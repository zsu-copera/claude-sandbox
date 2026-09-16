#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $# == 2 || $# == 3 ]] || { echo 'Expected --image IMAGE [--observations-only|--context-only].' >&2; exit 2; }
[[ $1 == --image && -n $2 && $2 != -* ]] || { echo 'Expected --image IMAGE [--observations-only|--context-only].' >&2; exit 2; }
image=$2
observations_only=0
context_only=0
if [[ $# == 3 ]]; then
    case "$3" in
        --observations-only) observations_only=1;;
        --context-only) context_only=1;;
        *) echo 'Unknown integration selector.' >&2; exit 2;;
    esac
fi
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
if [[ $context_only == 1 ]]; then
    fixture context-inputs
    PATH=/unavailable /bin/bash "$wrapper" send --help > "$root/context-help.out"
    for flags in --brief --apply --handoff; do
        expect_failure env PATH=/unavailable /bin/bash "$wrapper" send TASK-1 \
            --handoff "$root/handoff.json" "$flags" invalid
    done
    bash "$wrapper" register --config "$root/config.json" > "$root/context-registered.json"
    for input in empty multiple oversized permissive symlink hardlink utf8 nul; do
        expect_failure bash "$wrapper" send TASK-1 --handoff "$root/handoff-$input.json"
    done
    expect_failure bash "$wrapper" send TASK-1 --handoff "$root/retained workspace/prj/README.md"
    expect_failure bash "$wrapper" send TASK-1 --handoff "$root/external source/README.md"
    expect_failure bash "$wrapper" send TASK-1 --handoff "$XDG_STATE_HOME/pera-sandbox-tasks/TASK-1/record.json"
    expect_failure bash "$wrapper" send TASK-1 --handoff "$root/handoff-large-invalid.json"
    grep -q 'Unexpected handoff fields' "$root/failure.err"
    fixture context-check-refusals
    bash "$wrapper" send TASK-1 --handoff "$root/handoff.json" > "$root/context-plan.json"
    plan=$(jq -er .planId "$root/context-plan.json")
    bash "$wrapper" send TASK-1 --apply "$plan" > "$root/context-applied.json"
    bash "$wrapper" send TASK-1 --handoff "$root/handoff.json" > "$root/context-unchanged.json"
    [[ $(jq -r .status "$root/context-unchanged.json") == unchanged ]]
    expect_failure bash "$wrapper" send TASK-1
    expect_failure bash "$wrapper" send TASK-1 --brief Documentation:review.md
    fixture context-prior-work
    bash "$wrapper" collect TASK-1 > "$root/context-collection-first.json"
    fixture context-metadata
    bash "$wrapper" send TASK-1 --handoff "$root/handoff.json" > "$root/context-metadata-plan.json"
    metadata_plan=$(jq -er .planId "$root/context-metadata-plan.json")
    fixture context-corrupt-original
    bash "$wrapper" send TASK-1 --apply "$metadata_plan" > "$root/context-metadata-applied.json"
    fixture context-check-metadata
    bash "$wrapper" collect TASK-1 > "$root/context-collection-metadata.json"
    fixture context-omit
    bash "$wrapper" send TASK-1 --handoff "$root/handoff.json" > "$root/context-needs-decision.json"
    fixture context-check-needs-decision
    fixture context-decide
    bash "$wrapper" send TASK-1 --handoff "$root/handoff.json" > "$root/context-second-plan.json"
    second=$(jq -er .planId "$root/context-second-plan.json")
    bash "$wrapper" send TASK-1 --apply "$second" > "$root/context-second-applied.json"
    fixture context-work
    bash "$wrapper" status TASK-1 > "$root/context-status.json"
    bash "$wrapper" collect TASK-1 > "$root/context-collection-work.json"
    fixture context-before-replay
    bash "$wrapper" send TASK-1 --apply "$plan" > "$root/context-replay.json"
    fixture context-check-final
    echo 'PASS context wrapper: private intake, v2 opt-in, carry-forward, exact plans, metadata-only collection and audited write-back.'
    exit 0
fi
round_wrapper="$scaffold/sandbox-round.sh"
bash "$round_wrapper" inspect --workspace "$root/retained workspace" --repository prj \
    --image "$image" > "$root/observation-legacy.json"
bash "$round_wrapper" inspect --workspace "$root/retained workspace" --repository prj \
    --path README.md --path missing.md --image "$image" > "$root/observation-clean.json"
source_probe="pera-task-fixture-$nonce-source-observation"
owned_names+=("$source_probe")
podman run --rm --pull=never --name "$source_probe" --label "io.pera.task-fixture=$nonce" \
    --network=none --cap-drop=all --security-opt=no-new-privileges --userns=keep-id \
    --http-proxy=false --unsetenv-all --env PATH=/usr/local/bin:/usr/bin:/bin \
    --env HOME=/nonexistent --entrypoint node \
    --mount "type=bind,src=$root/external source,dst=/repo,ro" \
    --mount "type=bind,src=$scaffold/tools/tasks,dst=/opt/tasks,ro" \
    --mount "type=bind,src=$scaffold/tools/rounds/rounds.js,dst=/opt/rounds.js,ro" \
    "$image" /opt/tasks/source.js source refs/heads/sandbox-fixture \
    'briefs/first brief.md' missing.md > "$root/observation-source.json"
fixture observation-dirty
bash "$round_wrapper" inspect --workspace "$root/retained workspace" --repository prj \
    --path README.md --image "$image" > "$root/observation-dirty.json"
fixture observation-restore
observation_blocker="pera-task-fixture-$nonce-observation-blocker"
owned_names+=("$observation_blocker")
podman run --detach --rm --pull=never --name "$observation_blocker" --label "io.pera.task-fixture=$nonce" \
    --network=none --cap-drop=all --security-opt=no-new-privileges --userns=keep-id \
    --http-proxy=false --unsetenv-all --entrypoint /usr/bin/sleep \
    --mount "type=bind,src=$root/retained workspace/prj,dst=/repo,ro" "$image" 300 > "$root/observation-blocker.id"
[[ $(podman container inspect "$observation_blocker" --format '{{.State.Running}}') == true ]]
bash "$round_wrapper" inspect --workspace "$root/retained workspace" --repository prj \
    --path README.md --path missing.md --image "$image" > "$root/observation-running.json"
podman rm --force "$observation_blocker" >/dev/null
expect_failure bash "$round_wrapper" inspect --workspace "$root/retained workspace" --repository prj \
    --path ../outside.md --image "$image"
fixture check-observations
echo 'PASS document observation wrapper: legacy shape, read-only source/target, absence and dirty/running guards.'
if [[ $observations_only == 1 ]]; then exit 0; fi

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
