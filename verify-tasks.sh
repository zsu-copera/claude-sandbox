#!/usr/bin/env bash
set -euo pipefail
umask 077
usage() {
    while IFS= read -r line; do printf '%s\n' "$line"; done <<'USAGE'
Usage: bash verify-tasks.sh [--image IMAGE] [--test-name-pattern PATTERN] [--integration]

Run built-in Node tests in the existing network-none, cap-drop-all image.
No host Node, dependencies, credentials, retained workspaces or source repos.
Only trusted helper/test directories are mounted read-only.
--integration also exercises the real WSL task wrapper in a uniquely owned
fixture under the current directory. Run outside scaffold/retained workspaces,
on the WSL filesystem. Cleanup retains data on unknown engine/mount status.
Selectors apply to Node tests; --integration always runs the wrapper scenario.
USAGE
}
if [[ $# == 1 && ( $1 == --help || $1 == -h ) ]]; then usage; exit 0; fi
image=localhost/pera-sandbox
image_set=0
pattern_set=0
integration=0
test_args=(--test)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            [[ $# -gt 1 && -n $2 && $2 != -* && $image_set == 0 ]] || { usage >&2; exit 2; }
            image=$2; image_set=1; shift 2;;
        --test-name-pattern)
            [[ $# -gt 1 && -n $2 && $pattern_set == 0 ]] || { usage >&2; exit 2; }
            test_args+=(--test-name-pattern "$2"); pattern_set=1; shift 2;;
        --integration)
            [[ $integration == 0 ]] || { usage >&2; exit 2; }
            integration=1; shift;;
        *) usage >&2; exit 2;;
    esac
done
for program in podman realpath sha256sum; do command -v "$program" >/dev/null || exit 1; done
scaffold=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")")
[[ $scaffold != *[,:]* && $scaffold != *$'\n'* && $scaffold != *$'\r'* ]] || { echo 'Unsafe scaffold mount path.' >&2; exit 1; }
podman image exists "$image" || { echo 'Image missing; no pull/build attempted.' >&2; exit 1; }
IFS= read -r nonce < /proc/sys/kernel/random/uuid
name="pera-task-tests-$nonce"
cleanup() {
    local status=$? label code failed=0
    trap - EXIT HUP INT TERM
    if podman container exists "$name"; then
        if label=$(podman container inspect "$name" --format '{{index .Config.Labels "io.pera.task-tests"}}'); then
            if [[ $label == "$nonce" ]]; then
                if ! podman rm --force "$name" >/dev/null; then failed=1; fi
            else failed=1; fi
        else failed=1; fi
    else code=$?; if [[ $code != 1 ]]; then failed=1; fi; fi
    if [[ $failed == 1 ]]; then
        echo 'Owned test-container cleanup failed; inspect before retrying.' >&2
        if [[ $status == 0 ]]; then status=1; fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
source_snapshot() {
    sha256sum -- "$scaffold/sandbox-task.sh" "$scaffold/sandbox-round.sh" "$scaffold/verify-tasks.sh" \
        "$scaffold/tools/rounds/rounds.js" "$scaffold"/tools/tasks/*.js \
        "$scaffold"/tests/tasks/*.js "$scaffold"/tests/tasks/*.sh \
        "$scaffold"/tests/rounds/*.js "$scaffold"/tests/rounds/*.cjs "$scaffold"/tests/rounds/*.sh
}
before=$(source_snapshot)
podman run --rm --pull=never --name "$name" --label "io.pera.task-tests=$nonce" \
    --network=none --cap-drop=all --security-opt=no-new-privileges --userns=keep-id \
    --http-proxy=false --unsetenv-all --env PATH=/usr/local/bin:/usr/bin:/bin \
    --env HOME=/nonexistent --entrypoint /bin/bash \
    --mount "type=bind,src=$scaffold/tools/tasks,dst=/opt/tasks,ro" \
    --mount "type=bind,src=$scaffold/tools/rounds/rounds.js,dst=/opt/rounds.js,ro" \
    --mount "type=bind,src=$scaffold/tests,dst=/tests,ro" \
    "$image" -c 'set -euo pipefail
umask 077
[[ $(id -u) != 0 ]]
IFS=: read -r _ _ _ _ _ workhome _ <<< "$(getent passwd "$(id -u)")"
[[ -n $workhome && -d $workhome ]]
cd -- "$workhome"
mkdir task-tests
cd task-tests
export TMPDIR="$PWD"
exec node "$@" /tests/tasks/*.test.js' tasks "${test_args[@]}"
[[ $(source_snapshot) == "$before" ]] || { echo 'Source changed during tests; results do not verify a stable snapshot.' >&2; exit 1; }
if [[ $integration == 1 ]]; then
    bash "$scaffold/tests/tasks/wrapper-integration.sh" --image "$image"
    bash "$scaffold/tests/tasks/lock-integration.sh" --image "$image"
    [[ $(source_snapshot) == "$before" ]] || { echo 'Source changed during integration; rerun a stable snapshot.' >&2; exit 1; }
fi
