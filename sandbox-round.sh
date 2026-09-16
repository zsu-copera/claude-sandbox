#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
    while IFS= read -r help_line; do printf '%s\n' "$help_line"; done <<'USAGE'
Usage:
  bash sandbox-round.sh export --source SOURCE_REPO --repository prj|Documentation
    --ref REF --task TASK --round ROUND --path FILE [--path FILE...]
    --output PACKET [--image IMAGE]
  bash sandbox-round.sh preview|apply|recover [--workspace WORKSPACE]
    --repository prj|Documentation --packet PACKET [--expected-head SHA]
    [--image IMAGE]
  bash sandbox-round.sh inspect [--workspace WORKSPACE]
    --repository prj|Documentation [--base SHA] [--path FILE ...] [--image IMAGE]
  bash sandbox-round.sh collect [--workspace WORKSPACE]
    --repository prj|Documentation --base SHA --work-base SHA
    --expected-head SHA --output NEW_DIRECTORY [--image IMAGE]

Defaults: workspace $HOME/pera-sandbox; image localhost/pera-sandbox.
Apply requires the full --expected-head from the reviewed preview; recover uses
the current HEAD shown in the pending-import diagnostic. Preview does not accept it.
Export selects committed .md/.txt blobs, not uncommitted edits or branch ancestry.
The output must be a NEW file outside both the source and the retained workspace.
Preview mounts the selected repository read-only; apply appends a round snapshot
and provenance commit without changing original files, branches or caches.
Packets must be outside the workspace. Only ordinary .git directories are supported.
The image must already exist: no pulls, rebuilds, preparation or network access.
Stop containers using this workspace before intake; other manual edits must also
remain stopped. The workspace lock coordinates this wrapper, not arbitrary tools.
Inspect reports known running containers without reading a live worktree. Collect
exports clean committed work read-only; it never pushes, merges or changes a repo.
Inspect --path returns bounded committed-document identities, not file contents.
Running, dirty, busy or recovery states return unobserved documents instead.
Without --path, the existing inspection output is unchanged.
Changed LFS pointers/attributes require separate artifact handling and block collect.

Windows: invoke this Bash entrypoint with wsl -d centos-9 -- bash SCRIPT ...
USAGE
}

