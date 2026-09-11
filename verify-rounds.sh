#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
    cat <<'USAGE'
Usage: bash verify-rounds.sh [--image IMAGE] [--test-name-pattern PATTERN] [--integration]

Run Node's built-in round tests in a fresh network-none maintenance container.
Only the trusted helper and test fixtures are mounted, both read-only. Repositories
and data are generated inside the disposable container; no retained sandbox,
credentials, caches or source repositories are mounted.

--integration also exercises the actual WSL wrapper against disposable fixture
directories created underneath the CURRENT DIRECTORY. Run this from an ordinary
WSL Linux-filesystem working directory outside the scaffold and retained sandbox.
The exact fixture directory is removed on exit; existing files are never deleted.
Requires the already-built image (default localhost/pera-sandbox); never pulls.
--test-name-pattern passes a selector to Node's existing built-in test runner.
USAGE
}
if [[ $# == 1 && ( $1 == --help || $1 == -h ) ]]; then usage; exit 0; fi
image=localhost/pera-sandbox
integration=0
image_set=0
pattern_set=0
test_args=(--test)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            [[ $# -gt 1 && -n $2 && $2 != -* && $image_set == 0 ]] || { usage >&2; exit 2; }
            image=$2; image_set=1; shift 2;;
        --integration)
            [[ $integration == 0 ]] || { usage >&2; exit 2; }
            integration=1; shift;;
        --test-name-pattern)
            [[ $# -gt 1 && -n $2 && $pattern_set == 0 ]] || { usage >&2; exit 2; }
            test_args+=(--test-name-pattern "$2"); pattern_set=1; shift 2;;
        *) usage >&2; exit 2;;
    esac
done
for program in podman realpath; do
    command -v "$program" >/dev/null 2>&1 || { printf 'Missing command: %s\n' "$program" >&2; exit 1; }
done
scaffold=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")")
[[ $scaffold != *[,:]* && $scaffold != *$'\n'* && $scaffold != *$'\r'* ]] || { echo 'Unsafe scaffold mount path.' >&2; exit 1; }
[[ -f $scaffold/tools/rounds/rounds.js ]] || { echo 'Rounds helper is not ready; fixtures were not run.' >&2; exit 1; }
podman image exists "$image" || { echo 'Required image is not present; no pull/build attempted.' >&2; exit 1; }
IFS= read -r nonce < /proc/sys/kernel/random/uuid
name="pera-round-tests-$nonce"
cleanup() {
    local status=$? label probe_status cleanup_failed=0
    trap - EXIT HUP INT TERM
    if podman container exists "$name"; then
        if label=$(podman container inspect "$name" --format '{{index .Config.Labels "io.pera.round-tests"}}'); then
            if [[ $label == "$nonce" ]]; then
                if ! podman rm --force "$name" >/dev/null; then cleanup_failed=1; fi
            else
                echo 'Refusing cleanup of an unrelated test container.' >&2
                cleanup_failed=1
            fi
        else
            cleanup_failed=1
        fi
    else
        probe_status=$?
        if [[ $probe_status != 1 ]]; then cleanup_failed=1; fi
    fi
    if [[ $cleanup_failed == 1 ]]; then
        echo 'Test container cleanup failed; inspect the owned container before retrying.' >&2
        if [[ $status == 0 ]]; then status=1; fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
podman run --rm --pull=never --name "$name" --label "io.pera.round-tests=$nonce" \
    --network=none --cap-drop=all --security-opt=no-new-privileges --userns=keep-id \
    --http-proxy=false --unsetenv-all --env PATH=/usr/local/bin:/usr/bin:/bin \
    --env HOME=/nonexistent --entrypoint /bin/bash \
    --mount "type=bind,src=$scaffold/tools/rounds/rounds.js,dst=/opt/rounds.js,ro" \
    --mount "type=bind,src=$scaffold/tests/rounds,dst=/tests,ro" \
    "$image" -c 'set -euo pipefail
IFS=: read -r _ _ _ _ _ workhome _ <<< "$(getent passwd "$(id -u)")"
[[ -n $workhome && -d $workhome ]]
cd -- "$workhome"
mkdir round-work
cd round-work
export TMPDIR="$PWD"
exec node "$@"' rounds "${test_args[@]}" /tests/core.test.js /tests/cleanup.test.js
if [[ $integration == 1 ]]; then
    bash "$scaffold/tests/rounds/wrapper-integration.sh" --image "$image"
fi
