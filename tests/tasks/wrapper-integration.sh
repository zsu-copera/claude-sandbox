#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $# == 2 && $1 == --image && -n $2 && $2 != -* ]] || { echo 'Expected --image IMAGE.' >&2; exit 2; }
image=$2
tests=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")")
scaffold=$(realpath -e -- "$tests/../..")
source "$scaffold/tests/rounds/mount-guard.sh"
wrapper="$scaffold/sandbox-task.sh"
cwd=$(pwd -P)
case "$cwd" in
    "$scaffold"|"$scaffold"/*|"$HOME/pera-sandbox"|"$HOME/pera-sandbox"/*|/|/mnt|/mnt/*)
        echo 'Run integration from an ordinary WSL directory outside scaffold/retained workspace.' >&2
        exit 1;;
esac
[[ $cwd != *[,:]* && $cwd != *$'\n'* && $cwd != *$'\r'* ]] || { echo 'Unsafe fixture parent.' >&2; exit 1; }
for program in jq podman sha256sum stat; do command -v "$program" >/dev/null || exit 1; done
IFS= read -r nonce < /proc/sys/kernel/random/uuid
root="$cwd/.tasks-fixture-$nonce"
mkdir -m 700 -- "$root"
owned_names=()
cleanup() {
    local status=$? name label code failed=0
    trap - EXIT HUP INT TERM
    for name in "${owned_names[@]}"; do
        if podman container exists "$name"; then
            if label=$(podman container inspect "$name" --format '{{index .Config.Labels "io.pera.task-fixture"}}'); then
                if [[ $label == "$nonce" ]]; then
                    if ! podman rm --force "$name" >/dev/null; then failed=1; fi
                else failed=1; fi
            else failed=1; fi
        else code=$?; if [[ $code != 1 ]]; then failed=1; fi; fi
    done
    if ! round_fixture_unmounted "$root"; then failed=1; fi
    if [[ $failed == 0 ]]; then
        if ! rm -rf -- "$root"; then failed=1; fi
    else printf 'Task fixture retained after unknown container/mount state: %s\n' "$root" >&2; fi
    if [[ $failed == 1 && $status == 0 ]]; then status=1; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
counter=0
fixture() {
    counter=$((counter + 1))
    local name="pera-task-fixture-$nonce-$counter"
    owned_names+=("$name")
    podman run --rm --pull=never --name "$name" --label "io.pera.task-fixture=$nonce" \
        --network=none --cap-drop=all --security-opt=no-new-privileges --userns=keep-id \
        --http-proxy=false --unsetenv-all --env PATH=/usr/local/bin:/usr/bin:/bin \
        --env HOME=/nonexistent --env TMPDIR=. --workdir /fixtures --entrypoint node \
        --mount "type=bind,src=$root,dst=/fixtures,rw" \
        --mount "type=bind,src=$scaffold/tests,dst=/tests,ro" \
        "$image" /tests/tasks/integration-fixture.js "$1" "$root" "$image"
}
expect_failure() {
    if "$@" > "$root/failure.out" 2> "$root/failure.err"; then
        echo 'Expected task action to fail.' >&2
        exit 1
    fi
    [[ ! -s $root/failure.out && -s $root/failure.err ]] || { echo 'Failure must have stderr and no success JSON.' >&2; exit 1; }
}
fixture setup
export XDG_STATE_HOME="$root/operator-state"
PATH=/unavailable /bin/bash "$wrapper" --help > "$root/help.out"
PATH=/unavailable /bin/bash "$wrapper" send --help > "$root/send-help.out"
expect_failure env PATH=/unavailable /bin/bash "$wrapper" send TASK-1 --unknown bad
expect_failure env PATH=/unavailable /bin/bash "$wrapper" send TASK-1 --apply short
expect_failure env PATH=/unavailable /bin/bash "$wrapper" send TASK-1 --brief prj:a.md --apply aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_failure env PATH=/unavailable /bin/bash "$wrapper" status TASK-1 --image invalid
expect_failure env PATH=/unavailable /bin/bash "$wrapper" register --config one --config two
bash "$wrapper" register --config "$root/config.json" > "$root/registered.json"
bash "$wrapper" register --config "$root/config.json" > "$root/registered-again.json"
[[ $(jq -r .status "$root/registered.json") == registered ]]
[[ $(jq -r .status "$root/registered-again.json") == already-registered ]]
[[ $(stat -c %a -- "$XDG_STATE_HOME/pera-sandbox-tasks/TASK-1") == 700 ]]
bash "$wrapper" send TASK-1 > "$root/plan.json"
bash "$wrapper" send TASK-1 > "$root/repeat.json"
fixture check-plan
plan=$(jq -r .planId "$root/plan.json")
bash "$wrapper" send TASK-1 --apply "$plan" > "$root/applied.json"
bash "$wrapper" send TASK-1 --apply "$plan" > "$root/reapplied.json"
[[ $(jq -r .status "$root/reapplied.json") == already-applied ]]
fixture check-first
bash "$wrapper" send TASK-1 > "$root/unchanged.json"
[[ $(jq -r .status "$root/unchanged.json") == unchanged ]]
fixture unrelated
bash "$wrapper" send TASK-1 > "$root/unrelated.json"
[[ $(jq -r .status "$root/unrelated.json") == unchanged ]]
fixture docs-update
bash "$wrapper" send TASK-1 > "$root/second-plan.json"
second=$(jq -r .planId "$root/second-plan.json")
bash "$wrapper" send TASK-1 --apply "$second" > "$root/second-applied.json"
fixture check-second
fixture result
bash "$wrapper" send TASK-1 --apply "$plan" > "$root/replayed-after-work.json"
fixture check-replayed-work
bash "$wrapper" collect TASK-1 > "$root/collected.json"
bash "$wrapper" collect TASK-1 > "$root/collected-again.json"
fixture check-collection
fixture dirty
bash "$wrapper" status TASK-1 > "$root/dirty-status.json"
[[ $(jq -r .status "$root/dirty-status.json") == blocked ]]
expect_failure bash "$wrapper" collect TASK-1
fixture clear-dirty

blocker="pera-task-fixture-$nonce-blocker"
owned_names+=("$blocker")
podman run --detach --rm --pull=never --name "$blocker" --label "io.pera.task-fixture=$nonce" \
    --network=none --cap-drop=all --security-opt=no-new-privileges --userns=keep-id \
    --http-proxy=false --unsetenv-all --entrypoint /usr/bin/sleep \
    --mount "type=bind,src=$root/retained workspace/prj,dst=/repo,ro" "$image" 300 > "$root/blocker.id"
[[ $(podman container inspect "$blocker" --format '{{.State.Running}}') == true ]]
bash "$wrapper" status TASK-1 > "$root/running.json"
[[ $(jq -r .status "$root/running.json") == running ]]
jq -e '.inspected.prj.head == null and .inspected.prj.changes == null' "$root/running.json" >/dev/null
expect_failure bash "$wrapper" collect TASK-1
podman rm --force "$blocker" >/dev/null
bash "$wrapper" status TASK-1 > "$root/restored-status.json"
[[ $(jq -r .status "$root/restored-status.json") == ready ]]
fixture tamper-input
expect_failure bash "$wrapper" send TASK-1
grep -q 'Retained handoff integrity' "$root/failure.err"
expect_failure bash "$wrapper" send TASK-1 --apply "$plan"
grep -q 'Retained handoff integrity' "$root/failure.err"
bash "$wrapper" status TASK-1 > "$root/input-status.json"
fixture check-refused-tamper
echo 'PASS task wrapper integration: attachment, exact plans, current replay validity, retained-input guards, paired/single sends, collection and dirty/running guards.'
