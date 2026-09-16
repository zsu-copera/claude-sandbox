#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
    while IFS= read -r line; do printf '%s\n' "$line"; done <<'USAGE'
Usage:
  bash sandbox-task.sh register --config FILE
  bash sandbox-task.sh send TASK [--brief REPO:RELATIVE_PATH ...]
  bash sandbox-task.sh send TASK --handoff FILE
  bash sandbox-task.sh send TASK --apply PLAN_ID
  bash sandbox-task.sh status TASK
  bash sandbox-task.sh collect TASK

All successful actions emit JSON. No interactive prompts, host Node, image pulls,
preparation, source commits, agent launches, checkout, push or merge.
Send only publishes a plan. The outside agent summarizes its exact actions in
chat, obtains human approval, then invokes send TASK --apply PLAN_ID.
The plan ID binds exact actions; it is not proof of human identity.

Closed register config schema (all fields required):
{"version":1,"task":"TASK-1","workspace":"/absolute/retained-workspace",
 "image":"localhost/pera-sandbox","profiles":["agencyWWW"],
 "repositories":{
   "prj":{"source":"/absolute/external/prj","ref":"refs/heads/task-branch",
     "auditBase":"FULL_LOWERCASE_40_OR_64_COMMIT_ID","briefs":["docs/task.md"]},
   "Documentation":{"source":"/absolute/external/Documentation",
     "ref":"refs/heads/task-docs","auditBase":"FULL_LOWERCASE_40_OR_64_COMMIT_ID",
     "briefs":[]}}}

Both auditBase commits must be ancestors of their workspace repository HEADs.
Profiles are informational, not evidence of complete warmed dependencies.
Paths must be real, absolute Linux paths, not symlinks. Ordinary .git directories
only. Source branches are explicit; ambient checkout and uncommitted briefs are
never imported. --brief overrides the whole selection with literal .md/.txt paths.
Identical registration is idempotent; changed definitions need a new task ID.
Task state is private under ${XDG_STATE_HOME:-$HOME/.local/state}/pera-sandbox-tasks.
It must not overlap the workspace, either source, or this scaffold.
Image IDs, both target heads/branches, source commits and packet bytes are bound
to each plan. Only changed selected briefs create imports; repos without changed
briefs keep their head. R numbers reserve existing round/checkpoint namespaces.
Partial sends require same-plan retry; foreign recovery is never overwritten.
Collections contain full changes.patch, focused work.patch, history.bundle when
needed, checksums, explicit incremental/work bases and input provenance.
Bundles are unreviewed; collection neither applies them nor runs application tests.

--handoff explicitly opts a task into context-aware sends. FILE must be an absolute
non-symlink, owned mode-600 single-link file in an owned mode-700 directory, outside
the workspace, source repos, scaffold and controller state. Maximum size: 1 MiB.
It is captured once; apply reads the approved plan, never the editable original.
Do not combine --handoff with --brief or --apply.

Closed handoff schema:
{"version":1,"briefs":{"prj":[],"Documentation":["review.md"]},
 "documents":[{"repository":"Documentation","path":"README.md","role":"shared",
   "reason":"Both sides update task status"}],
 "retire":[],"decisions":[]}
