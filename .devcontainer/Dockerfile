# CentOS Stream 9 base: Zscaler policy on this network blocks deb.debian.org and
# NodeSource (403) but allows mirror.stream.centos.org, EPEL, nodejs.org, and
# archive.apache.org (verified 2026-07). Bonus: same distro family as the centos-9
# WSL host podman runs in.
FROM quay.io/centos/centos:stream9

# Corporate TLS interception (Zscaler): trust the PERA root CAs BEFORE any dnf/curl
# (the dnf mirrors are HTTPS and get MITM'd). new-sandbox.sh stages the WSL host's
# anchors into container/certs/ (dir may be empty on a network without interception).
# On RHEL-family, update-ca-trust also regenerates the Java trust store
# (/etc/pki/ca-trust/extracted/java/cacerts) — no keytool step needed.
COPY container/certs/ /etc/pki/ca-trust/source/anchors/
RUN update-ca-trust

# Toolchain: JDK 17 (prj target), Node 22 (matches the v22.13.0 the
# frontend-maven-plugin pins per module), Chromium (Karma ChromeHeadless),
# iptables/ipset/bind-utils (init-firewall.sh), bubblewrap/socat (Claude native sandbox).
RUN dnf -y install epel-release \
    && dnf -y module enable nodejs:22 \
    && dnf -y install --setopt=install_weak_deps=False \
        java-17-openjdk-devel \
        nodejs npm \
        chromium \
        iptables-nft ipset bind-utils \
        bubblewrap socat \
        git openssh-clients \
        jq less procps-ng \
        sudo util-linux util-linux-core tar gzip unzip which \
    && dnf clean all

# Maven 3.9 via the internal Nexus (Zscaler resets direct tarball downloads mid-stream;
# maven-public serves the distribution anonymously — it's a regular Central artifact)
ARG MAVEN_VERSION=3.9.9
ARG NEXUS_MAVEN=https://nexus-repo.isd.copera.org/repository/maven-public
RUN curl -fsSL "${NEXUS_MAVEN}/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
        | tar -xz -C /opt \
    && ln -s /opt/apache-maven-${MAVEN_VERSION} /opt/maven

# Stable Chrome path for Karma regardless of which binary name EPEL ships
RUN ln -sf "$(command -v chromium-browser || command -v chromium)" /usr/local/bin/chrome

# Replace the dnf node BINARY with the official build: the dnf-built node SEGFAULTS
# on Angular builds (esbuild/sass native pipeline). Shadowing via /usr/local/bin is
# NOT enough — npm prepends its own execPath dir (/usr/bin) to every script PATH,
# so /usr/bin/node itself must be the official binary. dnf's npm (pure JS) runs on
# it unaffected. Version matches the poms' pin.
ARG NODE_OFFICIAL=22.13.0
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc \
    cd /tmp \
    && npm pack "node-linux-x64@${NODE_OFFICIAL}" \
        --registry=https://nexus-repo.isd.copera.org/repository/java-npm-group-public/ \
    && tar -xzf "node-linux-x64-${NODE_OFFICIAL}.tgz" \
    && install -m 0755 package/bin/node /usr/bin/node \
    && install -m 0755 package/bin/node /usr/local/bin/node \
    && rm -rf package "node-linux-x64-${NODE_OFFICIAL}.tgz" \
    && /usr/bin/node --version && npm --version

# Global Angular CLI: the Gruntfile's runProcess() strips the child environment on
# Linux (pera-grunt-utils.js), so `ng` must resolve from bash's DEFAULT PATH
# (/usr/bin). The global CLI auto-delegates to each workspace's local version.
# Auth for the Nexus npm proxy comes in as a build secret (never in a layer):
#   podman build --secret id=npmrc,src=.secrets/npmrc ...
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc \
    npm install -g @angular/cli@21 \
        --registry=https://nexus-repo.isd.copera.org/repository/java-npm-group-public/ \
    && command -v ng

