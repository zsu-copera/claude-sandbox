#!/bin/bash
# Start the autonomous Claude Code session, locked down.
#
#   run-agent                                   # interactive
#   run-agent -p "task…" --output-format json   # headless; extra args pass through
#
# Order matters: lockdown first (fails hard if it can't), THEN purge credentials,
# THEN start the agent. A background loop re-resolves the Anthropic allowlist every
# 15 min (atomic ipset swap — no gap) since API IPs rotate during long runs.
set -euo pipefail

WS=/workspace

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
        sudo /usr/local/bin/init-firewall.sh lockdown >/dev/null 2>&1 || true
    done
) &
REFRESH_PID=$!
trap 'kill "$REFRESH_PID" 2>/dev/null || true' EXIT

# Use the prepare-staged latest Claude Code if present (image-baked CLI is the
# fallback). Same $HOME across containers keeps the installer's symlinks valid.
if [ -f "$WS/.agent-cli/claude-local.tgz" ]; then
    echo "==> Installing prepare-staged Claude Code"
    tar -C "$HOME" -xzf "$WS/.agent-cli/claude-local.tgz"
fi

cd "$WS"
echo "==> Starting Claude Code $(claude --version 2>/dev/null || echo '(version unknown)') (bypassPermissions) in $WS"
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
setpriv --inh-caps=-all --ambient-caps=-all \
    claude --dangerously-skip-permissions "$@"
