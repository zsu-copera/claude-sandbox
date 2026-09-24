#!/bin/bash
# Guarded startup for the agent CLIs (finding E5). Installed root-owned as
# /usr/local/lib/pera-sandbox/bin/claude and .../copilot, first on the image PATH.
#
# A bare `claude` or `copilot` from an uninitialized shell would run with the egress
# firewall still open and, under podman's --cap-add, with CAP_NET_ADMIN in the ambient
# set. This refuses unless the container has locked down (init-firewall.sh pins
# /run/claude-lockdown-domains, root-owned, at the first lockdown) and this process holds
# no capabilities, which is exactly the state run-agent / run-copilot establish before
# they exec the CLI. `--version` / `--help` on their own always pass through.
#
# This guards against operator mistakes, not the agent: a process inside a guarded
# session can exec the real binary by path, and gains nothing by it, because the
# lockdown, the capability drop and the managed policy already apply to it.
set -euo pipefail

name=${0##*/}
case "$name" in
    claude)  real=/home/vscode/.local/bin/claude ;;
    copilot) real=/usr/local/bin/copilot ;;
    *) echo "agent-cli-guard: installed under an unknown name: $name" >&2; exit 78 ;;
esac

# Redirects of Claude Code's managed policy (§4.2 of the Phase 3 spec). Also removed by
# run-agent; repeated here so a copied `-e` cannot reach a CLI started any other way.
unset CLAUDE_CODE_MANAGED_SETTINGS_PATH CLAUDE_CODE_REMOTE_SETTINGS_PATH \
      CLAUDE_CODE_MOCK_REMOTE_SETTINGS CLAUDE_CODE_DISABLE_ADMIN_ENV_UNION \
      CLAUDE_CODE_SUBPROCESS_ENV_SCRUB

if [ "$#" -eq 1 ]; then
    case "$1" in --version|-v|--help|-h) exec "$real" "$1" ;; esac
fi

refuse() {
    echo "==> REFUSED (finding E5): $name $1." >&2
    echo "    Start agents with run-agent or run-copilot (QUICKSTART step 4)." >&2
    exit 78
}

lock=/run/claude-lockdown-domains
{ [ -f "$lock" ] && [ ! -L "$lock" ] && [ "$(stat -c %u -- "$lock")" = 0 ]; } \
    || refuse "cannot start before this container has locked down its egress"

# Read in this shell, not a pipeline, so /proc/self is the process that will exec.
while read -r key value; do
    case "$key" in
        CapInh:|CapPrm:|CapEff:|CapAmb:)
            [ "$((16#$value))" -eq 0 ] || refuse "cannot start while holding capabilities ($key $value)" ;;
    esac
done < /proc/self/status

exec "$real" "$@"