# GitHub Copilot CLI — same Nexus npm channel (registry.npmjs.org is Zscaler-blocked).
# Separate layer from @angular/cli so version bumps don't cross-invalidate.
# NOTE: `gh` is deliberately NOT installed — with api.github.com allowlisted in Copilot
# sessions it would be a ready-made exfiltration tool (see run-copilot deny rules).
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc \
    npm install -g "@github/copilot" \
        --registry=https://nexus-repo.isd.copera.org/repository/java-npm-group-public/ \
    && command -v copilot && copilot --version

# Non-root user (devcontainer convention). Passwordless sudo is scoped to the ONE
# command that needs it: init-firewall.sh (the only sudo call site in prepare.sh,
# run-agent.sh and run-copilot.sh). A blanket NOPASSWD:ALL would make the agent
# effectively root — able to `sudo iptables -F` past the egress lockdown and `sudo cat`
# past the settings.json Read deny rules — which would undercut the isolation the
# firewall is there to provide. Args are intentionally unconstrained: callers pass
# `open`, `lockdown`, and per-mode domain lists; `open` is guarded inside the script.
RUN useradd -m -s /bin/bash vscode \
    && echo "vscode ALL=(ALL) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/vscode \
    && chmod 0440 /etc/sudoers.d/vscode \
    && visudo -c -q

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk \
    M2_HOME=/opt/maven \
    PATH=/opt/maven/bin:$PATH \
    # Maven repo on the workspace mount: containers are ephemeral, the cache the
    # prepare phase warms must be the same one the locked-down agent reads.
    MAVEN_OPTS="-Dmaven.repo.local=/workspace/.m2/repository" \
    CHROME_BIN=/usr/local/bin/chrome \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_AUTOUPDATER=1 \
    # Node ignores the system store — covers npm, ng, and the Claude CLI (RHEL bundle path)
    NODE_EXTRA_CA_CERTS=/etc/pki/tls/certs/ca-bundle.crt

