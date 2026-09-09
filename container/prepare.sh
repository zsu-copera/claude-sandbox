#!/bin/bash
# Prepare phase: warm every cache the locked-down agent will need, while the
# network is still open. Run once per fresh sandbox (idempotent to re-run).
#
# Zscaler on this network kills direct downloads from nodejs.org / registry.npmjs.org /
# deb.debian.org, so EVERYTHING routes through the internal Nexus:
#   - Maven deps      -> nexus maven-public   (creds: .secrets/settings.xml)
#   - npm packages    -> nexus java-npm-group-public (creds: .secrets/npmrc)
#   - node v22.13.0   -> assembled locally from the node-linux-x64 npm package and
#                        fed to frontend-maven-plugin via -DnodeDownloadRoot=file://…
#                        (CLI property override — the poms stay untouched)
#
# run-agent purges all staged credentials before the autonomous session starts.
set -euo pipefail

# Guard against the classic podman-flag-placement mistake: options like
# `-e PREPARE_PROFILES=...` placed AFTER the image name arrive here as arguments
# (and the env var silently stays unset). Fail loudly instead of prepping defaults.
if [ $# -gt 0 ]; then
    echo "ERROR: prepare-sandbox takes no arguments (got: $*)" >&2
    echo "       If you meant to set PREPARE_PROFILES, podman options must come BEFORE" >&2
    echo "       the image name:  podman run ... -e PREPARE_PROFILES=\"...\" pera-sandbox prepare-sandbox" >&2
    exit 2
fi

WS=/workspace
SETTINGS="$WS/.secrets/settings.xml"
NPMRC_SRC="$WS/.secrets/npmrc"
NPM_REG="https://nexus-repo.isd.copera.org/repository/java-npm-group-public/"

# Node versions are discovered from the <nodeVersion> pins in the module poms
# (they differ per module: e.g. agency=v22.13.0, shared=v18.10.0). Each needs the
# npm version that node release bundles — extend this map if a pom pins a new one.
declare -A NPM_FOR=(
    [v22.13.0]=10.9.2
    [v18.10.0]=8.19.2
    [v16.13.1]=8.1.2
    [v14.17.5]=6.14.14
)
NODE_CACHE="$WS/.node-cache"

[ -d "$WS/prj" ] || { echo "ERROR: $WS/prj not found — is the sandbox mounted at /workspace?" >&2; exit 1; }
[ -d "$WS/Documentation" ] || echo "WARN: $WS/Documentation missing — conversion playbooks will be unavailable" >&2
[ -f "$SETTINGS" ] || { echo "ERROR: $SETTINGS missing — re-run new-sandbox.sh on the host" >&2; exit 1; }
[ -f "$NPMRC_SRC" ] || { echo "ERROR: $NPMRC_SRC missing — re-run new-sandbox.sh on the host" >&2; exit 1; }

# Sanity-check the AI assets that are git-ignored upstream (must come from the overlay).
[ -f "$WS/prj/.github/copilot-instructions.md" ] || echo "WARN: prj/.github overlay missing" >&2
[ -d "$WS/prj/.agents/skills/agency-jsp-to-angular" ] || echo "WARN: agency-jsp-to-angular skill missing" >&2

echo "==> Opening firewall for the prepare phase"
sudo /usr/local/bin/init-firewall.sh open

git config --global --add safe.directory '*' 2>/dev/null || true

# --- Commit identity ------------------------------------------------------------
# Without one, git refuses to commit and the agent invents its own: JWA-2905 round 01
# landed as "PERA Sandbox Agent <agent@sandbox.local>", which maps to no Bitbucket
# account and breaks blame/PR attribution.
#
# Set it PER-REPO, not --global. run-agent runs in a SEPARATE container and only
# /workspace and the config volumes persist (same reason the CLIs are staged on the
# workspace mount below), so a --global config written here never reaches the agent.
# Per-repo config lives in /workspace/<repo>/.git/config, which does persist.
#
# The human who audits and pushes the work is the author; if an agent wants to record
# itself, it does that with a Co-authored-by trailer naming whichever agent actually ran.
#
# core.autocrlf=input stops a Linux agent ever writing CRLF into repos whose Windows
# checkouts use autocrlf=true.
echo "==> Setting commit identity (${SANDBOX_GIT_NAME:-Zhan} <${SANDBOX_GIT_EMAIL:-zsu@copera.org}>)"
for _repo in "$WS/prj" "$WS/Documentation"; do
  [ -d "$_repo/.git" ] || continue
  git -C "$_repo" config user.name     "${SANDBOX_GIT_NAME:-Zhan}"
  git -C "$_repo" config user.email    "${SANDBOX_GIT_EMAIL:-zsu@copera.org}"
  git -C "$_repo" config core.autocrlf input
done
unset _repo

echo "==> Staging npm credentials (~/.npmrc, purged by run-agent)"
cp "$NPMRC_SRC" "$HOME/.npmrc"
chmod 600 "$HOME/.npmrc"

# --- Refresh agent CLIs to latest -----------------------------------------------
# The run-agent/run-copilot containers are SEPARATE from this one (only /workspace
# and the config volumes persist), so refreshed CLIs are staged on the workspace
# mount: Claude as a ~/.local tarball that run-agent unpacks ($HOME is the same
# absolute path in every container, so the installer's symlinks stay valid), and
# Copilot as an npm prefix install (relative symlinks, self-contained). Non-fatal:
# on failure the agents fall back to the image-baked versions.
AGENT_CLI="$WS/.agent-cli"
mkdir -p "$AGENT_CLI"

echo "==> Refreshing Claude Code (native installer -> $AGENT_CLI/claude-local.tgz)"
if curl -fsSL https://claude.ai/install.sh | bash \
        && tar -C "$HOME" -czf "$AGENT_CLI/claude-local.tgz" .local; then
    echo "    -> staged: $("$HOME/.local/bin/claude" --version 2>/dev/null || echo '(version check failed)')"
else
    rm -f "$AGENT_CLI/claude-local.tgz"
    echo "WARN: Claude Code refresh failed — run-agent will use the image-baked CLI" >&2
fi

echo "==> Refreshing Copilot CLI (Nexus npm -> $AGENT_CLI/copilot)"
if NPM_CONFIG_PREFIX="$AGENT_CLI/copilot" npm install -g "@github/copilot" \
        --no-audit --no-fund --registry="$NPM_REG" >/dev/null; then
    echo "    -> staged: $("$AGENT_CLI/copilot/bin/copilot" --version 2>/dev/null || echo '(version check failed)')"
else
    rm -rf "$AGENT_CLI/copilot"
    echo "WARN: Copilot CLI refresh failed — run-copilot will use the image-baked CLI" >&2
fi

# --- Assemble the node dist tarballs frontend-maven-plugin expects --------------
# Official layout: node-v.../bin/node + lib/node_modules/npm (bundled npm — the poms
# don't set npmVersion, so the plugin uses "provided", i.e. the one inside the tarball).
build_node_tarball() {
    local NODE_V="$1" NPM_V="$2"
    [ -f "$NODE_CACHE/$NODE_V/node-$NODE_V-linux-x64.tar.gz" ] && return 0
    echo "==> Building node $NODE_V dist tarball (npm $NPM_V) from Nexus npm packages"
    local work dist
    work=$(mktemp -d)
    pushd "$work" >/dev/null
    npm pack "node-linux-x64@${NODE_V#v}" "npm@$NPM_V" --registry="$NPM_REG" >/dev/null
    dist="node-$NODE_V-linux-x64"
    mkdir -p "$dist/bin" "$dist/lib/node_modules"
    tar -xzf "node-linux-x64-${NODE_V#v}.tgz"
    cp package/bin/node "$dist/bin/node" && chmod 755 "$dist/bin/node"
    rm -rf package
    tar -xzf "npm-$NPM_V.tgz"
    mv package "$dist/lib/node_modules/npm"
    ln -s ../lib/node_modules/npm/bin/npm-cli.js "$dist/bin/npm"
    ln -s ../lib/node_modules/npm/bin/npx-cli.js "$dist/bin/npx"
    mkdir -p "$NODE_CACHE/$NODE_V"
    tar -czf "$NODE_CACHE/$NODE_V/node-$NODE_V-linux-x64.tar.gz" "$dist"
    popd >/dev/null
    rm -rf "$work"
    echo "    -> $NODE_CACHE/$NODE_V/node-$NODE_V-linux-x64.tar.gz"
}

NEEDED_VERSIONS=$(grep -rho '<nodeVersion>v[0-9.]*</nodeVersion>' "$WS/prj" --include=pom.xml \
    | sed 's/<[^>]*>//g' | sort -u)
echo "==> Node versions pinned across module poms: $(echo $NEEDED_VERSIONS | tr '\n' ' ')"
for v in $NEEDED_VERSIONS; do
    if [ -z "${NPM_FOR[$v]:-}" ]; then
        echo "ERROR: no bundled-npm mapping for node $v — extend NPM_FOR in prepare.sh" >&2
        exit 1
    fi
    build_node_tarball "$v" "${NPM_FOR[$v]}"
done

# Root npm ci BEFORE Maven: the grunt tasks load their plugins (grunt-string-replace
# et al.) from the prj-root node_modules.
echo "==> Root npm ci (Grunt tooling)"
if [ -f "$WS/prj/package.json" ]; then
    (cd "$WS/prj" && npm ci --no-audit --no-fund --registry="$NPM_REG")
fi

# Profiles to warm — override per sandbox with:  podman run -e PREPARE_PROFILES=...
# Comma-separated, passed straight to -P. Parent+module profile ids (case-sensitive):
#   agencyWWW agencyintra memberWWW memberintra vendorWWW vendorintra www intra
# A profile only builds offline later if it (or a superset) was warmed here.
PROFILES="${PREPARE_PROFILES:-agencyWWW}"

echo "==> Maven build: profiles [$PROFILES]"
cd "$WS/prj"
# Maven cache lands in /workspace/.m2 (MAVEN_OPTS in the image) so it survives
# into the locked-down agent container.
mvn clean install -P "$PROFILES" -s "$SETTINGS" -DskipTests \
    -DnodeDownloadRoot="file://$NODE_CACHE/" \
    -Dmaven.wagon.http.ssl.insecure=true

# Intra variants build the same modules with productionIntra Angular configs and
# different WAR packaging (iagency/imember) — selecting a profile offline needs no
# new downloads IF its modules were warmed. agencyWWW covers agencyintra;
# memberWWW covers memberintra. Exception: vendorintra and intra add the itools
# module, which no WWW profile warms — include them here explicitly if needed.

# --- Make the warmed cache resolvable offline ---------------------------------
# Every artifact just downloaded carries a `_remote.repositories` file attributing it
# to repository id `nexus` (from $SETTINGS). That settings.xml is credentialed, so
# run-agent deletes it — which would leave the cache present but UNUSABLE: Maven's
# enhanced local repository refuses artifacts whose origin repo id isn't declared in
# the current build context, so `-o` fails on the very first plugin. Stripping the
# tracking files makes the artifacts count as locally installed, which resolves
# unconditionally and needs no settings.xml (so no credentials have to survive).
#
# This belongs here, not in the Dockerfile: the cache lives on the bind-mounted
# workspace, not in the image. It must also run AFTER all warming above.
MVN_REPO="$WS/.m2/repository"
if [ -d "$MVN_REPO" ]; then
    echo "==> Making the warmed cache offline-resolvable (stripping _remote.repositories)"
    find "$MVN_REPO" -name _remote.repositories -delete
else
    echo "WARN: $MVN_REPO not found — offline builds will fail; did the Maven warm-up run?" >&2
fi

echo ""
echo "Prepare complete. Next: 'run-agent' (locks the firewall, purges credentials, starts Claude)."
