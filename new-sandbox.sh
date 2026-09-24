#!/bin/bash
# WSL-native assembly of the disposable agent sandbox. It builds
# INSIDE the WSL distro filesystem (fast container bind mounts; /mnt/c
# would go through 9p and cripple the Maven/npm builds).
#
# Run from Windows:   wsl -d centos-9 -- bash /mnt/c/work/pera/claude-sandbox/new-sandbox.sh [options]
# Review from Windows at: \\wsl$\centos-9\home\<user>\pera-sandbox
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: new-sandbox.sh [--force [--discard-unharvested]] [--allow-missing-assets]

  --force                 Replace an existing sandbox at SANDBOX_ROOT. Refused if a repo is
                          not clean or cannot be inspected; HEAD, a branch or a stash entry
                          is on no source ref; there are linked worktrees or unexpected
                          top-level files; or a task is registered to it. Tags, other refs
                          and file contents outside the two repos are not checked.
  --discard-unharvested   With --force: list those problems, then delete anyway. Never
                          overrides a running container or a pending round recovery.
  --allow-missing-assets  Assemble even if prj's git-ignored AI assets are missing.

Environment: SOURCE_ROOT (default /mnt/c/work/pera), SANDBOX_ROOT (default ~/pera-sandbox,
must be inside $HOME), WIN_M2, WIN_NPMRC, SANDBOX_GIT_NAME, SANDBOX_GIT_EMAIL.
USAGE
}
die() { echo "ERROR: $*" >&2; exit 1; }

FORCE=0
DISCARD=0
ALLOW_MISSING_ASSETS=0
for arg in "$@"; do
    case "$arg" in
        --force|-f)             FORCE=1 ;;
        --discard-unharvested)  DISCARD=1 ;;
        --allow-missing-assets) ALLOW_MISSING_ASSETS=1 ;;
        --help|-h)              usage; exit 0 ;;
        *)                      usage >&2; echo "ERROR: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
[ "$DISCARD" = 0 ] || [ "$FORCE" = 1 ] || die "--discard-unharvested only applies together with --force"

SCAFFOLD="$(realpath -e -- "$(dirname "${BASH_SOURCE[0]}")")"
SOURCE_ROOT="$(realpath -m -- "${SOURCE_ROOT:-/mnt/c/work/pera}")"
SANDBOX_ROOT_IN="${SANDBOX_ROOT:-$HOME/pera-sandbox}"
SANDBOX_ROOT="$(realpath -m -- "$SANDBOX_ROOT_IN")"
HOME_REAL="$(realpath -m -- "$HOME")"