# Sandbox scripts (sed strips CRLF in case they were authored on Windows)
COPY container/init-firewall.sh /usr/local/bin/init-firewall.sh
COPY container/prepare.sh       /usr/local/bin/prepare-sandbox
COPY container/run-agent.sh     /usr/local/bin/run-agent
COPY container/run-copilot.sh   /usr/local/bin/run-copilot
COPY container/copilot-settings.json    /usr/local/share/copilot-defaults/settings.json
RUN sed -i 's/\r$//' /usr/local/bin/init-firewall.sh /usr/local/bin/prepare-sandbox /usr/local/bin/run-agent \
        /usr/local/bin/run-copilot /usr/local/share/copilot-defaults/*.json \
    && chmod 755    /usr/local/bin/init-firewall.sh /usr/local/bin/prepare-sandbox /usr/local/bin/run-agent \
        /usr/local/bin/run-copilot \
    && chmod 0644   /usr/local/share/copilot-defaults/settings.json

# Copilot guardrail installed as MACHINE POLICY, not user config. Policy hooks load
# before all others, cannot be disabled by `disableAllHooks`, and live outside the
# agent's reach — which is what makes run-copilot's --allow-all-tools defensible.
# It denies obfuscated commands and closes the `git -C . push` hole that the
# --deny-tool prefix rules do not catch.
#
# The ownership and mode below are a REQUIREMENT, not hygiene: on POSIX the CLI
# ignores any policy file that is not root-owned or that is group/world-writable,
# and it does so silently. A malformed or rejected policy file fails OPEN.
COPY container/guard-shell-command.js /usr/local/lib/copilot-guard/guard-shell-command.js
COPY container/copilot-policy.json    /etc/github-copilot/policy.d/10-guardrails.json
RUN sed -i 's/\r$//' /usr/local/lib/copilot-guard/guard-shell-command.js \
        /etc/github-copilot/policy.d/10-guardrails.json \
    && chown root:root /usr/local/lib/copilot-guard/guard-shell-command.js \
        /etc/github-copilot/policy.d/10-guardrails.json \
    && chmod 0644 /etc/github-copilot/policy.d/10-guardrails.json \
    && chmod 0755 /usr/local/lib/copilot-guard/guard-shell-command.js \
    && node --check /usr/local/lib/copilot-guard/guard-shell-command.js

# Claude Code's mandatory policy (findings E2/E3). Managed settings outrank user and
# project settings and carry the locks those scopes cannot undo (managed-only permission
# rules, hooks and MCP servers; sandbox required, no unsandboxed escape). The agent must
# not be able to write any of it: root-owned, not group/world-writable, and an EMPTY
# root-owned drop-in directory so nothing else can supply a fragment. A file that does
# not parse makes the CLI refuse to start. claude-project-settings.json is the canonical
# /workspace/.claude/settings.json that run-agent compares the workspace copy against (N5).
COPY container/claude-managed-settings.json /etc/claude-code/managed-settings.json
COPY container/claude-project-settings.json /usr/local/share/pera-sandbox/claude-project-settings.json
RUN sed -i 's/\r$//' /etc/claude-code/managed-settings.json \
        /usr/local/share/pera-sandbox/claude-project-settings.json \
    && mkdir -p /etc/claude-code/managed-settings.d \
    && chown -R root:root /etc/claude-code /usr/local/share/pera-sandbox \
    && chmod 0755 /etc/claude-code /etc/claude-code/managed-settings.d /usr/local/share/pera-sandbox \
    && chmod 0644 /etc/claude-code/managed-settings.json \
        /usr/local/share/pera-sandbox/claude-project-settings.json \
    && jq empty /etc/claude-code/managed-settings.json \
        /usr/local/share/pera-sandbox/claude-project-settings.json

# Guarded startup (finding E5): root-owned `claude` / `copilot` wrappers first on PATH
# refuse to start an agent CLI before lockdown or while capabilities are held, then exec
# the baked binary. One script; it dispatches on the name it was invoked as.
COPY container/agent-cli-guard.sh /usr/local/lib/pera-sandbox/bin/claude
RUN sed -i 's/\r$//' /usr/local/lib/pera-sandbox/bin/claude \
    && ln -s claude /usr/local/lib/pera-sandbox/bin/copilot \
    && chown -R root:root /usr/local/lib/pera-sandbox \
    && chmod 0755 /usr/local/lib/pera-sandbox /usr/local/lib/pera-sandbox/bin \
        /usr/local/lib/pera-sandbox/bin/claude

# Claude Code (native installer; autoupdate disabled — the runtime firewall would block
# it). This baked CLI is the only one the launchers run (finding N5, decision A): a copy
# on the workspace would be agent-writable and persist into the next session. New CLI
# versions and models therefore need an image rebuild.
USER vscode
RUN curl -fsSL https://claude.ai/install.sh | bash
# Leave no `claude` in ~/.local/bin (E5): the stock ~/.bashrc puts that directory back in
# front of the wrapper in every interactive or login shell, where `claude` would then run
# the real CLI unguarded (Phase 3 review, pass 1 M1). The installer's link moves to a
# root-owned path that only the wrapper execs; the versioned binary stays where it is.
USER root
RUN target=$(readlink -f /home/vscode/.local/bin/claude) \
    && [ -x "$target" ] \
    && install -d -m 0755 -o root -g root /usr/local/lib/pera-sandbox/real \
    && ln -s "$target" /usr/local/lib/pera-sandbox/real/claude \
    && rm /home/vscode/.local/bin/claude
USER vscode
# CLAUDE_CONFIG_DIR: keep ALL login/config state (incl. .claude.json, which otherwise
# lives at ~/.claude.json in the ephemeral container fs) inside the mounted
# pera-claude-config volume, so auth survives container exits.
# The wrapper directory must come first on PATH (verify-scaffold S25).
ENV PATH=/usr/local/lib/pera-sandbox/bin:$PATH \
    CLAUDE_CONFIG_DIR=/home/vscode/.claude
