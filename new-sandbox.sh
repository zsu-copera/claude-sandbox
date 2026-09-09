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
WIN_M2="${WIN_M2:-/mnt/c/Users/su/.m2/settings.xml}"
WIN_NPMRC="${WIN_NPMRC:-/mnt/c/Users/su/.npmrc}"
FORCE=0
[ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ] && FORCE=1

# --- Preflight ---------------------------------------------------------------
for p in "$SOURCE_ROOT/prj/.git" "$SOURCE_ROOT/Documentation/.git"; do
    [ -e "$p" ] || { echo "ERROR: expected git repo not found: $p" >&2; exit 1; }
done
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
cat <<EOF

Next steps (inside this WSL distro):
  cd $SANDBOX_ROOT
  podman build -t pera-sandbox -f .devcontainer/Dockerfile .
  podman run -it --cap-add=NET_ADMIN --cap-add=NET_RAW \\
    -v $SANDBOX_ROOT:/workspace -v pera-claude-config:/home/vscode/.claude \\
    -w /workspace pera-sandbox bash
  # then in the container:  prepare-sandbox   ->   run-agent

Review from Windows:  \\\\wsl\$\\centos-9\\${SANDBOX_ROOT#/}
EOF
