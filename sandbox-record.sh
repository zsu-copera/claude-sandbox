#!/usr/bin/env bash
set -euo pipefail
umask 077

die() { printf 'sandbox-record: %s\n' "$*" >&2; exit 125; }
usage() {
    cat <<'USAGE'
Usage:
  bash sandbox-record.sh --label LABEL --workspace DIRECTORY \
    [--output-root DIRECTORY] -- COMMAND [ARGUMENT...]

Run from an interactive WSL terminal. Wrap the existing guarded podman launch,
not a bare agent CLI. This recorder does not authorize or validate that launch.
DIRECTORY paths must be absolute, real Linux paths, not symlinked.
LABEL is 1-64 ASCII letters/digits, underscores or hyphens, starting alphanumeric.

Output defaults to ${XDG_STATE_HOME:-$HOME/.local/state}/pera-sandbox-recordings.
Each run gets a new private directory; existing recordings are never overwritten.
It contains launch.json, command.argv (NUL-separated arguments), terminal.log,
timing.log, command-exit.txt when available, outcome.json and SHA256SUMS.
No raw input stream, environment dump or CLI-config volume is copied. Output and
command arguments can still contain secrets; keep all artifacts private.

The output root must be outside the workspace, scaffold and operator state.
The operator must also keep it outside source checkouts and ALL container mounts.
The recorder cannot infer these boundaries from an arbitrary command.

The exit status follows the launch command when recording completes normally;
125 indicates a recorder failure. outcome.json distinguishes the two, including
a launch that itself exits 125. Missing outcome/checksums mean incomplete capture.
A zero launch exit does not prove that the agent's builds or tests passed.
USAGE
}
private_dir() {
    [[ -d $1 && ! -L $1 && $(stat -c %u -- "$1") == "$UID" && $(stat -c %a -- "$1") == 700 ]] \
        || die "Expected an owned mode-700 directory: $1"
}
private_file() {
    [[ -f $1 && ! -L $1 && $(stat -c %u -- "$1") == "$UID" \
        && $(stat -c %a -- "$1") == 600 && $(stat -c %h -- "$1") == 1 ]] \
        || die "Expected an owned mode-600 single-link file: $1"
}

