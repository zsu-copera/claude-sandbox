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
mkdir -p "$ST"
for r in prj Documentation; do
    git init -q -b main "$SRC/$r"
    git -C "$SRC/$r" -c user.name=F -c user.email=f@x commit -q --allow-empty -m init
done
# Like the real prj: the overlaid AI assets are git-ignored there.
printf '.github/\n.agents/skills\n' > "$SRC/prj/.gitignore"
git -C "$SRC/prj" add .gitignore
git -C "$SRC/prj" -c user.name=F -c user.email=f@x commit -q -m "ignore AI assets"
for a in .github/copilot-instructions.md .github/a11y.instructions.md \
         .agents/skills/agency-jsp-to-angular/SKILL.md .agents/skills/angular-developer/SKILL.md; do
    mkdir -p "$(dirname "$SRC/prj/$a")"; echo synthetic > "$SRC/prj/$a"
done
echo synthetic > "$T/m2"; echo synthetic > "$T/npmrc"
export SOURCE_ROOT=$SRC WIN_M2=$T/m2 WIN_NPMRC=$T/npmrc SANDBOX_GIT_NAME='Test Dev' \
       SANDBOX_GIT_EMAIL=dev@example.invalid XDG_STATE_HOME=$ST
pass=0; fail=0
# expect LABEL WANT_RC GREP_PATTERN [env...] -- [args...]
expect() {
    local label=$1 want=$2 pat=$3; shift 3
    local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
    out=$(env "${envs[@]}" SANDBOX_ROOT="${SBX:-$WS}" bash "$NS" "$@" 2>&1); rc=$?
    if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -qE -- "$pat"; then
        pass=$((pass+1)); echo "PASS $label"
    else
        fail=$((fail+1)); echo "FAIL $label (rc=$rc, want $want, pattern '$pat')"; printf '%s\n' "$out" | tail -8 | sed 's/^/     /'
    fi
}
g() { git -C "$WS/$1" "${@:2}"; }

expect "T01 fresh assembly" 0 "Sandbox ready" --
[ -f "$WS/.pera-sandbox-workspace" ] && echo "     marker present" || { echo "FAIL marker missing"; fail=$((fail+1)); }
expect "T02 exists, no --force" 1 "already exists" --
expect "T03 --force, clean + harvested" 0 "Removing existing sandbox" -- --force
g prj commit -q --allow-empty -m "agent work"
expect "T04 unharvested HEAD refused" 1 "prj HEAD .*unharvested" -- --force
[ -d "$WS/prj/.git" ] && echo "     workspace kept" || { echo "FAIL workspace deleted"; fail=$((fail+1)); }
expect "T05 --discard-unharvested proceeds" 0 "discarding" -- --force --discard-unharvested
echo scratch > "$WS/Documentation/notes.txt"
expect "T06 dirty worktree refused" 1 "Documentation is dirty" -- --force
rm -f "$WS/Documentation/notes.txt"
g prj switch -q -c side; g prj commit -q --allow-empty -m "side work"; g prj switch -q main
expect "T07 unharvested side branch refused" 1 "refs/heads/side .*unharvested" -- --force
g prj branch -q -D side
echo stashed > "$WS/prj/tracked.txt"; g prj add tracked.txt; g prj stash -q
expect "T08 stash refused" 1 "refs/stash .*unharvested" -- --force
g prj stash drop -q
mkdir -p "$ST/pera-sandbox-tasks/TASK-9"
printf '{"version":1,"config":{"task":"TASK-9","workspace":"%s"}}\n' "$WS" > "$ST/pera-sandbox-tasks/TASK-9/record.json"
expect "T09 registered workspace refused" 1 "registered to task TASK-9" -- --force
rm -rf "$ST/pera-sandbox-tasks"
expect "T10 clean again after cleanup" 0 "Removing existing sandbox" -- --force
SBX=$HOME expect "T11 SANDBOX_ROOT=\$HOME refused" 1 "must be a directory inside" -- --force
SBX=/tmp/v2-outside expect "T12 outside \$HOME refused" 1 "must be a directory inside" --
SBX=$SRC/prj/nested expect "T13 inside source refused" 1 "overlaps" --
SBX=$T expect "T14 containing source refused" 1 "overlaps" -- --force
ln -s "$WS" "$T/link"
SBX=$T/link expect "T15 symlink refused" 1 "must not be a symlink" -- --force
mkdir -p "$T/notsandbox/data"
SBX=$T/notsandbox expect "T16 foreign directory refused" 1 "does not look like a sandbox" -- --force --discard-unharvested
[ -d "$T/notsandbox/data" ] && echo "     foreign dir kept" || { echo "FAIL foreign dir deleted"; fail=$((fail+1)); }
rm -f "$WS/.pera-sandbox-workspace"
expect "T17 legacy layout (no marker) accepted" 0 "Removing existing sandbox" -- --force
mv "$SRC/prj/.agents" "$T/agents-aside"
expect "T18 missing assets refused" 1 "angular-developer/SKILL.md" -- --force
expect "T19 --allow-missing-assets proceeds" 0 "WARN: prj/.agents/skills/agency-jsp-to-angular/SKILL.md missing" -- --force --allow-missing-assets
mv "$T/agents-aside" "$SRC/prj/.agents"
expect "T20 --discard without --force" 1 "only applies together with --force" -- --discard-unharvested
expect "T21 unknown argument" 2 "unknown argument: --frce" -- --frce
mkdir -p "$T/fakebin"; printf '#!/bin/sh\necho "fake podman: unavailable" >&2\nexit 125\n' > "$T/fakebin/podman"; chmod +x "$T/fakebin/podman"
expect "T22 inspect unavailable refused" 1 "could not be inspected" PATH="$T/fakebin:/usr/bin:/bin" -- --force
[ -d "$WS/prj/.git" ] && echo "     workspace kept" || { echo "FAIL workspace deleted"; fail=$((fail+1)); }

echo "== $pass passed, $fail failed"
rm -rf "$T" 2>/dev/null || podman unshare rm -rf "$T"
[ ! -e "$T" ] && echo "cleaned $T"
[ "$fail" = 0 ]