Document roles are reference, shared and host-owned. Declarations carry forward;
retirements explicitly name repository/path/reason. Decisions name
repository/path/action/reason. Actions are reconcile-in-sandbox, retain-sandbox,
defer-to-host or initialize-from-source. They are instructions, not automatic edits.
Missing decisions produce needs-decision with no applicable plan ID.
Successful context planning upgrades private task metadata to version 2;
subsequent sends require --handoff. Existing registration config is unchanged.
Context-only approval creates no import round and does not move audit/work bases.
USAGE
}
die() { printf 'sandbox-task: %s\n' "$*" >&2; exit 1; }
if [[ $# == 1 && ( $1 == --help || $1 == -h ) ]]; then usage; exit 0; fi
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
mode=$1
shift
case "$mode" in register|send|status|collect) ;; *) die 'Expected register, send, status or collect.';; esac
if [[ $# == 1 && ( $1 == --help || $1 == -h ) ]]; then usage; exit 0; fi
task=
config_file=
plan_id=
handoff_file=
briefs=()
if [[ $mode == register ]]; then
    [[ $# == 2 && $1 == --config && -n $2 && $2 != --* ]] || die 'Register requires exactly --config FILE.'
    config_file=$2
else
    [[ $# -gt 0 && $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || die 'Expected a conservative 1-64 character ASCII task ID.'
    task=$1
    shift
    while [[ $# -gt 0 ]]; do
        [[ $mode == send ]] || die 'Status/collect do not accept extra flags.'
        [[ $# -gt 1 && -n $2 && $2 != --* ]] || die 'Missing send option value.'
        case "$1" in
            --brief)
                [[ -z $plan_id && -z $handoff_file && $2 =~ ^(prj|Documentation):.+ ]] || die '--brief requires REPO:PATH and cannot accompany --apply or --handoff.'
                briefs+=("$2");;
            --handoff)
                [[ -z $handoff_file && -z $plan_id && ${#briefs[@]} == 0 ]] || die '--handoff requires one FILE and cannot accompany --brief or --apply.'
                handoff_file=$2;;
            --apply)
                [[ -z $plan_id && -z $handoff_file && ${#briefs[@]} == 0 && $2 =~ ^[0-9a-f]{64}$ ]] || die '--apply requires one exact plan ID and no --brief or --handoff.'
                plan_id=$2;;
            *) die "Unknown argument: $1";;
        esac
        shift 2
    done
    if [[ -n $handoff_file ]]; then
        command -v head >/dev/null 2>&1 || die 'Required WSL command is missing: head'
    fi
fi
for program in podman jq flock realpath stat id mkdir chmod mv rm sleep dirname; do
    command -v "$program" >/dev/null 2>&1 || die "Required WSL command is missing: $program"
done
[[ $(id -u) != 0 ]] || die 'Run as the normal rootless container user.'
[[ -n ${HOME:-} && $HOME == /* ]] || die 'HOME must be absolute.'
inside() { [[ $2 == "$1" || $2 == "$1/"* || $1 == / ]]; }
overlaps() { inside "$1" "$2" || inside "$2" "$1"; }
resolve() {
    local lexical canonical
    [[ $1 == /* && $1 != *[,:\\]* && $1 != *$'\n'* && $1 != *$'\r'* ]] || die 'Expected a safe absolute Linux path.'
    lexical=$(realpath -ms -- "$1") || die 'Cannot normalize path.'
    canonical=$(realpath -m -- "$1") || die 'Cannot resolve path.'
    [[ $canonical == "$lexical" ]] || die 'Symlinked paths are unsupported.'
    printf '%s\n' "$canonical"
}
scaffold=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")")
state_base=$(resolve "${XDG_STATE_HOME:-$HOME/.local/state}/pera-sandbox-tasks")
! overlaps "$state_base" "$scaffold" || die 'Task state must not overlap the scaffold.'
private_dir() {
    [[ -d $1 && ! -L $1 && $(stat -c %u -- "$1") == "$(id -u)" && $(stat -c %a -- "$1") == 700 ]] \
        || die "Expected a private owned mode-700 state directory: $1"
}
private_file() {
    [[ -f $1 && ! -L $1 && $(stat -c %u -- "$1") == "$(id -u)" \
        && $(stat -c %a -- "$1") == 600 && $(stat -c %h -- "$1") == 1 ]] || die "Unsafe ${2:-task state} file."
}
if [[ $mode == register ]]; then
    [[ -f $config_file && ! -L $config_file ]] || die 'Config must be a regular non-symlink file.'
    config=$(jq -ce . -- "$config_file") || die 'Config must be valid JSON.'
    task=$(jq -er '.task | strings' <<< "$config") || die 'Config requires a task ID.'
    [[ $task =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || die 'Invalid task ID.'
else
    private_dir "$state_base"
    private_dir "$state_base/$task"
    private_file "$state_base/$task/record.json"
    config=$(jq -ce .config "$state_base/$task/record.json") || die 'Task record is corrupt.'
fi
task_root="$state_base/$task"
workspace=$(resolve "$(jq -er '.workspace | strings' <<< "$config")")
[[ -d $workspace && $workspace != / && $workspace != "$(realpath -e -- "$HOME")" ]] || die 'Unsafe or missing workspace.'
! overlaps "$workspace" "$scaffold" || die 'Workspace must be outside the scaffold.'
for protected in "$workspace" "$(jq -er '.repositories.prj.source | strings' <<< "$config")" \
    "$(jq -er '.repositories.Documentation.source | strings' <<< "$config")"; do
    protected=$(resolve "$protected")
    [[ -d $protected ]] || die 'Workspace/source directory does not exist.'
    ! overlaps "$state_base" "$protected" || die 'Task state overlaps a workspace/source.'
done
for repository in prj Documentation; do
    source_path=$(resolve "$(jq -er --arg repository "$repository" '.repositories[$repository].source | strings' <<< "$config")")
    ! overlaps "$source_path" "$workspace" || die 'Source and workspace must not overlap.'
    ! overlaps "$source_path" "$scaffold" || die 'Source and scaffold must not overlap.'
    [[ -d $source_path/.git && ! -L $source_path/.git ]] || die 'Source requires an ordinary .git directory.'
    target=$(resolve "$workspace/$repository")
    [[ -d $target/.git && ! -L $target/.git ]] || die 'Target requires an ordinary .git directory.'
done
if [[ -n $handoff_file ]]; then
    [[ $handoff_file != *[[:cntrl:]]* ]] || die 'Handoff path must not contain control characters.'
    handoff_file=$(resolve "$handoff_file")
    private_file "$handoff_file" handoff
    private_dir "$(dirname -- "$handoff_file")"
    for protected in "$workspace" "$scaffold" "$state_base" \
        "$(jq -er '.repositories.prj.source | strings' <<< "$config")" \
        "$(jq -er '.repositories.Documentation.source | strings' <<< "$config")"; do
        protected=$(resolve "$protected")
        ! overlaps "$protected" "$handoff_file" || die 'Handoff input overlaps a workspace, source, scaffold or controller state.'
    done
    [[ $(stat -c %s -- "$handoff_file") -le 1048576 ]] || die 'Handoff input exceeds 1 MiB.'
fi
[[ ! -e $state_base ]] && mkdir -p -m 700 -- "$state_base"
private_dir "$state_base"
if [[ ! -e $task_root ]]; then mkdir -m 700 -- "$task_root"; fi
private_dir "$task_root"
lock="$task_root/task.lock"
[[ ! -e $lock ]] || private_file "$lock"
exec 9>> "$lock"
flock -n 9 || die 'Another task-controller operation owns this task; retry after it finishes.'
IFS= read -r nonce < /proc/sys/kernel/random/uuid
operation="$state_base/.operation-$nonce"
mkdir -m 700 -- "$operation"
owned_names=()
controller_pid=
cleanup() {
    local status=$? name label code failed=0
    trap - EXIT HUP INT TERM
    for name in "${owned_names[@]}"; do
        if podman container exists "$name"; then
            if label=$(podman container inspect "$name" --format '{{index .Config.Labels "io.pera.task-operation"}}'); then
                if [[ $label == "$nonce" ]]; then
                    if ! podman rm --force "$name" >/dev/null; then failed=1; fi
                else
                    printf 'sandbox-task: refusing cleanup of an unrelated container.\n' >&2
                    failed=1
                fi
            else failed=1; fi
        else
            code=$?
            if [[ $code != 1 ]]; then failed=1; fi
        fi
    done
    if [[ $failed == 0 && -n $controller_pid ]]; then
        if wait "$controller_pid"; then :; else code=$?; if [[ $status == 0 ]]; then status=$code; fi; fi
    fi
    if [[ $failed == 0 ]]; then
        if ! rm -rf -- "$operation"; then failed=1; fi
    else printf 'sandbox-task: operation staging retained after uncertain container cleanup: %s\n' "$operation" >&2; fi
    if [[ $failed == 1 && $status == 0 ]]; then status=1; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
image=$(jq -er '.image | strings' <<< "$config")
[[ -n $image && $image != -* && $image != *$'\n'* && $image != *$'\r'* ]] || die 'Invalid image.'
podman image exists "$image" || die 'Required image is absent; no pull/build attempted.'
image_id=$(podman image inspect "$image" --format '{{.Id}}')
image_user=$(podman image inspect "$image" --format '{{.Config.User}}')
if [[ $image_id =~ ^[0-9a-f]{64}$ ]]; then image_id="sha256:$image_id"; fi
[[ $image_id =~ ^sha256:[0-9a-f]{64}$ && -n $image_user && ! $image_user =~ ^(root|0)(:|$) ]] || die 'Image must have an immutable ID and non-root default user.'
if [[ $mode != register ]]; then
    [[ $image_id == "$(jq -er .imageId "$task_root/record.json")" ]] || die 'Registered image changed; restore the pinned image.'
fi
handoff_value="$operation/handoff-value.json"
if [[ -n $handoff_file ]]; then
    head -c 1048577 -- "$handoff_file" > "$operation/handoff.json"
    [[ $(stat -c %s -- "$operation/handoff.json") -le 1048576 ]] || die 'Handoff input exceeded 1 MiB during capture.'
    chmod 400 -- "$operation/handoff.json"
    jq -ces 'if length == 1 and (.[0] | type == "object") then .[0]
        else error("Expected exactly one handoff object") end' "$operation/handoff.json" > "$handoff_value" \
        || die 'Handoff input must contain exactly one valid JSON object.'
else
    printf 'null\n' > "$handoff_value"
fi
brief_json='[]'
for selected in "${briefs[@]}"; do brief_json=$(jq -c --arg selected "$selected" '. + [$selected]' <<< "$brief_json"); done
jq -n --arg mode "$mode" --arg hostRoot "$task_root" --arg planId "$plan_id" \
    --argjson config "$config" --argjson briefs "$brief_json" --slurpfile handoff "$handoff_value" \
    '{mode:$mode,hostRoot:$hostRoot,config:$config,briefs:$briefs,planId:$planId,handoff:$handoff[0]}' > "$operation/input.json"
container=(podman run --rm --pull=never --network=none --cap-drop=all
    --security-opt=no-new-privileges --userns=keep-id --http-proxy=false
    --unsetenv-all --env PATH=/usr/local/bin:/usr/bin:/bin --env HOME=/nonexistent
    --mount "type=bind,src=$scaffold/tools/tasks,dst=/opt/tasks,ro"
    --mount "type=bind,src=$scaffold/tools/rounds/rounds.js,dst=/opt/rounds.js,ro")
controller_name="pera-task-$nonce"
owned_names+=("$controller_name")
# The writer itself owns the task lock, so killing its host broker cannot permit
# another controller to overwrite still-live state. No workspace lock is held.
flock -u 9
exec 9>&-
"${container[@]}" --entrypoint /bin/bash --name "$controller_name" --label "io.pera.task-operation=$nonce" \
    --mount "type=bind,src=$task_root,dst=/task,rw" --mount "type=bind,src=$operation,dst=/operation,rw" \
    --workdir /task "$image_id" -c 'set -euo pipefail
umask 077
exec 9>>/task/task.lock
flock -n 9 || { echo "sandbox-task: Another controller owns this task; stop its labelled container before retrying." >&2; exit 1; }
node /opt/tasks/tasks.js' 9>&- > "$operation/result.json" &
controller_pid=$!

# Only this allowlisted broker invokes host operations. It never evaluates a
# command string or grants the controller a Podman socket/host executable mount.
perform() {
    local request=$1 action submode name root selected key
    local -a args=()
    action=$(jq -er .operation "$request")
    case "$action" in
        image)
            selected=$(jq -er .args.image "$request")
            podman image exists "$selected" || return
            local pinned user
            pinned=$(podman image inspect "$selected" --format '{{.Id}}') || return
            user=$(podman image inspect "$selected" --format '{{.Config.User}}') || return
            if [[ $pinned =~ ^[0-9a-f]{64}$ ]]; then pinned="sha256:$pinned"; fi
            jq -n --arg id "$pinned" --arg user "$user" '{id:$id,user:$user}';;
        round)
            submode=$(jq -er .args.mode "$request")
            case "$submode" in export|inspect|preview|apply|recover|collect) ;; *) return 1;; esac
            args=("$submode")
            for key in workspace source repository ref task round output image packet expected-head base work-base; do
                if jq -e --arg key "$key" '.args | has($key)' "$request" >/dev/null; then
                    args+=("--$key" "$(jq -er --arg key "$key" '.args[$key] | strings' "$request")")
                fi
            done
            while IFS= read -r selected; do args+=(--path "$selected"); done < <(jq -r '.args.paths[]?' "$request")
            bash "$scaffold/sandbox-round.sh" "${args[@]}" 9>&-;;
        source|import-head)
            name="pera-task-$nonce-read-$sequence"
            owned_names+=("$name")
            if [[ $action == source ]]; then
                root=$(resolve "$(jq -er .args.source "$request")")
                args=(source "$(jq -er .args.ref "$request")")
                if jq -e '.args | has("paths")' "$request" >/dev/null; then
                    jq -e '.args.paths | type == "array" and length <= 128
                        and all(.[]; type == "string" and (test("[\u0000-\u001f\u007f]") | not))' \
                        "$request" >/dev/null || { printf 'Invalid source document path list.\n' >&2; return 1; }
                    while IFS= read -r selected; do args+=("$selected"); done < <(jq -r '.args.paths[]' "$request")
                fi
            else
                root=$(resolve "$(jq -er '.args.workspace + "/" + .args.repository' "$request")")
                args=(import-head "$(jq -er .args.head "$request")" "$(jq -er .args.base "$request")" "$(jq -er .args.roundPath "$request")")
            fi
            "${container[@]}" --entrypoint node --name "$name" --label "io.pera.task-operation=$nonce" \
                --mount "type=bind,src=$root,dst=/repo,ro" "$image_id" /opt/tasks/source.js "${args[@]}" 9>&-;;
        *) printf 'Unsupported host operation.\n' >&2; return 1;;
    esac
}
sequence=1
while kill -0 "$controller_pid" 2>/dev/null; do
    request="$operation/request-$sequence.json"
    if [[ -f $request ]]; then
        if perform "$request" > "$operation/value.json" 2> "$operation/error.txt"; then
            if [[ ! -s $operation/value.json ]]; then printf 'null\n' > "$operation/value.json"; fi
            if ! jq -n --slurpfile value "$operation/value.json" \
                'if ($value | length) == 1 then {ok:true,value:$value[0]} else error("Expected one JSON result") end' \
                > "$operation/response.part"; then die 'Host operation produced invalid JSON.'; fi
        else
            jq -n --rawfile error "$operation/error.txt" '{ok:false,error:$error}' > "$operation/response.part"
        fi
        mv -- "$operation/response.part" "$operation/response-$sequence.json"
        sequence=$((sequence + 1))
    else sleep 0.05; fi
done
if wait "$controller_pid"; then controller_pid=; else status=$?; controller_pid=; exit "$status"; fi
jq -ce . "$operation/result.json"
