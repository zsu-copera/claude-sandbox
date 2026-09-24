#!/bin/bash
# Start the autonomous Claude Code session, locked down.
#
#   run-agent                                   # interactive
#   run-agent -p "task…" --output-format json   # headless; extra args pass through
#
# Order matters: check the persistent inputs (refusing before any network change), THEN
# lockdown (fails hard if it can't), THEN purge credentials, THEN start the agent. A
# background loop re-resolves the Anthropic allowlist every 15 min (staged allowlist
# updates, without flushing live rules).
set -euo pipefail

WS=/workspace
CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CANONICAL=/usr/local/share/pera-sandbox/claude-project-settings.json
# sha256 of the only overlay .claude/settings.json shipped before Phase 3. Workspaces
# assembled earlier still carry it; under the managed policy its scalars lose and its
# lists (allowWrite /tmp, api.anthropic.com) add nothing.
LEGACY_PROJECT_SHA=58804644b538df8ff209284dc4fc4342946d1b2879cc302095d57eaa7ccb7eff
# User-settings keys that neither run commands nor touch the sandbox. Deliberately
# closed: a key a future CLI adds is refused until someone reviews it.
USER_KEYS='["$schema","effortLevel","language","model","outputStyle","skipDangerousModePermissionPrompt","theme","tui","viewMode"]'

# Settings redirects (Phase 3 spec §4.2 and the review's M2), and git's, whose root decides
# where Claude reads local settings. The environment comes from the operator's podman run;
# this closes it against a mistaken or copied -e. It is a denylist of the variables known
# to move settings, not an allowlist. The claude wrapper repeats it.
unset CLAUDE_CODE_MANAGED_SETTINGS_PATH CLAUDE_CODE_REMOTE_SETTINGS_PATH \
      CLAUDE_CODE_MOCK_REMOTE_SETTINGS CLAUDE_CODE_DISABLE_ADMIN_ENV_UNION \
      CLAUDE_CODE_SUBPROCESS_ENV_SCRUB CLAUDE_CODE_USE_COWORK_PLUGINS \
      CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST CLAUDE_CODE_BRIDGE_CHILD_MACHINE_SETTINGS \
      CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

# Finding N5: the workspace and the config volume persist between sessions and the agent
# can write both, so one session could hand the next a looser policy. Managed settings
# win for scalars, but lists merge from every scope, nothing locks excludedCommands (which
# run outside bubblewrap) or allowWrite, and user settings may still set command-running
# keys (statusLine, apiKeyHelper, ...). Every such input is checked here, while no agent
# process exists. A change refuses the launch rather than being silently repaired, so a
# human sees that something changed. Recovery: QUICKSTART "Startup refusals".
refuse_n5() {
    echo "==> REFUSED (finding N5): $1" >&2
    echo "    A previous session or a manual edit changed a persistent input. Inspect it" >&2
    echo "    before restoring it; see QUICKSTART \"Startup refusals\"." >&2
    exit 78
}
absent()  { [ ! -e "$1" ] && [ ! -L "$1" ]; }
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
for d in "$WS/.claude" "$CONFIG"; do
    absent "$d" || { [ -d "$d" ] && [ ! -L "$d" ]; } || refuse_n5 "$d is not a plain directory"
done
p="$WS/.claude/settings.json"
if ! absent "$p"; then
    regular "$p" || refuse_n5 "$p is not a regular file"
    cmp -s -- "$p" "$CANONICAL" || [ "$(sha256sum < "$p")" = "$LEGACY_PROJECT_SHA  -" ] \
        || refuse_n5 "$p differs from the canonical project settings ($CANONICAL)"
fi
# /workspace is not a repository. A .git there (a file naming prj/.git as its gitdir is
# enough) makes it a worktree, and Claude then reads local settings at the canonical git
# root, e.g. prj/.claude/settings.local.json, which is unchecked and writable in-session.
for f in "$WS/.claude/settings.local.json" "$WS/.mcp.json" "$WS/.git"; do
    absent "$f" || refuse_n5 "$f must not exist"
