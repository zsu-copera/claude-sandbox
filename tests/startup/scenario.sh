#!/bin/bash
# One Phase 3 startup scenario (findings N5, E5). Runs as root in a disposable
# --network=none container started by verify-startup.sh.
#
# Without --baked it installs the source-mounted policy, wrapper and launchers over the
# image's, so it works on an image that predates Phase 3. Either way the real agent CLIs are
# replaced by a recorder, the firewall by a fake sudo, and the launcher or wrapper under
# test runs as vscode with every capability cleared. No real CLI, credential or network.
set -Euo pipefail
BAKED=0
[ "${1:-}" = --baked ] && { BAKED=1; shift; }
SC=${1:?scenario}
S=/opt/src FX=/opt/fx R=/run/p3
LOCK=/run/claude-lockdown-domains
REDIRECTS=(CLAUDE_CODE_MANAGED_SETTINGS_PATH CLAUDE_CODE_REMOTE_SETTINGS_PATH CLAUDE_CODE_MOCK_REMOTE_SETTINGS
           CLAUDE_CODE_DISABLE_ADMIN_ENV_UNION CLAUDE_CODE_SUBPROCESS_ENV_SCRUB)
die() { echo "ASSERT($SC): $*" >&2; [ -f "$R/out" ] && sed 's/^/    | /' "$R/out" >&2; exit 1; }

install -d -m 0755 "$R" /opt/p3bin
chown 1000:1000 "$R"
if [ "$BAKED" = 0 ]; then
    install -d -m 0755 /etc/claude-code /etc/claude-code/managed-settings.d \
        /usr/local/share/pera-sandbox /usr/local/lib/pera-sandbox /usr/local/lib/pera-sandbox/bin
    install -m 0644 "$S/claude-managed-settings.json" /etc/claude-code/managed-settings.json
    install -m 0644 "$S/claude-project-settings.json" /usr/local/share/pera-sandbox/claude-project-settings.json
    install -m 0755 "$S/agent-cli-guard.sh" /usr/local/lib/pera-sandbox/bin/claude
    ln -sfn claude /usr/local/lib/pera-sandbox/bin/copilot
    install -m 0755 "$S/run-agent.sh" /usr/local/bin/run-agent
    install -m 0755 "$S/run-copilot.sh" /usr/local/bin/run-copilot
    AGENT_PATH="/opt/p3bin:/usr/local/lib/pera-sandbox/bin:$PATH"
else
    AGENT_PATH="/opt/p3bin:$PATH"   # the image's own order is what is under test
fi

# Recorder at both wrapper targets: one log line per invocation, plus the last call's
# arguments, environment and capability sets.
cat > /opt/p3bin/fake-cli <<'EOF'
#!/bin/bash
echo "$0 $*" >> /run/p3/cli-log
printf '%s\0' "$@" > /run/p3/cli-args
env > /run/p3/cli-env
grep '^Cap' /proc/self/status > /run/p3/cli-caps
echo "fake CLI ran: $0"
EOF
printf '#!/bin/bash\necho "$*" >> /run/p3/sudo-calls\n' > /opt/p3bin/sudo
chmod 0755 /opt/p3bin/fake-cli /opt/p3bin/sudo
ln -sfn /opt/p3bin/fake-cli /home/vscode/.local/bin/claude
ln -sfn /opt/p3bin/fake-cli /usr/local/bin/copilot

W=/workspace C=/home/vscode/.claude
mkdir -p "$W/.secrets" /home/vscode/.copilot
echo synthetic > "$W/.secrets/fixture"
lock() { printf 'api.anthropic.com\n' > "$LOCK"; chmod 0600 "$LOCK"; }
settings() { mkdir -p "$W/.claude"; printf '%s\n' "$1" > "$W/.claude/settings.json"; }
user() { printf '%s\n' "$1" > "$C/settings.json"; }
as_agent() {
    local redirect=() v
    for v in "${REDIRECTS[@]}"; do redirect+=("$v=/tmp/p3-injected"); done
    setpriv --reuid 1000 --regid 1000 --init-groups --inh-caps=-all --ambient-caps=-all \
        env -i HOME=/home/vscode USER=vscode LANG=C.UTF-8 CLAUDE_CONFIG_DIR="$C" PATH="$AGENT_PATH" \
        "${redirect[@]}" "$@"
}

