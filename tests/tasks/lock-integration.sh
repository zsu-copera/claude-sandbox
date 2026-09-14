#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $# == 2 && $1 == --image && -n $2 && $2 != -* ]] || { echo 'Expected --image IMAGE.' >&2; exit 2; }
image=$2
tests=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")")
scaffold=$(realpath -e -- "$tests/../..")
source "$scaffold/tests/rounds/mount-guard.sh"
cwd=$(pwd -P)
case "$cwd" in
    "$scaffold"|"$scaffold"/*|"$HOME/pera-sandbox"|"$HOME/pera-sandbox"/*|/|/mnt|/mnt/*)
        echo 'Run lock integration from an ordinary WSL directory outside scaffold/retained workspace.' >&2
        exit 1;;
esac
[[ $cwd != *[,:]* && $cwd != *$'\n'* && $cwd != *$'\r'* ]] || exit 1
IFS= read -r nonce < /proc/sys/kernel/random/uuid
root="$cwd/.tasks-lock-fixture-$nonce"
mkdir -m 700 -- "$root"
fixture_name="pera-task-lock-test-$nonce"
controller_name=
controller_nonce=
wrapper_pid=
cleanup() {
    local status=$? name label code failed=0
    trap - EXIT HUP INT TERM
    if [[ -n $wrapper_pid ]]; then
        if kill -0 "$wrapper_pid" 2>/dev/null; then
            if ! kill -CONT "$wrapper_pid"; then failed=1; fi
            if ! kill -TERM "$wrapper_pid"; then failed=1; fi
        fi
        if wait "$wrapper_pid"; then :; else code=$?; if [[ $code != 143 && $code != 137 ]]; then failed=1; fi; fi
    fi
    for name in "$fixture_name" "$controller_name"; do
        [[ -n $name ]] || continue
        if podman container exists "$name"; then
            if [[ $name == "$fixture_name" ]]; then
                if ! label=$(podman container inspect "$name" --format '{{index .Config.Labels "io.pera.task-lock-test"}}'); then failed=1; continue; fi
                if [[ $label != "$nonce" ]]; then failed=1; continue; fi
            else
                if ! label=$(podman container inspect "$name" --format '{{index .Config.Labels "io.pera.task-operation"}}'); then failed=1; continue; fi
                if [[ $label != "$controller_nonce" ]]; then failed=1; continue; fi
            fi
            if ! podman rm --force "$name" >/dev/null; then failed=1; fi
        else code=$?; if [[ $code != 1 ]]; then failed=1; fi; fi
    done
    if ! round_fixture_unmounted "$root"; then failed=1; fi
    if [[ $failed == 0 ]]; then
        if ! rm -rf -- "$root"; then failed=1; fi
    else printf 'Lock fixture retained after unknown cleanup/mount state: %s\n' "$root" >&2; fi
    if [[ $failed == 1 && $status == 0 ]]; then status=1; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
podman run --rm --pull=never --name "$fixture_name" --label "io.pera.task-lock-test=$nonce" \
    --network=none --cap-drop=all --security-opt=no-new-privileges --userns=keep-id \
    --http-proxy=false --unsetenv-all --env PATH=/usr/local/bin:/usr/bin:/bin \
    --env HOME=/nonexistent --env TMPDIR=. --workdir /fixtures --entrypoint node \
    --mount "type=bind,src=$root,dst=/fixtures,rw" --mount "type=bind,src=$scaffold/tests,dst=/tests,ro" \
    "$image" /tests/tasks/integration-fixture.js setup "$root" "$image"
export XDG_STATE_HOME="$root/operator-state"
wrapper="$scaffold/sandbox-task.sh"
bash "$wrapper" register --config "$root/config.json" > "$root/registered.json"
bash "$wrapper" status TASK-1 > "$root/interrupted.json" 2> "$root/interrupted.err" &
wrapper_pid=$!
shopt -s nullglob
ready=0
for ((attempt=0; attempt<1200; attempt++)); do
    kill -0 "$wrapper_pid" 2>/dev/null || { echo 'Controller ended before the lock test could capture it.' >&2; exit 1; }
    requests=("$XDG_STATE_HOME"/pera-sandbox-tasks/.operation-*/request-1.json)
    if [[ ${#requests[@]} == 1 ]]; then
        operation=$(dirname -- "${requests[0]}")
        controller_nonce=${operation##*/.operation-}
        [[ $controller_nonce =~ ^[a-f0-9-]{36}$ ]] || exit 1
        controller_name="pera-task-$controller_nonce"
        jq -e '.operation == "image"' "${requests[0]}" >/dev/null
        kill -STOP "$wrapper_pid"
        ready=1
        break
    fi
    sleep 0.05
done
[[ $ready == 1 ]] || { echo 'Controller did not become responsive.' >&2; exit 1; }
[[ $(podman container inspect "$controller_name" --format '{{.State.Running}}') == true ]]
kill -KILL "$wrapper_pid"
if wait "$wrapper_pid"; then echo 'Expected interrupted host wrapper.' >&2; exit 1; else code=$?; [[ $code == 137 ]]; fi
wrapper_pid=
if bash "$wrapper" status TASK-1 > "$root/locked.json" 2> "$root/locked.err"; then
    echo 'An orphan controller must retain exclusive ownership of task state.' >&2
    exit 1
fi
[[ ! -s $root/locked.json ]]
grep -q 'owns this task' "$root/locked.err"
[[ $(podman container inspect "$controller_name" --format '{{index .Config.Labels "io.pera.task-operation"}}') == "$controller_nonce" ]]
podman rm --force "$controller_name" >/dev/null
controller_name=
bash "$wrapper" status TASK-1 > "$root/recovered.json"
[[ $(jq -r .status "$root/recovered.json") == ready ]]
echo 'PASS task process lock: host interruption retains exclusive state ownership until its labelled controller stops.'