done
u="$CONFIG/settings.json"
if ! absent "$u"; then
    regular "$u" || refuse_n5 "$u is not a regular file"
    extra=$(jq -r --argjson ok "$USER_KEYS" \
        'if type == "object" then keys - $ok | join(" ") else error("not an object") end' "$u" 2>/dev/null) \
        || refuse_n5 "$u does not parse as a JSON object"
    [ -z "$extra" ] || refuse_n5 "$u sets keys outside the reviewed allowlist: $extra"
fi
r="$CONFIG/remote-settings.json"
if ! absent "$r"; then
    { regular "$r" && case "$(jq -c . "$r" 2>/dev/null)" in '[]'|'{}') true ;; *) false ;; esac; } \
        || refuse_n5 "$r holds a server-managed settings cache; only [] or {} is accepted"
fi
for c in "$CONFIG/.claude.json" "$HOME/.claude.json"; do
    absent "$c" && continue
    regular "$c" || refuse_n5 "$c is not a regular file"
    n=$(jq '[.. | objects | select(has("mcpServers")) | .mcpServers | select(. != {} and . != null)] | length' \
        "$c" 2>/dev/null) || refuse_n5 "$c does not parse"
    [ "$n" = 0 ] || refuse_n5 "$c configures MCP servers"
done
unset d p f u r c n extra

echo "==> Locking down egress (Anthropic endpoints only)"
sudo /usr/local/bin/init-firewall.sh lockdown

echo "==> Purging build-time credentials"
rm -rf "$WS/.secrets"
rm -f "$HOME/.m2/settings.xml" 2>/dev/null || true   # belt & suspenders — prepare uses -s, never installs one
rm -f "$HOME/.npmrc" 2>/dev/null || true             # staged by prepare (carries Nexus _auth)

# Refresh allowlist IPs in the background for long sessions.
(
    while true; do
        sleep 900
        if ! sudo /usr/local/bin/init-firewall.sh lockdown >/dev/null; then
            echo "[firewall] WARN: allowlist refresh failed; restrictions retained. Check the firewall error above; provider connectivity may degrade." >&2
        fi
    done
) &
REFRESH_PID=$!
trap 'kill "$REFRESH_PID" 2>/dev/null || true' EXIT

# Only the image-baked CLI runs (finding N5, decision A). Anything under the workspace,
# including a /workspace/.agent-cli left by an older prepare, is agent-writable and would
# carry a modified CLI into the next session. CLI updates are image rebuilds.

cd "$WS"
# The version banner drops capabilities too: nothing the CLI loads should ever hold them.
echo "==> Starting Claude Code $(setpriv --inh-caps=-all --ambient-caps=-all claude --version 2>/dev/null || echo '(version unknown)') (bypassPermissions) in $WS"
# Drop the firewall capabilities before handing control to the agent. Two reasons:
#   1. bubblewrap — the harness's own per-command sandbox — REFUSES to start while the
#      process holds capabilities without being setuid ("Unexpected capabilities but not
#      setuid, old file caps config?"). podman puts --cap-add=NET_ADMIN/NET_RAW in the
#      AMBIENT set so a non-root user keeps them, so every Bash tool call failed until the
#      agent turned its own sandbox off. The firewall and bwrap were mutually exclusive.
#   2. The agent has no business holding CAP_NET_ADMIN — the capability that manipulates
#      the very firewall confining it.
# Permitted caps are recomputed at exec from (inheritable ∪ ambient), so clearing those
# two yields an empty permitted set — which is what bwrap actually inspects. setpriv is
# used rather than `capsh --caps=""` because it execs a real argv, so "$@" passes through
# without shell-string requoting. The 15-min refresh loop above was forked BEFORE this
# point and reaches root via sudo, so it keeps working.
# `claude` resolves to the guarded wrapper, which re-checks this state and execs the baked
# CLI. The mandatory policy is /etc/claude-code/managed-settings.json (E2/E3).
setpriv --inh-caps=-all --ambient-caps=-all \
    claude --dangerously-skip-permissions "$@"
