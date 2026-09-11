#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $# == 2 && $1 == --image && -n $2 && $2 != -* ]] || { echo 'Expected --image IMAGE.' >&2; exit 2; }
image=$2
tests=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")")
source "$tests/mount-guard.sh"
scaffold=$(realpath -e -- "$tests/../..")
wrapper="$scaffold/sandbox-round.sh"
cwd=$(pwd -P)
case "$cwd" in
    "$scaffold"|"$scaffold"/*|"$HOME/pera-sandbox"|"$HOME/pera-sandbox"/*|/|/mnt|/mnt/*)
        echo 'Run wrapper integration from an ordinary WSL directory outside the scaffold/sandbox.' >&2
        exit 1;;
esac
[[ $cwd != *[,:]* && $cwd != *$'\n'* && $cwd != *$'\r'* ]] || { echo 'Unsafe fixture parent.' >&2; exit 1; }
for program in jq podman sha256sum stat; do command -v "$program" >/dev/null || exit 1; done
IFS= read -r nonce < /proc/sys/kernel/random/uuid
root="$cwd/.rounds-fixture-$nonce"
mkdir -m 700 -- "$root"
owned_names=()
cleanup() {
    local status=$? name label probe_status cleanup_failed=0
    trap - EXIT HUP INT TERM
    for name in "${owned_names[@]}"; do
        if podman container exists "$name"; then
            if label=$(podman container inspect "$name" --format '{{index .Config.Labels "io.pera.round-fixture"}}'); then
                if [[ $label == "$nonce" ]]; then
                    if ! podman rm --force "$name" >/dev/null; then cleanup_failed=1; fi
                else
                    echo 'Refusing cleanup of an unrelated fixture container.' >&2
                    cleanup_failed=1
                fi
            else
                cleanup_failed=1
            fi
        else
            probe_status=$?
            if [[ $probe_status != 1 ]]; then cleanup_failed=1; fi
        fi
    done
    # Wrapper operations have their own nonce labels, not the fixture label.
    # Keep the data if any surviving container still mounts it, or inspection fails.
    if ! round_fixture_unmounted "$root"; then cleanup_failed=1; fi
    if [[ $cleanup_failed == 0 ]]; then
        if ! rm -rf -- "$root"; then cleanup_failed=1; fi
    else
        printf 'Fixture retained because container cleanup failed: %s\n' "$root" >&2
    fi
    if [[ $cleanup_failed == 1 && $status == 0 ]]; then status=1; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
counter=0
fixture() {
    counter=$((counter + 1))
    local name="pera-round-fixture-$nonce-$counter"
    owned_names+=("$name")
    podman run --rm --pull=never --name "$name" --label "io.pera.round-fixture=$nonce" \
        --network=none --cap-drop=all --security-opt=no-new-privileges --userns=keep-id \
        --http-proxy=false --unsetenv-all --env PATH=/usr/local/bin:/usr/bin:/bin \
        --env HOME=/nonexistent --env TMPDIR=. --workdir /fixtures --entrypoint node \
        --mount "type=bind,src=$root,dst=/fixtures,rw" --mount "type=bind,src=$tests,dst=/tests,ro" \
        "$image" /tests/integration-fixture.js "$1" /fixtures
}
expect_failure() {
    if "$@" > "$root/failure.out" 2> "$root/failure.err"; then
        printf 'Expected failure: %s\n' "$*" >&2
        exit 1
    fi
}
fixture setup
source="$root/external source"
workspace="$root/retained workspace"
packet="$root/packets/round one.json"
head=$(jq -r .baseHead "$root/fixture.json")
export XDG_STATE_HOME="$root/operator-state"

# Help and malformed CLI calls must not even require the container executable.
PATH=/unavailable /bin/bash "$wrapper" --help > "$root/help.out"
expect_failure env PATH=/unavailable /bin/bash "$wrapper" preview --unknown yes
expect_failure env PATH=/unavailable /bin/bash "$wrapper" preview --repository prj \
    --packet "$packet" --expected-head "$head"
grep -q 'Preview does not accept --expected-head' "$root/failure.err"
expect_failure bash "$wrapper" apply --workspace "$workspace" --repository prj --packet "$packet"
expect_failure bash "$wrapper" preview --repository prj --repository prj --packet "$packet"
bash "$wrapper" export --source "$source" --repository prj --ref HEAD --task TASK_42 \
    --round R1 --path 'briefs/first brief.md' --path briefs/second.txt --output "$packet" --image "$image"
[[ $(stat -c %a -- "$packet") == 600 ]]
packet_hash=$(sha256sum -- "$packet")
expect_failure bash "$wrapper" export --source "$source" --repository prj --ref HEAD --task TASK_42 \
    --round R1 --path 'briefs/first brief.md' --output "$packet" --image "$image"
[[ $(sha256sum -- "$packet") == "$packet_hash" ]]
expect_failure bash "$wrapper" export --source "$source" --repository prj --ref HEAD --task TASK_42 \
    --round R1 --path 'briefs/first brief.md' --output "$source/forbidden.json" --image "$image"
expect_failure bash "$wrapper" export --source "$source" --repository prj --ref HEAD --task TASK_42 \
    --round R1 --path missing.md --output "$root/packets/failed.json" --image "$image"
[[ ! -e $root/packets/failed.json ]]
shopt -s nullglob
partials=("$root/packets"/.*.part)
[[ ${#partials[@]} == 0 ]]
fixture preview-before
bash "$wrapper" preview --workspace "$workspace" --repository prj --packet "$packet" --image "$image" > "$root/preview.json"
[[ $(jq -r .status "$root/preview.json") == ready && $(jq -r .head "$root/preview.json") == "$head" ]]
fixture preview-after
expect_failure bash "$wrapper" apply --workspace "$workspace" --repository prj --packet "$packet" \
    --expected-head 0000000000000000000000000000000000000000 --image "$image"
expect_failure bash "$wrapper" preview --workspace "$workspace" --repository Documentation --packet "$packet" --image "$image"
bash "$wrapper" apply --workspace "$workspace" --repository prj --packet "$packet" \
    --expected-head "$head" --image "$image" > "$root/applied.json"
[[ $(jq -r .status "$root/applied.json") == imported ]]
first_head=$(jq -r .head "$root/applied.json")
fixture check-first
bash "$wrapper" apply --workspace "$workspace" --repository prj --packet "$packet" \
    --expected-head "$first_head" --image "$image" > "$root/replay.json"
[[ $(jq -r .status "$root/replay.json") == already-imported ]]
second_packet="$root/packets/round two.json"
bash "$wrapper" export --source "$source" --repository prj --ref HEAD --task TASK_42 \
    --round R2 --path 'briefs/first brief.md' --path briefs/second.txt --output "$second_packet" --image "$image"
bash "$wrapper" preview --workspace "$workspace" --repository prj --packet "$second_packet" --image "$image" > "$root/second-preview.json"
[[ $(jq -r .head "$root/second-preview.json") == "$first_head" ]]
bash "$wrapper" apply --workspace "$workspace" --repository prj --packet "$second_packet" \
    --expected-head "$first_head" --image "$image" > "$root/second-applied.json"
fixture check-second
fixture dirty
expect_failure bash "$wrapper" preview --workspace "$workspace" --repository prj --packet "$packet" --image "$image"
fixture clear-dirty
fixture invalid-packet
expect_failure bash "$wrapper" preview --workspace "$workspace" --repository prj --packet "$root/packets/invalid.json" --image "$image"
ln -s -- "$workspace" "$root/linked-workspace"
expect_failure bash "$wrapper" preview --workspace "$root/linked-workspace" --repository prj --packet "$packet" --image "$image"
expect_failure bash "$wrapper" preview --workspace "$workspace" --repository prj --packet "$workspace/prj/README.md" --image "$image"
expect_failure bash "$wrapper" preview --workspace "$HOME" --repository prj --packet "$packet" --image "$image"
expect_failure bash "$wrapper" preview --workspace "$scaffold" --repository prj --packet "$packet" --image "$image"
expect_failure bash "$wrapper" preview --workspace "$root/unsafe,workspace" --repository prj --packet "$packet" --image "$image"

blocker="pera-round-fixture-$nonce-blocker"
owned_names+=("$blocker")
podman run --detach --rm --pull=never --name "$blocker" --label "io.pera.round-fixture=$nonce" \
    --network=none --cap-drop=all --security-opt=no-new-privileges --userns=keep-id \
    --http-proxy=false --unsetenv-all --entrypoint /usr/bin/sleep \
    --mount "type=bind,src=$workspace/prj,dst=/repo,ro" "$image" 300 > "$root/blocker.id"
[[ $(podman container inspect "$blocker" --format '{{.State.Running}}') == true ]]
expect_failure bash "$wrapper" preview --workspace "$workspace" --repository prj --packet "$packet" --image "$image"
grep -q 'running container mounts this workspace' "$root/failure.err"
[[ $(podman container inspect "$blocker" --format '{{.State.Running}}') == true ]]
podman rm --force "$blocker" >/dev/null
bash "$wrapper" preview --workspace "$workspace" --repository prj --packet "$packet" --image "$image" > "$root/after-blocker.json"
[[ $(jq -r .status "$root/after-blocker.json") == already-imported ]]
[[ $(sha256sum -- "$packet") == "$packet_hash" ]]
echo 'PASS wrapper integration: two rounds, retained state, refusals, read-only preview and active-container guard.'