# --- setup -----------------------------------------------------------------------------
case "$SC" in
    agent-legacy)
        mkdir -p "$W/.claude"; cp "$FX/legacy-project-settings.json" "$W/.claude/settings.json"
        user '{"model":"opus","skipDangerousModePermissionPrompt":true,"theme":"dark","tui":"default"}'
        echo '[]' > "$C/remote-settings.json"
        echo '{"projects":{"/workspace":{"mcpServers":{},"allowedTools":[]}}}' > "$C/.claude.json" ;;
    agent-canonical)  mkdir -p "$W/.claude"; cp /usr/local/share/pera-sandbox/claude-project-settings.json "$W/.claude/settings.json"
                      echo '{}' > "$C/remote-settings.json" ;;
    agent-absent) ;;
    agent-project-excludedCommands) settings '{"sandbox":{"excludedCommands":["curl"]}}' ;;
    agent-project-allowWrite)       settings '{"sandbox":{"filesystem":{"allowWrite":["/"]}}}' ;;
    agent-project-bwrapPath)        settings '{"sandbox":{"bwrapPath":"/workspace/fake-bwrap"}}' ;;
    agent-project-hook)             settings '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"id"}]}]}}' ;;
    agent-project-statusLine)       settings '{"statusLine":{"type":"command","command":"id"}}' ;;
    agent-project-apiKeyHelper)     settings '{"apiKeyHelper":"id"}' ;;
    agent-project-whitespace)       mkdir -p "$W/.claude"; { cat /usr/local/share/pera-sandbox/claude-project-settings.json; echo; } > "$W/.claude/settings.json" ;;
    agent-project-symlink)          mkdir -p "$W/.claude"; ln -s /usr/local/share/pera-sandbox/claude-project-settings.json "$W/.claude/settings.json" ;;
    agent-claude-dir-symlink)       mkdir -p "$W/elsewhere"; ln -s elsewhere "$W/.claude" ;;
    agent-settings-local)           mkdir -p "$W/.claude"; echo '{}' > "$W/.claude/settings.local.json" ;;
    agent-mcp-json)                 echo '{"mcpServers":{}}' > "$W/.mcp.json" ;;
    agent-user-hooks)               user '{"model":"opus","hooks":{}}' ;;
    agent-user-statusLine)          user '{"statusLine":{"type":"command","command":"id"}}' ;;
    agent-user-apiKeyHelper)        user '{"apiKeyHelper":"id"}' ;;
    agent-user-env)                 user '{"env":{"CLAUDE_CODE_MANAGED_SETTINGS_PATH":"/tmp"}}' ;;
    agent-user-sandbox)             user '{"sandbox":{"excludedCommands":["curl"]}}' ;;
    agent-user-unparseable)         user '{"model":' ;;
    agent-user-array)               user '["model"]' ;;
    agent-remote-permissive)        echo '{"sandbox":{"excludedCommands":["*"]}}' > "$C/remote-settings.json" ;;
    agent-claudejson-top)           echo '{"mcpServers":{"x":{"command":"sh"}}}' > "$C/.claude.json" ;;
    agent-claudejson-project)       echo '{"projects":{"/workspace":{"mcpServers":{"x":{"command":"sh"}}}}}' > "$C/.claude.json" ;;
    agent-claudejson-unparseable)   echo '{"projects":' > "$C/.claude.json" ;;
    wrapper-lock-not-root)          lock; chown 1000:1000 "$LOCK" ;;
    wrapper-lock-symlink)           printf 'x\n' > /run/p3-real-lock; ln -s /run/p3-real-lock "$LOCK" ;;
    wrapper-lock-dir)               mkdir "$LOCK" ;;
    wrapper-caps-held|wrapper-guarded|copilot-guarded|copilot-launcher) lock ;;
    wrapper-unknown-name)           lock; ln -s /usr/local/lib/pera-sandbox/bin/claude /opt/p3bin/other ;;
    wrapper-bare|wrapper-bare-version|wrapper-version-plus-args|copilot-bare) ;;
    baked-layout) [ "$BAKED" = 1 ] || { echo "baked-layout needs --baked"; exit 77; } ;;
    *) die "unknown scenario" ;;