# --- Destination containment (finding V2) ------------------------------------
# --force ends in rm -rf of this path, so pin down what it can be before anything else.
# Strictly inside $HOME keeps it off /, $HOME itself and the Windows drives, and apart
# from the real working copies and this scaffold that it is cloned from.
under() { [ "$2" = "$1" ] || [ "$1" = / ] || case "$2" in "$1"/*) true ;; *) false ;; esac; }
# No symlink anywhere in the path: -s keeps links, so any difference means one was
# followed (this also catches `link/` and `link/.`, which [ -L ] misses).
[ "$(realpath -ms -- "$SANDBOX_ROOT_IN")" = "$SANDBOX_ROOT" ] \
    || die "SANDBOX_ROOT must not pass through a symlink: $SANDBOX_ROOT_IN"
[ "$SANDBOX_ROOT" != "$HOME_REAL" ] && under "$HOME_REAL" "$SANDBOX_ROOT" \
    || die "SANDBOX_ROOT must be a directory inside $HOME_REAL, not $SANDBOX_ROOT"
# The source repos are compared resolved as well: either may be a link elsewhere.
for p in "$SOURCE_ROOT" "$(realpath -m -- "$SOURCE_ROOT/prj")" \
         "$(realpath -m -- "$SOURCE_ROOT/Documentation")" "$SCAFFOLD"; do
    ! under "$p" "$SANDBOX_ROOT" && ! under "$SANDBOX_ROOT" "$p" \
        || die "SANDBOX_ROOT ($SANDBOX_ROOT) overlaps $p"
done

# --- Preflight ---------------------------------------------------------------
for p in "$SOURCE_ROOT/prj/.git" "$SOURCE_ROOT/Documentation/.git"; do
    [ -e "$p" ] || { echo "ERROR: expected git repo not found: $p" >&2; exit 1; }
done

# Nexus credentials live in the Windows profile of whoever runs this (finding I2). Ask
# Windows for it through WSL interop; the Linux $USER need not match the Windows account.
# From /mnt/c because cmd.exe refuses a UNC (\\wsl$) working directory.
win_profile() {
    local p
    p=$(cd /mnt/c && cmd.exe /d /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r') || return 1
    [ -n "$p" ] && [ "$p" != "%USERPROFILE%" ] || return 1
    wslpath -u "$p"
}
if [ -z "${WIN_M2:-}" ] || [ -z "${WIN_NPMRC:-}" ]; then
    WIN_HOME=$(win_profile) || {
        echo "ERROR: could not resolve %USERPROFILE% through WSL interop." >&2
        echo "       Set WIN_M2 and WIN_NPMRC to your settings.xml and .npmrc (as /mnt/c/... paths)." >&2
        exit 1
    }
    WIN_M2="${WIN_M2:-$WIN_HOME/.m2/settings.xml}"
    WIN_NPMRC="${WIN_NPMRC:-$WIN_HOME/.npmrc}"
fi

# Commit identity (finding I1): the developer who runs this audits and pushes the
# sandbox's work, so the sandbox commits as them. WSL's git config for the source repo
# (repo-local, then WSL global) is the default source. There is deliberately no fallback
# name: a guessed identity attributes the work to the wrong person. Validated the way
# the round importer validates it, so a bad value fails here rather than at import.
GIT_NAME="${SANDBOX_GIT_NAME:-$(git -C "$SOURCE_ROOT/prj" config user.name 2>/dev/null || true)}"
GIT_EMAIL="${SANDBOX_GIT_EMAIL:-$(git -C "$SOURCE_ROOT/prj" config user.email 2>/dev/null || true)}"
if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
    echo "ERROR: no commit identity for the sandbox repos. Either set SANDBOX_GIT_NAME and" >&2
    echo "       SANDBOX_GIT_EMAIL, or configure git inside this WSL distro:" >&2
    echo "       git config --global user.name \"Your Name\"; git config --global user.email you@example.org" >&2
    exit 1
fi
_bad_ident='[[:cntrl:]<>]'
if [[ "$GIT_NAME$GIT_EMAIL" =~ $_bad_ident ]]; then
    echo "ERROR: commit identity contains a control character or angle bracket" >&2
    exit 1
fi

[ -f "$WIN_M2" ] || { echo "ERROR: $WIN_M2 missing (Nexus mirror + creds needed for prepare phase)" >&2; exit 1; }
[ -f "$WIN_NPMRC" ] || { echo "ERROR: $WIN_NPMRC missing (Nexus npm registry + auth needed for prepare phase)" >&2; exit 1; }
# Git-ignored AI assets (finding D5). A fresh prj clone has none of them, and without them
# the agent silently loses its instructions, a11y rules and skills, so they are required
# unless the caller opts out.
REQUIRED_ASSETS=(
    .github/copilot-instructions.md
    .github/a11y.instructions.md
    .agents/skills/agency-jsp-to-angular/SKILL.md
    .agents/skills/angular-developer/SKILL.md
)
missing_assets=()
for a in "${REQUIRED_ASSETS[@]}"; do
    [ -f "$SOURCE_ROOT/prj/$a" ] && [ ! -L "$SOURCE_ROOT/prj/$a" ] || missing_assets+=("prj/$a")
done
if [ "${#missing_assets[@]}" -gt 0 ]; then
    if [ "$ALLOW_MISSING_ASSETS" = 1 ]; then
        for a in "${missing_assets[@]}"; do echo "WARN: $a missing; the sandbox will lack it" >&2; done
    else
        echo "ERROR: required git-ignored assets are missing from $SOURCE_ROOT/prj:" >&2
        for a in "${missing_assets[@]}"; do echo "         $a" >&2; done
        echo "       A fresh clone never has them. Copy them from a prj checkout that does (the" >&2
        echo "       copilot instructions are generated from Documentation's canonical file), or" >&2
        echo "       pass --allow-missing-assets to assemble without them." >&2
        exit 1
    fi
fi

# --- Existing sandbox: identify, then refuse to lose work (finding V2) --------
# Everything here reads the old sandbox as data. Its repos are agent-written, and host
# git would honour their config (fsmonitor, filters, hooks), so working-tree state comes
# from sandbox-round.sh inspect, which runs in a network-less, capability-free container.
MARKER=.pera-sandbox-workspace
# Entries assembly and prepare create at the top level; anything else is someone's work.
KNOWN_TOP=" prj Documentation CLAUDE.md AGENTS.md .claude .devcontainer container .dockerignore .secrets .m2 .node-cache .agent-cli $MARKER "
# Prints one problem per line, prefixed "hard " (--discard-unharvested cannot override)
# or "soft ". Every check that cannot complete reports a problem: it fails closed.
reset_problems() {
    local r gd out status head refs sha name state ws rec errf entry n
    soft() { printf 'soft %s\n' "$*"; }
    hard() { printf 'hard %s\n' "$*"; }
    errf=$(mktemp) || { soft "cannot create a temporary file, so nothing was inspected"; return 0; }

    # A registered task pins this workspace; deleting it strands the task's rounds.
    state="${XDG_STATE_HOME:-$HOME/.local/state}/pera-sandbox-tasks"
    if [ -e "$state" ] && ! { [ -d "$state" ] && [ -r "$state" ] && [ -x "$state" ]; }; then
        soft "task state $state is unreadable; cannot confirm no task uses this workspace"
    fi
    for rec in "$state"/*/record.json; do
        [ -e "$rec" ] || continue
        ws=$(jq -r '.config.workspace // empty' "$rec" 2>/dev/null) || ws=
        if [ -z "$ws" ]; then
            soft "task record $rec is unreadable; cannot confirm it does not use this workspace"
        elif ws=$(realpath -m -- "$ws") && { under "$ws" "$SANDBOX_ROOT" || under "$SANDBOX_ROOT" "$ws"; }; then
            soft "registered to task $(basename "$(dirname "$rec")") (workspace $ws)"
        fi
    done

    for entry in "$SANDBOX_ROOT"/* "$SANDBOX_ROOT"/.[!.]* "$SANDBOX_ROOT"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        n=${entry##*/}
        case "$KNOWN_TOP" in
            *" $n "*) ;;
            *) soft "unexpected top-level entry $n (its contents are not checked)" ;;
        esac
    done

    for r in prj Documentation; do
        gd="$SANDBOX_ROOT/$r/.git"
        [ -e "$SANDBOX_ROOT/$r" ] || [ -L "$SANDBOX_ROOT/$r" ] || continue
        [ -d "$gd" ] && [ ! -L "$gd" ] || { soft "$r has no ordinary .git directory; cannot check it"; continue; }
        if ! out=$(bash "$SCAFFOLD/sandbox-round.sh" inspect --workspace "$SANDBOX_ROOT" --repository "$r" 2>"$errf"); then
            soft "$r could not be inspected ($(tail -n 1 "$errf"))"
            continue
        fi
        status=$(printf '%s' "$out" | jq -r '.status // empty' 2>/dev/null) || status=
        head=$(printf '%s' "$out" | jq -r '.head // empty' 2>/dev/null) || head=
        case "$status" in
            clean) ;;
            running) hard "$r is mounted by a running container; stop it first" ;;
            recovery-required) hard "$r has an interrupted round import; run sandbox-round.sh recover first (its recovery state is keyed by path and would outlive the reset)" ;;
            *) soft "$r is ${status:-in an unknown state} (uncommitted or in-progress work)" ;;
        esac
        # Linked worktrees can live outside this working tree, where inspect cannot see them.
        [ ! -e "$gd/worktrees" ] || soft "$r has linked worktrees (.git/worktrees); their work is not checked"
        # HEAD, every local branch and every stash entry, read from ref files as plain data.
        # packed-refs is parsed whole: gc packs refs/stash too, and a line that cannot be
        # parsed is reported rather than skipped.
        refs=$(cd "$gd" && {
            [ -n "$head" ] && echo "$head HEAD"
            find refs/heads -type f -print 2>/dev/null | while IFS= read -r f; do printf '%s %s\n' "$(head -c 80 "$f")" "$f"; done
            [ -f refs/stash ] && printf '%s refs/stash\n' "$(head -c 80 refs/stash)"
            [ -f logs/refs/stash ] && awk '{ print $2, "stash-entry" }' logs/refs/stash
            [ -f packed-refs ] && awk '/^#/ || /^\^/ || NF == 0 { next }
                NF != 2 { print "malformed", "packed-refs:" NR; next }
                $2 ~ /^refs\/heads\// || $2 == "refs/stash" { print $1, $2 }' packed-refs
        } || true)
        while read -r sha name; do
            [ -n "$sha" ] || continue
            if ! [[ $sha =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
                soft "$r $name is not a plain commit id; cannot confirm it was harvested"
            elif ! git -C "$SOURCE_ROOT/$r" cat-file -e "$sha^{commit}" 2>/dev/null \
                 || [ -z "$(git -C "$SOURCE_ROOT/$r" for-each-ref --contains "$sha" --count=1 2>/dev/null)" ]; then
                soft "$r $name (${sha:0:12}) is not on any ref in $SOURCE_ROOT/$r: unharvested commits"
            fi
        done <<< "$refs"
    done
    rm -f "$errf"
    return 0
}

if [ -e "$SANDBOX_ROOT" ]; then
    [ "$FORCE" = 1 ] || die "$SANDBOX_ROOT already exists. Use --force to rebuild (it refuses if work would be lost)."
    [ -d "$SANDBOX_ROOT" ] || die "$SANDBOX_ROOT exists but is not a directory; not touching it"
    # Only delete what this script built. Sandboxes assembled before the marker existed
    # are recognised by their layout.
    if [ ! -f "$SANDBOX_ROOT/$MARKER" ] && ! { [ -d "$SANDBOX_ROOT/prj/.git" ] \
            && [ -d "$SANDBOX_ROOT/Documentation/.git" ] && [ -f "$SANDBOX_ROOT/.devcontainer/Dockerfile" ]; }; then
        die "$SANDBOX_ROOT does not look like a sandbox this script assembled; not deleting it"
    fi
    echo "==> Checking $SANDBOX_ROOT for work that would be lost ..."
    problems=$(reset_problems)
    # sed, not grep: it never fails on no match, which pipefail would turn into an exit.
    # Anything not marked hard counts as soft, so an unprefixed line cannot be lost.
    hard_problems=$(printf '%s\n' "$problems" | sed -n 's/^hard //p')
    soft_problems=$(printf '%s\n' "$problems" | sed -e '/^hard /d' -e '/^$/d' -e 's/^soft //')
    if [ -n "$hard_problems" ]; then
        echo "ERROR: refusing to delete $SANDBOX_ROOT; --discard-unharvested does not override:" >&2
        printf '%s\n' "$hard_problems" | sed 's/^/         /' >&2
        [ -z "$soft_problems" ] || { echo "       Also found:" >&2; printf '%s\n' "$soft_problems" | sed 's/^/         /' >&2; }
        exit 1
    fi
    if [ -n "$soft_problems" ]; then
        if [ "$DISCARD" = 1 ]; then
            echo "WARN: --discard-unharvested given; discarding:" >&2
            printf '%s\n' "$soft_problems" | sed 's/^/       /' >&2
        else
            echo "ERROR: refusing to delete $SANDBOX_ROOT:" >&2
            printf '%s\n' "$soft_problems" | sed 's/^/         /' >&2
            echo "       Harvest or collect the work first (OPERATOR.md), use a different SANDBOX_ROOT," >&2
            echo "       or add --discard-unharvested to delete it anyway." >&2
            exit 1
        fi
    fi
    # Move aside first, so a partial delete never leaves a half-sandbox at SANDBOX_ROOT
    # without its marker, and never cross into a mount inside the tree.
    echo "Removing existing sandbox at $SANDBOX_ROOT ..."
    tomb="$SANDBOX_ROOT.deleting.$$"
    [ ! -e "$tomb" ] && [ ! -L "$tomb" ] || die "$tomb already exists; remove it by hand first"
    mv -T -- "$SANDBOX_ROOT" "$tomb"
    rm -rf --one-file-system -- "$tomb" \
        || die "the old sandbox was moved to $tomb but could not be fully deleted; remove it by hand"
fi
mkdir -p "$SANDBOX_ROOT"
printf 'Assembled by new-sandbox.sh; new-sandbox.sh --force only deletes directories carrying this file.\n' \
    > "$SANDBOX_ROOT/$MARKER"

# --- 1. Clone both repos from the Windows working copies (one-time 9p read) ---
# --single-branch: the agent gets the FULL history of the working branch (needed for
# blame/prior-conversion context/revertability) but no other branches' objects — depth
# without breadth.
echo "==> Cloning prj (committed state of current branch) ..."
git clone --no-hardlinks --single-branch -c core.autocrlf=false -c core.eol=lf "$SOURCE_ROOT/prj" "$SANDBOX_ROOT/prj"
echo "==> Cloning Documentation ..."
git clone --no-hardlinks --single-branch -c core.autocrlf=false -c core.eol=lf "$SOURCE_ROOT/Documentation" "$SANDBOX_ROOT/Documentation"
# Note: uncommitted changes in the Windows working copies are intentionally NOT carried over.

# Strip remotes: the agent must not have a push/fetch target (its origin would point at
# the REAL working copies via /mnt/c — unreachable in-container, but a host-side foot-gun).
# Harvest never needs them: you fetch FROM the real repo, pointing AT the sandbox path.
git -C "$SANDBOX_ROOT/prj" remote remove origin
git -C "$SANDBOX_ROOT/Documentation" remote remove origin

# Per-repo, because only /workspace persists between the prepare and agent containers.
echo "==> Commit identity: $GIT_NAME <$GIT_EMAIL>"
for r in prj Documentation; do
    git -C "$SANDBOX_ROOT/$r" config user.name  "$GIT_NAME"
    git -C "$SANDBOX_ROOT/$r" config user.email "$GIT_EMAIL"
done

# --- 2. Overlay the git-ignored AI assets -------------------------------------
# Copy the directories' contents, not the directories: if the clone already has one
# (a tracked file under it), `cp -r src dst` would nest the copy at dst/.agents/.agents.
for d in .github .agents; do
    if [ -d "$SOURCE_ROOT/prj/$d" ]; then
        echo "==> Overlaying prj/$d ..."
        mkdir -p "$SANDBOX_ROOT/prj/$d"
        cp -r "$SOURCE_ROOT/prj/$d/." "$SANDBOX_ROOT/prj/$d/"
    fi
done
# D5: prove the required assets arrived where the agent reads them, as regular files.
if [ "$ALLOW_MISSING_ASSETS" = 0 ]; then
    for a in "${REQUIRED_ASSETS[@]}"; do
        [ -f "$SANDBOX_ROOT/prj/$a" ] && [ ! -L "$SANDBOX_ROOT/prj/$a" ] \
            || die "prj/$a did not reach the sandbox as a regular file"
    done
fi

# --- 3. Sandbox agent instructions + Claude settings + container definition ---
cp "$SCAFFOLD/overlay/CLAUDE.md" "$SANDBOX_ROOT/CLAUDE.md"
cp "$SCAFFOLD/overlay/CLAUDE.md" "$SANDBOX_ROOT/AGENTS.md"   # Copilot CLI reads AGENTS.md
# One canonical project settings file: the image bakes the same file and run-agent refuses a
# workspace copy that differs (finding N5). The mandatory policy is the image's managed file.
mkdir -p "$SANDBOX_ROOT/.claude"
cp "$SCAFFOLD/container/claude-project-settings.json" "$SANDBOX_ROOT/.claude/settings.json"
cp -r "$SCAFFOLD/.devcontainer" "$SANDBOX_ROOT/.devcontainer"
cp -r "$SCAFFOLD/container" "$SANDBOX_ROOT/container"
cp "$SCAFFOLD/dockerignore" "$SANDBOX_ROOT/.dockerignore"
# Scaffold lives on /mnt/c — normalize line endings on everything we copied from it.
find "$SANDBOX_ROOT/.devcontainer" "$SANDBOX_ROOT/container" "$SANDBOX_ROOT/.claude" \
     "$SANDBOX_ROOT/CLAUDE.md" "$SANDBOX_ROOT/AGENTS.md" "$SANDBOX_ROOT/.dockerignore" \
     -type f -exec sed -i 's/\r$//' {} +

# --- 3b. Corporate root CAs (Zscaler TLS interception) ------------------------
# Stage the WSL distro's custom anchors so the Dockerfile can bake them into the
# image's system + Java + Node trust stores. Empty dir is fine off-network.
mkdir -p "$SANDBOX_ROOT/container/certs"
if compgen -G "/etc/pki/ca-trust/source/anchors/*.crt" > /dev/null; then
    echo "==> Staging corporate root CAs ..."
    cp /etc/pki/ca-trust/source/anchors/*.crt "$SANDBOX_ROOT/container/certs/"
fi

# --- 4. Nexus credentials for the prepare phase only --------------------------
mkdir -p "$SANDBOX_ROOT/.secrets"
cp "$WIN_M2" "$SANDBOX_ROOT/.secrets/settings.xml"
cp "$WIN_NPMRC" "$SANDBOX_ROOT/.secrets/npmrc"
chmod 600 "$SANDBOX_ROOT/.secrets/settings.xml" "$SANDBOX_ROOT/.secrets/npmrc"

echo ""
echo "Sandbox ready at $SANDBOX_ROOT"
# Point at the guarded procedure rather than printing a shell recipe (finding E5): a
# plain `podman run ... bash` has no lockdown and still holds the prepare credentials.
cat <<EOF

Next steps: follow QUICKSTART.md from step 2 (build the image), step 3 (prepare),
then step 4 (run-agent or run-copilot). Its commands assume ~/pera-sandbox; if you
set SANDBOX_ROOT, use $SANDBOX_ROOT and a matching container-name suffix instead.
Start agents only through run-agent / run-copilot. An interactive shell in the
image has no firewall lockdown and still holds the Nexus credentials.

Review from Windows:  \\\\wsl\$\\centos-9\\${SANDBOX_ROOT#/}
EOF