die() { printf 'sandbox-round: %s\n' "$*" >&2; exit 1; }
if [[ $# == 1 && ( $1 == --help || $1 == -h ) ]]; then usage; exit 0; fi
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
mode=$1
shift
case "$mode" in export|preview|apply|recover|inspect|collect) ;; *) die 'Expected export, preview, apply, recover, inspect or collect (or --help).';; esac
if [[ $# == 1 && ( $1 == --help || $1 == -h ) ]]; then usage; exit 0; fi

declare -A options=()
paths=()
while [[ $# -gt 0 ]]; do
    flag=$1
    shift
    case "$flag" in
        --source|--repository|--ref|--task|--round|--path|--output|--image|--workspace|--packet|--expected-head|--base|--work-base) ;;
        *) die "Unknown argument: $flag";;
    esac
    [[ $# -gt 0 && -n $1 && $1 != --* ]] || die "Missing value for $flag."
    if [[ $flag == --path ]]; then
        paths+=("$1")
    else
        [[ ! -v "options[$flag]" ]] || die "Duplicate option: $flag"
        options["$flag"]=$1
    fi
    shift
done
repository=${options[--repository]:-}
[[ $repository == prj || $repository == Documentation ]] || die 'Select --repository prj or Documentation.'
if [[ $mode == export ]]; then
    for flag in --source --ref --task --round --output; do
        [[ -v "options[$flag]" ]] || die "Export requires $flag."
    done
    [[ ${#paths[@]} -gt 0 ]] || die 'Export requires at least one --path.'
    for flag in --workspace --packet --expected-head --base --work-base; do
        [[ ! -v "options[$flag]" ]] || die "$flag is not valid for export."
    done
else
    [[ ${#paths[@]} == 0 || $mode == inspect ]] || die '--path is only valid for export or inspect.'
    for flag in --source --ref --task --round; do
        [[ ! -v "options[$flag]" ]] || die "$flag is only valid for export."
    done
    if [[ $mode == collect ]]; then
        [[ ! -v 'options[--packet]' ]] || die 'Collect does not accept --packet.'
        for flag in --base --work-base --expected-head --output; do
            [[ -v "options[$flag]" ]] || die "Collect requires $flag."
        done
    elif [[ $mode == inspect ]]; then
        for flag in --packet --expected-head --work-base --output; do
            [[ ! -v "options[$flag]" ]] || die "$flag is not valid for inspect."
        done
    else
        [[ -v 'options[--packet]' ]] || die 'Import requires --packet.'
        for flag in --base --work-base --output; do
            [[ ! -v "options[$flag]" ]] || die "$flag is not valid for import."
        done
        if [[ $mode != preview ]]; then
            [[ -v 'options[--expected-head]' ]] || die 'Apply/recover requires --expected-head.'
        else
            [[ ! -v 'options[--expected-head]' ]] || die 'Preview does not accept --expected-head.'
        fi
    fi
fi
for flag in --expected-head --base --work-base; do
    if [[ -v "options[$flag]" ]]; then
        [[ ${options[$flag]} =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
            || die "$flag must be a full lowercase Git object ID (40 or 64 characters), not a placeholder or abbreviated hash."
    fi
done
if [[ $mode == inspect && ${#paths[@]} -gt 128 ]]; then
    die 'Inspect supports at most 128 document paths.'
fi

for program in podman jq flock realpath sha256sum stat dirname basename mkdir chmod ln rm mv id; do
    command -v "$program" >/dev/null 2>&1 || die "Required WSL command is missing: $program"
done
[[ $(id -u) != 0 ]] || die 'Run this wrapper as the normal rootless container user.'
[[ -n ${HOME:-} && $HOME == /* ]] || die 'HOME must be an absolute path.'
inspect_paths='[]'
if [[ $mode == inspect && ${#paths[@]} -gt 0 ]]; then
    inspect_paths=$(jq -cn --args '$ARGS.positional' -- "${paths[@]}")
fi

mount_path() {
    [[ $1 != *[,:]* && $1 != *$'\n'* && $1 != *$'\r'* ]] || die 'Mount paths cannot contain commas, colons or newlines.'
}
inside() { [[ $2 == "$1" || $2 == "$1/"* || $1 == / ]]; }
overlaps() { inside "$1" "$2" || inside "$2" "$1"; }
resolve() {
    local input=$1 lexical canonical
    mount_path "$input"
    lexical=$(realpath -ms -- "$input") || die 'Cannot normalize path.'
    canonical=$(realpath -m -- "$input") || die 'Cannot resolve path.'
    [[ $lexical == "$canonical" ]] || die 'Symlinked paths are not supported.'
    mount_path "$canonical"
    printf '%s\n' "$canonical"
}
scaffold=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")")
core=$(resolve "$scaffold/tools/rounds/rounds.js")
[[ -f $core && ! -L $core ]] || die 'Trusted rounds helper is missing.'
home=$(realpath -e -- "$HOME")
workspace=$(resolve "${options[--workspace]:-$HOME/pera-sandbox}")
[[ $workspace != / && $workspace != "$home" ]] || die 'Root and home cannot be workspaces.'
! inside "$workspace" "$scaffold" || die 'The scaffold or its parent cannot be the workspace.'
image=${options[--image]:-localhost/pera-sandbox}
[[ $image != -* && $image != *$'\n'* && $image != *$'\r'* ]] || die 'Invalid image name.'
podman image exists "$image" || die 'Required image is not present; build it separately.'
image_user=$(podman image inspect "$image" --format '{{.Config.User}}') || die 'Cannot inspect the image.'
[[ -n $image_user && $image_user != root && $image_user != root:* && $image_user != 0 && $image_user != 0:* ]] \
    || die 'The selected image must declare a non-root default user.'

nonce=
IFS= read -r nonce < /proc/sys/kernel/random/uuid
[[ $nonce =~ ^[a-f0-9-]{36}$ ]] || die 'Cannot allocate an operation identifier.'
container_name="pera-round-$nonce"
partial=
collection_partial=
container_attempted=0
cleanup() {
    local status=$? label probe_status cleanup_failed=0
    trap - EXIT HUP INT TERM
    if [[ $container_attempted == 1 ]]; then
        if podman container exists "$container_name"; then
            if label=$(podman container inspect "$container_name" --format '{{index .Config.Labels "io.pera.round-operation"}}'); then
                if [[ $label == "$nonce" ]]; then
                    if ! podman rm --force "$container_name" >/dev/null; then cleanup_failed=1; fi
                else
                    printf 'sandbox-round: refusing cleanup of a container with a different owner label.\n' >&2
                    cleanup_failed=1
                fi
            else
                cleanup_failed=1
            fi
        else
            probe_status=$?
            if [[ $probe_status != 1 ]]; then
                printf 'sandbox-round: cannot establish whether the operation container needs cleanup.\n' >&2
                cleanup_failed=1
            fi
        fi
    fi
    if [[ -n $partial ]] && ! rm -f -- "$partial"; then cleanup_failed=1; fi
    if [[ -n $collection_partial ]]; then
        if [[ $cleanup_failed == 0 ]]; then
            if ! rm -rf -- "$collection_partial"; then cleanup_failed=1; fi
        else
            printf 'sandbox-round: collection staging retained for inspection: %s\n' "$collection_partial" >&2
        fi
    fi
    if [[ $cleanup_failed == 1 && $status == 0 ]]; then status=1; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

container=(podman run --rm --pull=never --name "$container_name"
    --label "io.pera.round-operation=$nonce" --network=none --cap-drop=all
    --security-opt=no-new-privileges --userns=keep-id --http-proxy=false
    --unsetenv-all --env PATH=/usr/local/bin:/usr/bin:/bin --env HOME=/nonexistent
    --entrypoint /bin/bash --mount "type=bind,src=$core,dst=/opt/rounds.js,ro")
bootstrap='set -euo pipefail
[[ $(id -u) != 0 ]]
IFS=: read -r _ _ _ _ _ workhome _ <<< "$(getent passwd "$(id -u)")"
[[ -n $workhome && -d $workhome ]]
cd -- "$workhome"
mkdir round-work
cd round-work
export TMPDIR="$PWD"
exec node "$@"'

if [[ $mode == export ]]; then
    source=$(resolve "${options[--source]}")
    [[ -d $source && -d $source/.git && ! -L $source/.git ]] || die 'Source requires an ordinary .git directory.'
    [[ $source != / && $source != "$home" && $source != "$scaffold" ]] || die 'Unsafe source repository root.'
    ! overlaps "$source" "$workspace" || die 'Export source must be outside the retained workspace.'
    output=$(resolve "${options[--output]}")
    [[ -d $(dirname -- "$output") && ! -e $output && ! -L $output ]] || die 'Output requires an existing parent and a new filename.'
    ! inside "$source" "$output" || die 'Output must be outside the source repository.'
    ! inside "$workspace" "$output" || die 'Output must be outside the retained workspace.'
    [[ $output != "$core" ]] || die 'Output cannot replace the trusted helper.'
    candidate="$(dirname -- "$output")/.$(basename -- "$output").round-$nonce.part"
    (set -o noclobber; : > "$candidate") || die 'Cannot reserve packet staging file.'
    partial=$candidate
    args=(export --root /repo --repository "$repository" --ref "${options[--ref]}"
        --task "${options[--task]}" --round "${options[--round]}")
    for selected in "${paths[@]}"; do args+=(--path "$selected"); done
    container_attempted=1
    "${container[@]}" --mount "type=bind,src=$source,dst=/repo,ro" "$image" \
        -c "$bootstrap" rounds /opt/rounds.js "${args[@]}" > "$partial"
    # A hard link publishes the complete file without ever replacing an existing path.
    ln -T -- "$partial" "$output" || die 'Packet publication failed; output was not replaced.'
    rm -f -- "$partial"
    partial=
    printf 'Exported packet: %s\n' "$output" >&2
    exit 0
fi

[[ -d $workspace ]] || die 'Retained workspace does not exist.'
target=$(resolve "$workspace/$repository")
[[ -d $target && -d $target/.git && ! -L $target/.git ]] || die 'Selected target requires an ordinary .git directory.'
packet=
if [[ $mode != inspect && $mode != collect ]]; then
    packet=$(resolve "${options[--packet]}")
    [[ -f $packet && ! -L $packet ]] || die 'Packet must be a regular file.'
    ! inside "$workspace" "$packet" || die 'Packet must be outside the retained workspace.'
    [[ $packet != "$core" ]] || die 'Packet cannot be the trusted helper.'
fi
state_base=$(resolve "${XDG_STATE_HOME:-$HOME/.local/state}/pera-sandbox-rounds")
! overlaps "$state_base" "$workspace" || die 'State must be outside the workspace.'
if [[ -n $packet ]]; then
    ! overlaps "$state_base" "$packet" || die 'State must not overlap the packet.'
fi
! overlaps "$state_base" "$scaffold" || die 'State must be outside the trusted scaffold.'
if [[ $mode == collect ]]; then
    output=$(resolve "${options[--output]}")
    [[ -d $(dirname -- "$output") && ! -e $output && ! -L $output ]] || die 'Collect requires a new directory with an existing parent.'
    for protected in "$workspace" "$scaffold" "$state_base"; do
        ! overlaps "$protected" "$output" || die 'Collection output overlaps protected data.'
    done
fi

private_directory() {
    local directory=$1
    mkdir -p -m 700 -- "$directory"
    [[ $(resolve "$directory") == "$directory" && -d $directory && ! -L $directory ]] || die 'Unsafe state directory.'
    [[ $(stat -c %u -- "$directory") == "$(id -u)" && $(stat -c %a -- "$directory") == 700 ]] \
        || die 'State directories must be owned by the current user with mode 700.'
}
private_directory "$state_base"
target_hash=$(printf '%s' "$target" | sha256sum)
target_hash=${target_hash%% *}
workspace_hash=$(printf '%s' "$workspace" | sha256sum)
workspace_hash=${workspace_hash%% *}
state="$state_base/$target_hash"
private_directory "$state"
lock="$state_base/workspace-$workspace_hash.lock"
[[ ! -L $lock && ( ! -e $lock || -f $lock ) ]] || die 'Unsafe workspace lock.'
if [[ -e $lock ]]; then
    [[ $(stat -c %u -- "$lock") == "$(id -u)" && $(stat -c %h -- "$lock") == 1 ]] || die 'Unsafe workspace lock ownership.'
fi
exec {lock_fd}>>"$lock"
flock --exclusive "$lock_fd"

# Inspect only: never stop another process or container. Recheck after taking the lock.
running=$(podman ps --filter status=running --format '{{.ID}}') || die 'Cannot list running containers.'
if [[ -n $running ]]; then
    mapfile -t running_ids <<< "$running"
    metadata=$(podman container inspect "${running_ids[@]}") || die 'Cannot inspect running containers.'
    jq -e 'type == "array" and all(.[]; (.Mounts | type == "array") and
        all(.Mounts[]; .Type != "bind" or (.Source | type == "string" and startswith("/"))))' \
        <<< "$metadata" >/dev/null || die 'Unexpected container mount metadata.'
    while IFS= read -r -d '' mounted; do
        mounted=$(realpath -m -- "$mounted") || die 'Cannot resolve an active container mount.'
        if overlaps "$workspace" "$mounted"; then
            if [[ $mode == inspect ]]; then
                jq -n --arg repository "$repository" --arg mount "$mounted" --argjson paths "$inspect_paths" \
                    '{status:"running",repository:$repository,observedWorktree:false,containers:[{mount:$mount}]}
                    + (if ($paths | length) > 0 then
                        {documents: ($paths | map({path:.,observation:{state:"unobserved",reason:"running"}}))}
                       else {} end)'
                exit 0
            fi
            die 'A running container mounts this workspace. Stop it before intake or collection.'
        fi
    done < <(jq -j '.[] | .Mounts[] | select(.Type == "bind") | .Source, "\u0000"' <<< "$metadata")
fi

if [[ $mode == inspect ]]; then
    args=(inspect --root /repo --state /state --repository "$repository")
    [[ ! -v 'options[--base]' ]] || args+=(--base "${options[--base]}")
    for selected in "${paths[@]}"; do args+=(--path "$selected"); done
    container_attempted=1
    "${container[@]}" --mount "type=bind,src=$target,dst=/repo,ro" \
        --mount "type=bind,src=$state,dst=/state,ro" "$image" -c "$bootstrap" \
        rounds /opt/rounds.js "${args[@]}"
    exit 0
fi
if [[ $mode == collect ]]; then
    candidate="$output.stage-$nonce"
    mkdir -m 700 -- "$candidate"
    collection_partial=$candidate
    container_attempted=1
    "${container[@]}" --mount "type=bind,src=$target,dst=/repo,ro" \
        --mount "type=bind,src=$state,dst=/state,ro" \
        --mount "type=bind,src=$collection_partial,dst=/out,rw" \
        "$image" -c "$bootstrap" rounds /opt/rounds.js collect --root /repo --state /state \
        --repository "$repository" --base "${options[--base]}" --work-base "${options[--work-base]}" \
        --expected-head "${options[--expected-head]}" --output /out >/dev/null
    mv --no-clobber --no-target-directory -- "$collection_partial" "$output"
    [[ ! -e $collection_partial ]] || die 'Collection destination appeared; existing output was not replaced.'
    collection_partial=
    jq . "$output/manifest.json"
    exit 0
fi
access=rw
[[ $mode != preview ]] || access=ro
args=("$mode" --root /repo --state /state --repository "$repository" --packet /input/packet.json)
[[ ! -v 'options[--expected-head]' ]] || args+=(--expected-head "${options[--expected-head]}")
container_attempted=1
"${container[@]}" --mount "type=bind,src=$target,dst=/repo,$access" \
    --mount "type=bind,src=$packet,dst=/input/packet.json,ro" \
    --mount "type=bind,src=$state,dst=/state,rw" "$image" -c "$bootstrap" rounds /opt/rounds.js "${args[@]}"
