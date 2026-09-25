#!/bin/bash
# Phase 3 startup regressions: run-agent's persistent-input checks (finding N5) and the
# guarded claude/copilot wrappers (finding E5).
#
#   wsl -d centos-9 -- bash /mnt/c/work/pera/claude-sandbox/verify-startup.sh [--image IMAGE] [--baked]
#
# Each scenario runs in its own disposable --network=none container as root with a handful
# of capabilities, so the fixture can install files and then drop to vscode with none. The
# real agent CLIs are replaced by a recorder and the firewall by a fake sudo: this proves
# the launcher and wrapper logic, not the CLI's own policy handling (Phase 3 spec, L1-L8).
# Without --baked the source-mounted scripts and policy are installed over the image's, so
# an image that predates Phase 3 works. With --baked the image's own copies are tested and
# must equal the source. Nothing is pulled, built, or mounted from a real workspace.
set -uo pipefail
IMAGE=localhost/pera-sandbox
BAKED=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --image) [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "Missing --image value" >&2; exit 2; }; IMAGE=$2; shift 2 ;;
        --baked) BAKED=(--baked); shift ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Usage: $0 [--image IMAGE] [--baked]" >&2; exit 2 ;;
    esac
done
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
command -v podman >/dev/null || { echo "FAIL prerequisite: podman unavailable"; exit 1; }
podman image exists "$IMAGE" || { echo "FAIL prerequisite: image $IMAGE unavailable (no pull/build attempted)"; exit 1; }

SCENARIOS=(
    agent-legacy agent-canonical agent-absent
    agent-project-excludedCommands agent-project-allowWrite agent-project-bwrapPath
    agent-project-hook agent-project-statusLine agent-project-apiKeyHelper agent-project-whitespace
    agent-project-symlink agent-claude-dir-symlink agent-settings-local agent-mcp-json
    agent-user-hooks agent-user-statusLine agent-user-apiKeyHelper agent-user-env agent-user-sandbox
    agent-user-unparseable agent-user-array agent-remote-permissive
    agent-claudejson-top agent-claudejson-project agent-claudejson-unparseable agent-claudejson-fifo
    agent-workspace-git agent-workspace-git-dir agent-project-hardlink agent-user-hardlink
    wrapper-bare wrapper-bare-version wrapper-version-plus-args wrapper-lock-not-root
    wrapper-lock-symlink wrapper-lock-dir wrapper-caps-held wrapper-guarded wrapper-unknown-name
    copilot-bare copilot-guarded copilot-launcher copilot-pkg-wrapper copilot-pkg-launcher baked-layout
)
NAME="p3-startup-${UID}-${BASHPID}-${RANDOM}"
ACTIVE=""
trap '[ -z "$ACTIVE" ] || podman rm --force --time 0 "$ACTIVE" >/dev/null 2>&1' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
PASS=0 FAIL=0 SKIP=0
for sc in "${SCENARIOS[@]}"; do
    ACTIVE="$NAME-$sc"
    out=$(timeout --signal=TERM --kill-after=5 60 podman run --rm --name "$ACTIVE" --pull never \
        --network none --user 0:0 --cap-drop all --security-opt no-new-privileges \
        --cap-add SETUID --cap-add SETGID --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
        --tmpfs /workspace:rw,mode=0755 --tmpfs /home/vscode/.claude:rw,mode=0755 \
        --volume "$ROOT/container:/opt/src:ro" --volume "$ROOT/tests/startup:/opt/fx:ro" \
        --entrypoint bash "$IMAGE" /opt/fx/scenario.sh "${BAKED[@]}" "$sc" 2>&1)
    status=$?
    # A scenario that hangs is killed by timeout, which stops the podman client, not the
    # container; remove it explicitly, as verify-firewall.sh does.
    if podman container exists "$ACTIVE"; then
        podman rm --force --time 0 "$ACTIVE" >/dev/null || { echo "FAIL cleanup: $ACTIVE"; exit 1; }
    fi
    ACTIVE=""
    case "$status" in
        0)  PASS=$((PASS + 1)); echo "PASS $sc" ;;
        77) SKIP=$((SKIP + 1)); echo "SKIP $sc: $out" ;;
        *)  FAIL=$((FAIL + 1)); printf 'FAIL %s (exit %s)\n%s\n' "$sc" "$status" "$out" ;;
    esac
done
echo "== $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
