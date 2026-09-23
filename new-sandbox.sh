#!/bin/bash
# WSL-native equivalent of New-Sandbox.ps1 — assembles the disposable Claude Code
# sandbox INSIDE the WSL distro filesystem (fast container bind mounts; /mnt/c
# would go through 9p and cripple the Maven/npm builds).
#
# Run from Windows:   wsl -d centos-9 -- bash /mnt/c/work/pera/claude-sandbox/new-sandbox.sh [--force]
# Review from Windows at: \\wsl$\centos-9\home\<user>\pera-sandbox
set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-/mnt/c/work/pera}"
SANDBOX_ROOT="${SANDBOX_ROOT:-$HOME/pera-sandbox}"
SCAFFOLD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=0
[ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ] && FORCE=1

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
[ -d "$SOURCE_ROOT/prj/.github" ] || echo "WARN: prj/.github not found — instruction files will be missing in the sandbox" >&2
[ -d "$SOURCE_ROOT/prj/.agents" ] || echo "WARN: prj/.agents not found — conversion skills will be missing in the sandbox" >&2

if [ -e "$SANDBOX_ROOT" ]; then
    if [ "$FORCE" = 1 ]; then
        echo "Removing existing sandbox at $SANDBOX_ROOT ..."
        rm -rf "$SANDBOX_ROOT"
    else
        echo "ERROR: $SANDBOX_ROOT already exists. Use --force to rebuild (un-reviewed agent commits there will be lost)." >&2
        exit 1
    fi
fi
mkdir -p "$SANDBOX_ROOT"

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
if [ -d "$SOURCE_ROOT/prj/.github" ]; then
    echo "==> Overlaying prj/.github (instructions) ..."
    cp -r "$SOURCE_ROOT/prj/.github" "$SANDBOX_ROOT/prj/.github"
fi
if [ -d "$SOURCE_ROOT/prj/.agents" ]; then
    echo "==> Overlaying prj/.agents (skills) ..."
    cp -r "$SOURCE_ROOT/prj/.agents" "$SANDBOX_ROOT/prj/.agents"
fi

# --- 3. Sandbox agent instructions + Claude settings + container definition ---
cp "$SCAFFOLD/overlay/CLAUDE.md" "$SANDBOX_ROOT/CLAUDE.md"
cp "$SCAFFOLD/overlay/CLAUDE.md" "$SANDBOX_ROOT/AGENTS.md"   # Copilot CLI reads AGENTS.md
cp -r "$SCAFFOLD/overlay/.claude" "$SANDBOX_ROOT/.claude"
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
