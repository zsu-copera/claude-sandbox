#!/bin/bash
# Start the autonomous GitHub Copilot CLI session, locked down.
#
#   run-copilot --login            # ONE-TIME: wider firewall (adds github.com) for the
#                                  #   device-flow login; authenticate, then exit.
#   run-copilot                    # normal autonomous session (github.com NOT allowed —
#                                  #   git push to GitHub is network-impossible)
#   run-copilot -p "task…"         # headless; extra args pass through to copilot
#
# Two-phase firewall rationale: Documentation is hosted ON github.com (prj may migrate),
# so steady-state sessions exclude github.com entirely; only the Copilot API transport
# hosts stay open. See README "GitHub Copilot CLI variant".
set -euo pipefail

WS=/workspace
COPILOT_DIR="$HOME/.copilot"
SEEDS=/usr/local/share/copilot-defaults

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
# technically connectable in every session, and --login differs only in intent,
# not network reach. The no-push barrier is therefore: deny-tool rules + no git
# credentials (the agent has none; git push to GitHub 401s) + no remotes +
# disabled github-mcp-server + human review. True hostname-level filtering
# would need an SNI-aware proxy (possible hardening step, README §4b).
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
if [ "${1:-}" = "--login" ]; then
    shift
    MODE_DOMAINS+=(github.com)
    echo "==> LOGIN MODE: authenticate with /login, confirm /workspace as trusted, then exit."
fi

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
        sudo /usr/local/bin/init-firewall.sh lockdown "${MODE_DOMAINS[@]}" >/dev/null 2>&1 || true
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
#                               tools that would use the OAuth token, bypassing shell)
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