esac
# Every agent-* scenario runs after a (fake) successful lockdown, so a refusal proves the
# N5 checks, not the wrapper, stopped it.
case "$SC" in agent-*) lock ;; esac
chown -R -h 1000:1000 "$W" "$C" /home/vscode/.copilot

# --- run and assert ----------------------------------------------------------------------
rc=0
refused() {   # $1 = expected message fragment
    [ "$rc" = 78 ] || die "exit $rc, want 78"
    grep -Fq -- "$1" "$R/out" || die "message missing: $1"
    [ ! -e "$R/cli-log" ] || die "agent CLI ran: $(cat "$R/cli-log")"
}
n5_refused() {
    refused "REFUSED (finding N5): "
    grep -Fq -- "$1" "$R/out" || die "N5 reason missing: $1"
    [ ! -e "$R/sudo-calls" ] || die "firewall called before the N5 refusal"
    [ -f "$W/.secrets/fixture" ] || die "credentials purged before the N5 refusal"
}
ran() {       # $1 = binary the wrapper must have exec'd
    [ "$rc" = 0 ] || die "exit $rc, want 0"
    [ -f "$R/cli-log" ] || die "agent CLI never ran"
    last=$(tail -1 "$R/cli-log")
    case "$last" in "$1"*) ;; *) die "wrong CLI ran: $last" ;; esac
    for v in "${REDIRECTS[@]}"; do ! grep -q "^$v=" "$R/cli-env" || die "$v reached the CLI"; done
    held=$(awk '/^Cap(Inh|Prm|Eff|Amb):/ && $2 !~ /^0+$/' "$R/cli-caps")
    [ -z "$held" ] || die "CLI holds capabilities: $held"
}
case "$SC" in
    agent-legacy|agent-canonical|agent-absent)
        as_agent bash /usr/local/bin/run-agent --probe 'with space' > "$R/out" 2>&1 || rc=$?
        ran /home/vscode/.local/bin/claude
        mapfile -d '' -t args < "$R/cli-args"
        [ "${#args[@]}" = 3 ] && [ "${args[0]}" = --dangerously-skip-permissions ] \
            && [ "${args[1]}" = --probe ] && [ "${args[2]}" = 'with space' ] || die "arguments not preserved: ${args[*]}"
        [ "$(head -1 "$R/sudo-calls")" = "/usr/local/bin/init-firewall.sh lockdown" ] || die "lockdown not called first"
        [ ! -e "$W/.secrets" ] || die "credentials not purged after lockdown" ;;
    agent-project-symlink)          as_agent bash /usr/local/bin/run-agent > "$R/out" 2>&1 || rc=$?; n5_refused "is not a regular file" ;;
    agent-claude-dir-symlink)       as_agent bash /usr/local/bin/run-agent > "$R/out" 2>&1 || rc=$?; n5_refused "is not a plain directory" ;;
    agent-project-*)                as_agent bash /usr/local/bin/run-agent > "$R/out" 2>&1 || rc=$?; n5_refused "differs from the canonical project settings" ;;
    agent-settings-local|agent-mcp-json) as_agent bash /usr/local/bin/run-agent > "$R/out" 2>&1 || rc=$?; n5_refused "must not exist" ;;
    agent-user-unparseable|agent-user-array) as_agent bash /usr/local/bin/run-agent > "$R/out" 2>&1 || rc=$?; n5_refused "does not parse as a JSON object" ;;
    agent-user-*)                   as_agent bash /usr/local/bin/run-agent > "$R/out" 2>&1 || rc=$?; n5_refused "outside the reviewed allowlist" ;;
    agent-remote-permissive)        as_agent bash /usr/local/bin/run-agent > "$R/out" 2>&1 || rc=$?; n5_refused "server-managed settings cache" ;;
    agent-claudejson-unparseable)   as_agent bash /usr/local/bin/run-agent > "$R/out" 2>&1 || rc=$?; n5_refused "does not parse" ;;
    agent-claudejson-*)             as_agent bash /usr/local/bin/run-agent > "$R/out" 2>&1 || rc=$?; n5_refused "configures MCP servers" ;;
    wrapper-bare|wrapper-lock-not-root|wrapper-lock-symlink|wrapper-lock-dir)
        as_agent claude -p probe > "$R/out" 2>&1 || rc=$?; refused "REFUSED (finding E5): claude cannot start before" ;;
    wrapper-version-plus-args)
        as_agent claude --version -p probe > "$R/out" 2>&1 || rc=$?; refused "REFUSED (finding E5)" ;;
    wrapper-bare-version)
        as_agent claude --version > "$R/out" 2>&1 || rc=$?; ran /home/vscode/.local/bin/claude
        as_agent copilot -h >> "$R/out" 2>&1 || rc=$?; ran /usr/local/bin/copilot ;;
    wrapper-caps-held)
        # Root in this container still holds SETUID, SETGID and others.
        env PATH="$AGENT_PATH" claude -p probe > "$R/out" 2>&1 || rc=$?; refused "while holding capabilities" ;;
    wrapper-guarded)
        as_agent claude -p probe > "$R/out" 2>&1 || rc=$?; ran "/home/vscode/.local/bin/claude -p probe" ;;
    wrapper-unknown-name)
        as_agent other -p probe > "$R/out" 2>&1 || rc=$?; refused "installed under an unknown name" ;;
    copilot-bare)
        as_agent copilot -p probe > "$R/out" 2>&1 || rc=$?; refused "REFUSED (finding E5): copilot cannot start before" ;;
    copilot-guarded)
        as_agent copilot -p probe > "$R/out" 2>&1 || rc=$?; ran "/usr/local/bin/copilot -p probe" ;;
    copilot-launcher)
        as_agent COPILOT_GITHUB_TOKEN=github_pat_p3_synthetic_fixture bash /usr/local/bin/run-copilot -p probe \
            > "$R/out" 2>&1 || rc=$?
        ran "/usr/local/bin/copilot --allow-all-tools --disable-builtin-mcps"
        # No network here, so this is also the static CIDR fallback path.
        grep -Fq "using static CIDR fallback" "$R/out" || die "CIDR fallback not taken"
        grep -Fq "140.82.112.0/20" "$R/sudo-calls" || die "fallback CIDRs not passed to the lockdown" ;;
    baked-layout)
        [ "$(as_agent sh -c 'command -v claude')" = /usr/local/lib/pera-sandbox/bin/claude ] || die "claude is not the wrapper on PATH"
        [ "$(as_agent sh -c 'command -v copilot')" = /usr/local/lib/pera-sandbox/bin/copilot ] || die "copilot is not the wrapper on PATH"
        for f in /etc/claude-code/managed-settings.json /usr/local/share/pera-sandbox/claude-project-settings.json; do
            [ "$(stat -c '%u %g %a' "$f")" = "0 0 644" ] || die "$f is not root:root 0644"
        done
        for d in /etc/claude-code /etc/claude-code/managed-settings.d /usr/local/lib/pera-sandbox/bin; do
            [ "$(stat -c '%u %g %a' "$d")" = "0 0 755" ] || die "$d is not root:root 0755"
        done
        [ -z "$(ls -A /etc/claude-code/managed-settings.d)" ] || die "managed-settings.d is not empty"
        [ "$(stat -c '%u %a' /usr/local/lib/pera-sandbox/bin/claude)" = "0 755" ] || die "wrapper is not root 0755"
        cmp -s /etc/claude-code/managed-settings.json "$S/claude-managed-settings.json" || die "baked policy differs from source"
        cmp -s /usr/local/lib/pera-sandbox/bin/claude "$S/agent-cli-guard.sh" || die "baked wrapper differs from source"
        cmp -s /usr/local/bin/run-agent "$S/run-agent.sh" || die "baked run-agent differs from source" ;;
esac
echo "ok"
