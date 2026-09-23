#!/bin/bash
# Disposable regressions for new-sandbox.sh assembly and reset safety (findings V2, D5, I1).
#
#   wsl -d centos-9 -- bash /mnt/c/work/pera/claude-sandbox/verify-assembly.sh
#
# Builds fake source repos, credential files and task state in a new directory under
# $HOME, assembles and resets sandboxes there, and removes it at the end. It never
# names the real ~/pera-sandbox, real task state or the real prj/Documentation, and it
# uses no network or credentials. The reset checks call sandbox-round.sh inspect, so
# the existing localhost/pera-sandbox image is required; nothing is pulled or built.
set -u
case "${1:-}" in
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "verify-assembly.sh takes no arguments" >&2; exit 2 ;;
esac
command -v podman >/dev/null && podman image exists localhost/pera-sandbox \
    || { echo "verify-assembly.sh: needs podman and the localhost/pera-sandbox image" >&2; exit 2; }
NS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/new-sandbox.sh"
unset SANDBOX_ROOT SOURCE_ROOT WIN_M2 WIN_NPMRC SANDBOX_GIT_NAME SANDBOX_GIT_EMAIL
T=$(mktemp -d "$HOME/verify-assembly-XXXXXX")
SRC=$T/src; WS=$T/ws; ST=$T/state
RUNNING=
cleanup() {
    [ -z "$RUNNING" ] || podman rm --force --time 0 "$RUNNING" >/dev/null 2>&1
    rm -rf "$T" 2>/dev/null || podman unshare rm -rf "$T"
    [ ! -e "$T" ] && echo "cleaned $T"
}
trap cleanup EXIT
mkdir -p "$ST"
commit() { git -C "$1" -c user.name=F -c user.email=f@x commit -q "${@:2}"; }
for r in prj Documentation; do
    git init -q -b main "$SRC/$r"
    commit "$SRC/$r" --allow-empty -m init
done
# Like the real prj: the overlaid AI assets are git-ignored there. A tracked file under
# .agents means the clone already has that directory, which must not nest the overlay.
printf '.github/\n.agents/skills\n' > "$SRC/prj/.gitignore"
mkdir -p "$SRC/prj/.agents"; echo tracked > "$SRC/prj/.agents/README.md"
git -C "$SRC/prj" add .gitignore .agents/README.md
commit "$SRC/prj" -m "ignore AI assets"
ASSETS=".github/copilot-instructions.md .github/a11y.instructions.md
        .agents/skills/agency-jsp-to-angular/SKILL.md .agents/skills/angular-developer/SKILL.md"
for a in $ASSETS; do
    mkdir -p "$(dirname "$SRC/prj/$a")"; echo synthetic > "$SRC/prj/$a"
done
echo synthetic > "$T/m2"; echo synthetic > "$T/npmrc"
export SOURCE_ROOT=$SRC WIN_M2=$T/m2 WIN_NPMRC=$T/npmrc SANDBOX_GIT_NAME='Test Dev' \
       SANDBOX_GIT_EMAIL=dev@example.invalid XDG_STATE_HOME=$ST
pass=0; fail=0
bad() { fail=$((fail+1)); echo "FAIL $*"; }
# expect LABEL WANT_RC GREP_PATTERN [env...] -- [args...]
# A refused run must leave an existing sandbox in place, and no run may leave a tombstone.
expect() {
    local label=$1 want=$2 pat=$3; shift 3
    local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
    local target=${SBX:-$WS} had=0
    [ -d "$target/prj/.git" ] && had=1
    out=$(env "${envs[@]}" SANDBOX_ROOT="$target" bash "$NS" "$@" 2>&1); rc=$?
    if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -qE -- "$pat"; then
        pass=$((pass+1)); echo "PASS $label"
    else
        bad "$label (rc=$rc, want $want, pattern '$pat')"; printf '%s\n' "$out" | tail -8 | sed 's/^/     /'
    fi
    if [ "$want" != 0 ] && [ "$had" = 1 ] && [ ! -d "$target/prj/.git" ]; then bad "$label deleted the sandbox"; fi
    if compgen -G "${target%/}.deleting.*" >/dev/null; then bad "$label left a tombstone"; fi
}
g() { git -C "$WS/$1" "${@:2}"; }
assets_ok() {
    local a; for a in $ASSETS; do [ -f "$WS/prj/$a" ] && [ ! -L "$WS/prj/$a" ] || return 1; done
    [ ! -e "$WS/prj/.agents/.agents" ] && [ ! -e "$WS/prj/.github/.github" ]
}

expect "T01 fresh assembly" 0 "Sandbox ready" --
[ -f "$WS/.pera-sandbox-workspace" ] || bad "T01 marker missing"
assets_ok || bad "T01 assets missing, linked or nested in the sandbox"
expect "T02 exists, no --force" 1 "already exists" --
expect "T03 --force, clean + harvested" 0 "Removing existing sandbox" -- --force
assets_ok || bad "T03 assets missing after reset"

g prj commit -q --allow-empty -m "agent work"
expect "T04 unharvested HEAD refused" 1 "prj HEAD .*unharvested" -- --force
expect "T05 --discard-unharvested proceeds" 0 "discarding" -- --force --discard-unharvested

echo scratch > "$WS/Documentation/notes.txt"
expect "T06 dirty worktree refused" 1 "Documentation is dirty" -- --force
rm -f "$WS/Documentation/notes.txt"

