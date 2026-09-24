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
refuse() {   # $1 = finding, $2 = reason
    echo "==> REFUSED (finding $1): $name $2." >&2
    echo "    Start agents with run-agent or run-copilot (QUICKSTART step 4 and \"Startup refusals\")." >&2
    exit 78
}
case "$name" in
    claude)  real=/home/vscode/.local/bin/claude; pre=() ;;
    copilot) real=/usr/local/bin/copilot;         pre=(--no-auto-update) ;;
    *) echo "agent-cli-guard: installed under an unknown name: $name" >&2; exit 78 ;;
esac

# Redirects of Claude Code's settings (Phase 3 spec §4.2 and the review's M2), and of git,
# whose root decides where Claude reads local settings. Also removed by run-agent; repeated
# here so a copied `-e` cannot reach a CLI started any other way.
unset CLAUDE_CODE_MANAGED_SETTINGS_PATH CLAUDE_CODE_REMOTE_SETTINGS_PATH \
      CLAUDE_CODE_MOCK_REMOTE_SETTINGS CLAUDE_CODE_DISABLE_ADMIN_ENV_UNION \
      CLAUDE_CODE_SUBPROCESS_ENV_SCRUB CLAUDE_CODE_USE_COWORK_PLUGINS \
      CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST CLAUDE_CODE_BRIDGE_CHILD_MACHINE_SETTINGS \
      CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

if [ "$name" = copilot ]; then
    # Finding N5 for Copilot (review H1): the npm loader runs a NEWER package from its
    # cache in preference to the baked one, and ~/.copilot/pkg is on the persistent,
    # agent-writable config volume. --no-auto-update (injected on every call, including
    # --version, which run-copilot calls) makes it run the baked version; a cache left
    # there refuses the start so a human sees it.
    export COPILOT_AUTO_UPDATE=false
    unset COPILOT_HOME COPILOT_CACHE_HOME COPILOT_PKG_CACHE_HOME COPILOT_CLI_VERSION
    pkg="$HOME/.copilot/pkg"
    { [ ! -e "$pkg" ] && [ ! -L "$pkg" ]; } \
        || refuse N5 "cannot start while a package cache exists at $pkg (a newer package there would run instead of the baked CLI)"
fi

if [ "$#" -eq 1 ]; then
    case "$1" in --version|-v|--help|-h) exec "$real" "${pre[@]}" "$1" ;; esac
fi

lock=/run/claude-lockdown-domains
{ [ -f "$lock" ] && [ ! -L "$lock" ] && [ "$(stat -c %u -- "$lock")" = 0 ]; } \
    || refuse E5 "cannot start before this container has locked down its egress"

# Read in this shell, not a pipeline, so /proc/self is the process that will exec.
while read -r key value; do
    case "$key" in
        CapInh:|CapPrm:|CapEff:|CapAmb:)
            [ "$((16#$value))" -eq 0 ] || refuse E5 "cannot start while holding capabilities ($key $value)" ;;
    esac
done < /proc/self/status

exec "$real" "${pre[@]}" "$@"
