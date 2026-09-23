#!/bin/bash
# Start the autonomous GitHub Copilot CLI session, locked down.
#
#   run-copilot                    # normal autonomous session
#   run-copilot -p "task…"         # headless; extra args pass through to copilot
#
# Requires COPILOT_GITHUB_TOKEN = a fine-grained PAT limited to the "Copilot Requests"
# account permission, e.g. podman --secret NAME,type=env,target=COPILOT_GITHUB_TOKEN.
# See README "GitHub Copilot CLI variant".
set -euo pipefail

WS=/workspace
COPILOT_DIR="$HOME/.copilot"
SEEDS=/usr/local/share/copilot-defaults

# Finding N3: the agent can read whatever credential Copilot uses, and GitHub is
# reachable (see HONEST LIMITATION below), so that credential must not be able to write
# to GitHub. The OAuth sign-in (/login, the retired --login mode) stores a gho_ token
# with the repo and gist scopes: it can push to every repository the user can write and
# create gists, whatever the deny rules or policy hook match. Only a fine-grained PAT
# supplied through the environment is accepted, and a token-like value left in the auth
# volume refuses the launch. The launcher cannot see a PAT's permissions; creating it
# with Copilot Requests only is the operator's step. Checks run before any network use.
refuse_n3() {
    echo "==> REFUSED (finding N3): $1" >&2
    echo "    See QUICKSTART step 4-alt for the Copilot-Requests-only fine-grained PAT setup." >&2
    exit 78
}
[ "${1:-}" != "--login" ] \
    || refuse_n3 "--login is retired: it stores an OAuth token with the repo and gist scopes."
case "${COPILOT_GITHUB_TOKEN:-}" in
    github_pat_?*) ;;
    "") refuse_n3 "COPILOT_GITHUB_TOKEN is not set." ;;
    *) refuse_n3 "COPILOT_GITHUB_TOKEN is not a fine-grained PAT (github_pat_...)." ;;
esac
unset GH_TOKEN GITHUB_TOKEN
if [ -e "$COPILOT_DIR/config.json" ]; then
    # config.json starts with // comment lines, so strip them before parsing. Fail closed:
    # an unparseable file, or any stored token other than a PAT, refuses the launch.
    STORED=$(grep -v '^[[:space:]]*//' "$COPILOT_DIR/config.json" \
        | jq -r '[(.copilotTokens // {})[] | select(type != "string" or (startswith("github_pat_") | not))] | length' \
        2>/dev/null) || STORED=unparseable
    if [ "$STORED" != 0 ] || grep -Eq 'gh[opsu]_[A-Za-z0-9]{20,}' "$COPILOT_DIR/config.json"; then
        refuse_n3 "the auth volume's config.json holds a stored sign-in token ($STORED non-PAT entries). Remove it and revoke the OAuth authorization."
    fi
fi

# Copilot Enterprise endpoints. Telemetry hosts intentionally excluded (fail-fast
# REJECT is fine). The GitHub-hosted names (github.com, api.github.com,
# api.githubcopilot.com…) sit behind GitHub's GLB, which rotates IPs BETWEEN
# resolutions — per-host IP snapshots fail (api.githubcopilot.com was 0/15
# reachable in testing) — so GitHub's published web/api CIDR ranges
# (api.github.com/meta) carry the allow; hostnames remain for the Azure-hosted
# transports and the smoke test.
#
# HONEST LIMITATION: github.com and api.githubcopilot.com are served from the
# SAME address pool, so IP-level filtering cannot separate them — github.com is
# technically connectable in every session. The no-push barrier is therefore the
# credential: the only GitHub token present is the Copilot-Requests-only PAT checked
# above, which cannot push or write through the REST API. The deny-tool rules, policy
# hook, disabled github-mcp-server, absent remotes and human review are defense-in-depth.
# True hostname-level filtering would need an SNI-aware proxy (README §4b).
#
# Ranges are fetched from the authoritative api.github.com/meta at startup
# (the fresh container's network is open until the first lockdown); the static
# fallback covers a failed fetch. The regional /32s in meta change over time —
# do not hand-maintain them.
FALLBACK_CIDRS="140.82.112.0/20 143.55.64.0/20 192.30.252.0/22 185.199.108.0/22"
GITHUB_CIDRS=$(curl -s -m 10 https://api.github.com/meta 2>/dev/null \
    | jq -r '(.web + .api)[]? | select(contains(":") | not)' 2>/dev/null | sort -u | tr '\n' ' ')