g prj switch -q -c side; g prj commit -q --allow-empty -m "side work"; g prj switch -q main
expect "T07 unharvested loose branch refused" 1 "refs/heads/side .*unharvested" -- --force
g prj pack-refs --all
[ ! -f "$WS/prj/.git/refs/heads/side" ] || bad "T08 setup: side branch still loose"
expect "T08 unharvested packed branch refused" 1 "refs/heads/side .*unharvested" -- --force
g prj branch -q -D side

echo one > "$WS/prj/tracked.txt"; g prj add tracked.txt; g prj stash -q
expect "T09 loose stash refused" 1 "refs/stash .*unharvested" -- --force
g prj pack-refs --all
[ ! -f "$WS/prj/.git/refs/stash" ] || bad "T10 setup: stash still loose"
expect "T10 packed stash refused" 1 "refs/stash .*unharvested" -- --force
echo two > "$WS/prj/tracked.txt"; g prj add tracked.txt; g prj stash -q
expect "T11 older stash entry refused" 1 "stash-entry .*unharvested" -- --force
g prj stash clear

printf 'garbage line here\n' >> "$WS/prj/.git/packed-refs"
expect "T12 malformed packed-refs refused" 1 "packed-refs|could not be inspected" -- --force
sed -i '/^garbage line here$/d' "$WS/prj/.git/packed-refs"

g prj worktree add -q --detach "$T/wt"
expect "T13 linked worktree refused" 1 "linked worktrees" -- --force
g prj worktree remove --force "$T/wt"; rm -rf "$WS/prj/.git/worktrees"

echo notes > "$WS/notes.md"
expect "T14 unexpected top-level file refused" 1 "unexpected top-level entry notes.md" -- --force
rm -f "$WS/notes.md"

mkdir -p "$ST/pera-sandbox-tasks/TASK-9"
printf '{"version":1,"config":{"task":"TASK-9","workspace":"%s"}}\n' "$WS" > "$ST/pera-sandbox-tasks/TASK-9/record.json"
expect "T15 registered workspace refused" 1 "registered to task TASK-9" -- --force
printf '{"version":1,"config":{"task":"TASK-9","workspace":"%s/sub"}}\n' "$WS" > "$ST/pera-sandbox-tasks/TASK-9/record.json"
expect "T16 registration nested inside refused" 1 "registered to task TASK-9" -- --force
printf '{not json' > "$ST/pera-sandbox-tasks/TASK-9/record.json"
expect "T17 unreadable task record refused" 1 "task record .* is unreadable" -- --force
rm -rf "$ST/pera-sandbox-tasks"

RUNNING=$(podman run -d --rm --pull=never --network=none --cap-drop=all --userns=keep-id \
    -v "$WS:/workspace:ro" --entrypoint sleep localhost/pera-sandbox 300)
expect "T18 running container: hard refusal despite --discard" 1 "running container.*|does not override" -- --force --discard-unharvested
podman rm --force --time 0 "$RUNNING" >/dev/null; RUNNING=

expect "T19 clean again after cleanup" 0 "Removing existing sandbox" -- --force
SBX=$HOME expect "T20 SANDBOX_ROOT=\$HOME refused" 1 "must be a directory inside" -- --force
SBX=/tmp/v2-outside expect "T21 outside \$HOME refused" 1 "must be a directory inside" --
SBX=$SRC/prj/nested expect "T22 inside source refused" 1 "overlaps" --
SBX=$T expect "T23 containing source refused" 1 "overlaps" -- --force
ln -s "$WS" "$T/link"
SBX=$T/link expect "T24 symlink refused" 1 "pass through a symlink" -- --force
SBX=$T/link/ expect "T25 symlink with trailing slash refused" 1 "pass through a symlink" -- --force
mkdir -p "$T/notsandbox/data"
SBX=$T/notsandbox expect "T26 foreign directory refused" 1 "does not look like a sandbox" -- --force --discard-unharvested
[ -d "$T/notsandbox/data" ] || bad "T26 foreign dir deleted"
rm -f "$WS/.pera-sandbox-workspace"
expect "T27 legacy layout (no marker) accepted" 0 "Removing existing sandbox" -- --force

mv "$SRC/prj/.agents/skills" "$T/skills-aside"
expect "T28 missing assets refused" 1 "angular-developer/SKILL.md" -- --force
expect "T29 --allow-missing-assets proceeds" 0 "WARN: prj/.agents/skills/agency-jsp-to-angular/SKILL.md missing" -- --force --allow-missing-assets
[ -f "$WS/prj/.github/copilot-instructions.md" ] && [ ! -e "$WS/prj/.agents/skills/angular-developer/SKILL.md" ] \
    || bad "T29 sandbox should have .github and lack the skills"
mv "$T/skills-aside" "$SRC/prj/.agents/skills"
mv "$SRC/prj/.github/a11y.instructions.md" "$T/a11y"; ln -s "$T/a11y" "$SRC/prj/.github/a11y.instructions.md"
expect "T30 symlinked asset refused" 1 "a11y.instructions.md" -- --force
rm "$SRC/prj/.github/a11y.instructions.md"; mv "$T/a11y" "$SRC/prj/.github/a11y.instructions.md"

expect "T31 --discard without --force" 1 "only applies together with --force" -- --discard-unharvested
expect "T32 unknown argument" 2 "unknown argument: --frce" -- --frce
mkdir -p "$T/fakebin"; printf '#!/bin/sh\necho "fake podman: unavailable" >&2\nexit 125\n' > "$T/fakebin/podman"; chmod +x "$T/fakebin/podman"
expect "T33 inspect unavailable refused" 1 "could not be inspected" PATH="$T/fakebin:/usr/bin:/bin" -- --force

echo "== $pass passed, $fail failed"
[ "$fail" = 0 ]