# script(1) accepts a shell string, not argv, on CentOS 9. Keep the user's
# arguments in a private NUL-delimited file rather than quoting or eval'ing them.
if [[ ${1:-} == --record-child ]]; then
    [[ $# == 2 ]] || die 'Invalid recorder child invocation.'
    private_dir "$2"
    private_file "$2/command.argv"
    mapfile -d '' -t launch < "$2/command.argv"
    [[ ${#launch[@]} -gt 0 && -n ${launch[0]} ]] || die 'Missing captured launch command.'
    run_dir=$2
    unset SANDBOX_RECORD_SCRIPT SANDBOX_RECORD_DIR
    if "${launch[@]}"; then command_status=0; else command_status=$?; fi
    printf '%s\n' "$command_status" > "$run_dir/command-exit.txt" || die 'Cannot retain launch exit status.'
    exit "$command_status"
fi

if [[ $# == 1 && ( $1 == --help || $1 == -h ) ]]; then usage; exit 0; fi
label=
workspace=
output_root=
while [[ $# -gt 0 && $1 != -- ]]; do
    [[ $# -ge 2 && -n $2 && $2 != --* ]] || die 'Missing option value.'
    case "$1" in
        --label) [[ -z $label ]] || die 'Duplicate --label.'; label=$2 ;;
        --workspace) [[ -z $workspace ]] || die 'Duplicate --workspace.'; workspace=$2 ;;
        --output-root) [[ -z $output_root ]] || die 'Duplicate --output-root.'; output_root=$2 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift 2
done
[[ $# -ge 2 && $1 == -- ]] || { usage >&2; die 'Expected -- followed by a launch command.'; }
shift
[[ $label =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || die 'Invalid or missing --label.'
[[ -n $workspace ]] || die '--workspace is required.'
for program in script bash jq realpath stat mkdir mktemp date sha256sum mv env; do
    command -v "$program" >/dev/null 2>&1 || die "Required WSL command is missing: $program"
done
[[ $UID != 0 ]] || die 'Run as the normal rootless container user.'
[[ -n ${HOME:-} && $HOME == /* ]] || die 'HOME must be absolute.'
[[ -n $1 ]] && type -P -- "$1" >/dev/null || die 'The launch command must be an executable, not a shell expression.'
resolve() {
    local lexical canonical
    [[ $1 == /* && $1 != *[[:cntrl:]]* ]] || die 'Expected an absolute Linux path without control characters.'
    lexical=$(realpath -ms -- "$1") || die 'Cannot normalize path.'
    canonical=$(realpath -m -- "$1") || die 'Cannot resolve path.'
    [[ $canonical == "$lexical" ]] || die 'Symlinked paths are unsupported.'
    printf '%s\n' "$canonical"
}
inside() { [[ $2 == "$1" || $2 == "$1/"* || $1 == / ]]; }
overlaps() { inside "$1" "$2" || inside "$2" "$1"; }
workspace=$(resolve "$workspace")
[[ -d $workspace && $workspace != / ]] || die 'Workspace must be an existing non-root directory.'
scaffold=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")")
state_base=$(resolve "${XDG_STATE_HOME:-$HOME/.local/state}")
output_root=$(resolve "${output_root:-$state_base/pera-sandbox-recordings}")
for protected in "$workspace" "$scaffold" "$state_base/pera-sandbox-tasks" "$HOME/.pera-operator"; do
    protected=$(resolve "$protected")
    ! overlaps "$output_root" "$protected" || die 'Recording storage overlaps a protected workspace/scaffold/operator path.'
done
[[ -t 0 && -t 1 ]] || die 'An interactive terminal is required; do not pipe stdin/stdout or use this for headless qualification.'
recorder_version=$(script --version) || die 'Cannot identify script(1).'
[[ $recorder_version == *util-linux* ]] || die 'This recipe requires util-linux script(1).'
mkdir -p -- "$output_root" || die 'Cannot create recording storage.'
private_dir "$output_root"
run_dir=$(mktemp -d "$output_root/$label-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || die 'Cannot create a private run directory.'
private_dir "$run_dir"
printf 'sandbox-record: retaining private terminal evidence in %s\n' "$run_dir" >&2
printf '%s\0' "$@" > "$run_dir/command.argv" || die 'Cannot capture launch arguments.'
jq -n --arg runLabel "$label" --arg workspace "$workspace" --arg cwd "$PWD" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg recorder "$recorder_version" \
    --args '{version:1,label:$runLabel,workspace:$workspace,cwd:$cwd,startedAt:$started,
             recorder:$recorder,command:$ARGS.positional}' -- "$@" \
    > "$run_dir/launch.json" || die 'Cannot capture launch metadata.'

export SANDBOX_RECORD_SCRIPT="$scaffold/sandbox-record.sh"
export SANDBOX_RECORD_DIR="$run_dir"
interruption=
forward_signal() {
    interruption=$1
    if kill -0 "$recorder_pid" 2>/dev/null; then
        kill -s "$1" "$recorder_pid" || printf 'sandbox-record: could not forward %s to recorder PID %s\n' "$1" "$recorder_pid" >&2
    fi
}
# Explicit stdin redirection prevents an asynchronous script process from
# inheriting /dev/null. Reset the INT/QUIT dispositions Bash ignores for async
# commands, so Ctrl-C still reaches the foreground program in the recorded PTY.
SHELL=/bin/bash env --default-signal=INT,QUIT script --quiet --return --flush \
    --log-out "$run_dir/terminal.log" --log-timing "$run_dir/timing.log" \
    --command 'exec bash --noprofile --norc "$SANDBOX_RECORD_SCRIPT" --record-child "$SANDBOX_RECORD_DIR"' <&0 &
recorder_pid=$!
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM
trap 'forward_signal HUP' HUP
while true; do
    if wait "$recorder_pid"; then recorder_status=0; break; else recorder_status=$?; fi
    if ! kill -0 "$recorder_pid" 2>/dev/null; then break; fi
done
trap - INT TERM HUP
unset SANDBOX_RECORD_SCRIPT SANDBOX_RECORD_DIR

command_status=null
state=recording-error
wrapper_status=125
if [[ -f $run_dir/command-exit.txt ]]; then
    private_file "$run_dir/command-exit.txt"
    command_status=$(< "$run_dir/command-exit.txt")
    [[ $command_status =~ ^(0|[1-9][0-9]{0,2})$ && $command_status -le 255 ]] || die "Invalid launch status; retain $run_dir"
    if [[ $command_status == "$recorder_status" && -f $run_dir/terminal.log && -f $run_dir/timing.log ]]; then
        state=returned
        wrapper_status=$command_status
    fi
fi
if [[ -n $interruption ]]; then
    state=interrupted
    case "$interruption" in INT) wrapper_status=130 ;; TERM) wrapper_status=143 ;; HUP) wrapper_status=129 ;; esac
fi
jq -n --arg state "$state" --arg ended "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg signal "$interruption" --argjson commandStatus "$command_status" \
    --argjson recorderStatus "$recorder_status" --argjson wrapperStatus "$wrapper_status" \
    '{version:1,state:$state,endedAt:$ended,interruptionSignal:(if $signal == "" then null else $signal end),
      commandExitStatus:$commandStatus,recorderExitStatus:$recorderStatus,wrapperExitStatus:$wrapperStatus}' \
    > "$run_dir/outcome.json" || die "Cannot retain recorder outcome; retain $run_dir"
artifacts=(launch.json command.argv outcome.json)
for file in terminal.log timing.log command-exit.txt; do
    if [[ -e $run_dir/$file ]]; then
        private_file "$run_dir/$file"
        artifacts+=("$file")
    fi
done
if ! (cd -- "$run_dir" && sha256sum -- "${artifacts[@]}" > .SHA256SUMS.tmp \
    && mv -- .SHA256SUMS.tmp SHA256SUMS); then
    die "Cannot finalize recording hashes; retain $run_dir and treat capture as incomplete."
fi
printf 'sandbox-record: %s; launch exit=%s; recorder exit=%s; evidence=%s\n' \
    "$state" "$command_status" "$recorder_status" "$run_dir" >&2
[[ $state != recording-error ]] || printf 'sandbox-record: capture did not complete normally; inspect retained artifacts, not just the launch status.\n' >&2
exit "$wrapper_status"