if [ -z "${GITHUB_CIDRS// /}" ]; then
    echo "==> WARN: could not fetch api.github.com/meta — using static CIDR fallback"
    GITHUB_CIDRS="$FALLBACK_CIDRS"
fi

# shellcheck disable=SC2206  # intentional word-splitting of the CIDR list
MODE_DOMAINS=(
    api.githubcopilot.com
    api.enterprise.githubcopilot.com
    api.github.com
    copilot-proxy.githubusercontent.com
    origin-tracker.githubusercontent.com
    $GITHUB_CIDRS
)

echo "==> Locking down egress (GitHub Copilot endpoints only)"
sudo /usr/local/bin/init-firewall.sh lockdown "${MODE_DOMAINS[@]}"

echo "==> Purging build-time credentials"
rm -rf "$WS/.secrets"
rm -f "$HOME/.m2/settings.xml" "$HOME/.npmrc" 2>/dev/null || true

# Seed the model default (claude-opus-4-8) into the persistent volume on FIRST run
# only — never clobber user state. (Deny rules are NOT seeded: Copilot's
# permissions-config.json is an interactive-approvals store, not a policy file;
# enforcement is via the CLI flags below, outside the agent's reach.)
mkdir -p "$COPILOT_DIR"
[ -f "$COPILOT_DIR/settings.json" ] || cp "$SEEDS/settings.json" "$COPILOT_DIR/settings.json"

# Refresh allowlist IPs for long sessions. MUST pass the mode's domain list — a bare
# `lockdown` would swap in the Anthropic defaults and cut Copilot off mid-session.
(
    while true; do
        sleep 900
        if ! sudo /usr/local/bin/init-firewall.sh lockdown "${MODE_DOMAINS[@]}" >/dev/null; then
            echo "[firewall] WARN: allowlist refresh failed; restrictions retained. Check the firewall error above; provider connectivity may degrade." >&2
        fi
    done
) &
REFRESH_PID=$!
trap 'kill "$REFRESH_PID" 2>/dev/null || true' EXIT

# Use the prepare-staged latest Copilot CLI if present (image-baked CLI is the
# fallback). The npm-prefix install under /workspace is self-contained.
if [ -x "$WS/.agent-cli/copilot/bin/copilot" ]; then
    export PATH="$WS/.agent-cli/copilot/bin:$PATH"
fi

cd "$WS"
echo "==> Starting Copilot CLI $(copilot --version 2>/dev/null || echo '(version unknown)') (autonomous) in $WS"
# GitHub write paths must be blocked at the tool layer because api.github.com stays
# open for Copilot's own auth (syntax verified against copilot --help, v1.0.69):
#   --disable-builtin-mcps      kills the built-in github-mcp-server (PR/issue/gist
#                               tools that would use the session's token, bypassing shell)
#   --deny-tool 'shell(x y)'    hierarchical command identifiers; :* wildcards args
#   --deny-url                  blocks the fetch tool from GitHub hosts (CLI's own
#                               API traffic is not a tool call and is unaffected)
#
# The deny-tool SYNTAX was verified against --help, but the BEHAVIOUR was not, and
# it is weaker than it looks: the rules match a command-identifier PREFIX, so
# `git push` and `git  push origin main` are denied while `git -C . push` and
# `env git push` run (verified 2026-09-09, v1.0.83). Any global option between
# `git` and `push` walks straight past them. They are kept because they give a
# clearer message for the common case, but the barrier that actually closes the
# hole is the policy hook baked into the image at
# /etc/github-copilot/policy.d/10-guardrails.json, which sees the whole command
# string. Do not treat these flags as the no-push control on their own.
# Deliberately NOT passed: --allow-all-paths / --allow-all-urls (path verification
# and URL gating stay on) and --autopilot (add it yourself for headless runs:
#   run-copilot --autopilot -p "task").
# Drop the firewall capabilities first — the agent has no business holding
# CAP_NET_ADMIN, the capability that manipulates the firewall confining it. (Same
# reasoning as run-agent.sh, minus the bubblewrap angle, which is Claude-specific.)
# The refresh loop above was forked earlier and reaches root via sudo, so it is
# unaffected. Permitted caps are recomputed at exec from (inheritable ∪ ambient).
setpriv --inh-caps=-all --ambient-caps=-all \
    copilot --allow-all-tools \
    --disable-builtin-mcps \
    --deny-tool='shell(git push)' \
    --deny-tool='shell(git remote)' \
    --deny-tool='shell(gh)' \
    --deny-tool='shell(gh:*)' \
    --deny-url=github.com \
    --deny-url=api.github.com \
    --deny-url=githubusercontent.com \
    "$@"
