# PERA Claude Code Sandbox

> **New here? Start with [QUICKSTART.md](QUICKSTART.md)** — 4 commands + one login.
> Questions? Check the [FAQ](FAQ.md) first.

Runs a coding agent **autonomously** inside an isolated container that holds a disposable
copy of both repos. Two entrypoints share one image and one prepared workspace:
**`run-agent`** (Claude Code, `bypassPermissions`) and **`run-copilot`** (GitHub Copilot
CLI, `--allow-all-tools`). Isolation layers:

1. **Container** (rootless podman) — agent sees only the sandbox copy of the workspace,
   never your real working copies or the Windows filesystem.
2. **Firewall** — at run time, egress is locked to **the active agent's provider
   endpoints** (Anthropic-only for Claude; Copilot API hosts for Copilot — see the
   Copilot section for the difference). Nexus, npm, Bitbucket, and the dev databases
   (AS400 / Oracle) are unreachable; blocked connections are REJECTed so tools fail fast.
   **Lockdown is one-way:** the agent holds passwordless sudo for `init-firewall.sh` alone,
   so the script refuses `open` once its container has locked down, and pins the allowlist
   the first lockdown committed to — a later `lockdown <other-domains>` is ignored.
3. **Agent-native guardrails** — Claude: settings deny rules **plus a working bubblewrap
   sandbox** on every Bash command (capabilities are dropped before the agent starts, which
   is what bwrap needs — see the FAQ); Copilot: deny-tool/deny-url flags + built-in GitHub
   MCP disabled. Both agents run without `CAP_NET_ADMIN`, so neither can touch the firewall
   directly, and sudo is scoped to `init-firewall.sh` rather than `ALL`.

Work never leaves the sandbox on its own: the agent commits **locally only** — the sandbox
repos have **no remotes** and `git push` is deny-ruled besides; you review from Windows and
push yourself.

**Isolation model in one sentence:** the bind-mounted `~/pera-sandbox` is the single,
deliberate output channel — a disposable copy whose contents are inert data until a human
reviews and merges them. Treat everything in it as **unreviewed input**: review via
`git diff`, don't run builds/scripts out of it on the host, and don't open it in an IDE
that auto-runs tasks. Verification-by-execution belongs inside the container (contained)
or after review (trusted).

## Environment assumptions (verified 2026-07 on this network)

- **podman runs rootless inside the `centos-9` WSL2 distro** — no Docker Desktop, no
  `podman machine`. The sandbox workspace lives in the WSL filesystem (`~/pera-sandbox`)
  because bind mounts from `/mnt/c` (9p) would cripple the builds.
- **Zscaler intercepts TLS and blocks whole download categories.** Direct fetches from
  `deb.debian.org`, NodeSource, `nodejs.org`, `archive.apache.org`, and full downloads from
  most external hosts are killed (403 or mid-stream reset). Range probes may succeed where
  full downloads fail — always test full downloads.
- Therefore the image is **CentOS Stream 9** (mirror.stream.centos.org + EPEL are allowed),
  and every build artifact routes through the internal **Nexus**
  (`nexus-repo.isd.copera.org`): Maven deps + the Maven distribution itself via
  `maven-public`, npm via `java-npm-group-public`, and node v22.13.0 assembled from the
  `node-linux-x64` npm package (see prepare.sh) — the poms stay untouched via
  `-DnodeDownloadRoot=file:///workspace/.node-cache/`.
- The PERA/Zscaler root CAs are taken from the WSL host
  (`/etc/pki/ca-trust/source/anchors/`) and baked into the image's system, Java, and Node
  trust stores (`NODE_EXTRA_CA_CERTS`).
- `claude.ai` (installer) and `api.anthropic.com` are reachable — verified.

## Lifecycle

```
[host]     new-sandbox.sh    clone repos -> overlay AI assets -> stage CAs + creds
[build]    podman build      CentOS 9 + JDK17 + Maven 3.9 + Node 22 + Chromium + Claude Code
[prepare]  prepare-sandbox   network OPEN: node cache, mvn -P agencyWWW, npm ci   (one-time)
[run]      run-agent         firewall -> Anthropic only, purge creds, start claude
[review]   (host)            git log/diff in the sandbox -> fetch into real repo -> push
```

## Usage

### 1. Assemble the sandbox (from Windows)

```powershell
wsl -d centos-9 -- bash /mnt/c/work/pera/claude-sandbox/new-sandbox.sh --force
```

Clones `prj` + `Documentation` from the local Windows working copies (committed state of the
current branch — no SSH keys, LF endings), overlays the git-ignored AI assets
(`prj/.github`, `prj/.agents`), drops in the sandbox `CLAUDE.md` + `.claude/settings.json`,
stages the corp CAs, and copies `~\.m2\settings.xml` + `~\.npmrc` into `.secrets/`
(purged before the agent runs). `--force` rebuilds fresh — recommended per task/ticket.

### 2. Build the image (only when the Dockerfile changes)

```bash
# inside: wsl -d centos-9
cd ~/pera-sandbox
podman build --secret id=npmrc,src=.secrets/npmrc \
  -t pera-sandbox -f .devcontainer/Dockerfile .
```

(The secret feeds the global `@angular/cli` install through the Nexus npm proxy without
persisting credentials in an image layer.)

### 3. Prepare (network open — one-time per sandbox, ~30–60 min)

Default warms `agencyWWW` (which also covers `agencyintra` — intra twins share modules
and need no extra downloads; `-DBUILD=productionIntra` selects them offline). To warm
more portals, set the env var — **before the image name**, or podman passes it as a
script argument instead (the script rejects that with a pointed error):

```bash
podman run -d --name pera-prepare --userns=keep-id --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -e PREPARE_PROFILES="agencyWWW,memberWWW" \
  -v ~/pera-sandbox:/workspace -v pera-claude-config:/home/vscode/.claude \
  -w /workspace pera-sandbox prepare-sandbox
# note: vendorintra / intra additionally pull in the itools module — warm those
# profiles explicitly if the task needs them
```

```bash
podman run -d --name pera-prepare --userns=keep-id \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/pera-sandbox:/workspace -v pera-claude-config:/home/vscode/.claude \
  -w /workspace pera-sandbox prepare-sandbox
podman logs -f pera-prepare        # watch; exits when done
```

### 4. Run the agent (locked down)

```bash
podman run -it --name pera-agent --rm --userns=keep-id \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/pera-sandbox:/workspace -v pera-claude-config:/home/vscode/.claude \
  -w /workspace pera-sandbox run-agent
# headless:  ... pera-sandbox run-agent -p "Convert EPD-xxx per the agency-jsp-to-angular skill" \
#                --output-format stream-json --verbose
```

`run-agent` locks the firewall (Anthropic-only; self-tests that api.anthropic.com is
reachable AND example.com is refused — refuses to start otherwise), purges `.secrets/` and
`~/.npmrc`, re-resolves allowlist IPs every 15 min, then starts
`claude --dangerously-skip-permissions`. First ever run: complete the login flow (auth
persists in the `pera-claude-config` volume) and confirm the bypass prompt.

**Session lifecycle:** exiting Claude removes the container (`--rm`) and its firewall with
it — nothing keeps running on the host (`podman ps` should be empty). The workspace, agent
commits, uncommitted working-tree changes, build caches, login, and session transcripts all
persist. Restart anytime with the same command; `run-agent --continue` resumes the previous
conversation (arguments pass through to `claude`). If you stop mid-task, prefer
`--continue` over a fresh session so the agent keeps its context.

### 4b. GitHub Copilot CLI variant

Same sandbox, same image, same prepare — different entrypoint and auth volume:

```bash
# ONE-TIME per machine: login phase (github.com temporarily allowlisted for the
# device flow; authenticate with /login, trust /workspace, then exit)
podman run -it --rm --name pera-copilot --userns=keep-id \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/pera-sandbox:/workspace -v pera-copilot-config:/home/vscode/.copilot \
  -w /workspace pera-sandbox run-copilot --login

# Normal autonomous sessions (drop --login); headless: append --autopilot -p "task"
podman run -it --rm --name pera-copilot --userns=keep-id \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/pera-sandbox:/workspace -v pera-copilot-config:/home/vscode/.copilot \
  -w /workspace pera-sandbox run-copilot
```

The seeded `~/.copilot/settings.json` pins the model to **claude-opus-4-8** (verify with
`/model` on first run — Enterprise policy must expose it). `--continue`/`--resume` work
like Claude's. Autopilot continuation limit defaults to 5 (`--max-autopilot-continues`).

**"System vault not available" at first login — answer yes (plain text).** Containers
have no OS keyring; the token stores in the `pera-copilot-config` volume, which is the
same posture as Claude's auth volume and the org's existing `~/.m2`/`.npmrc` plaintext
credentials. The volume is host-user-readable only; in-container, `~/.copilot` sits
outside `/workspace` behind Copilot's path verification (we don't pass
`--allow-all-paths`). Treat the volume as credential storage: mount it only into
`run-copilot` sessions, and if a machine is compromised, revoke the session at
GitHub → Settings → Applications rather than merely deleting the volume.

**Firewall difference & residual risk (read this):** Copilot sessions allowlist the
Copilot API hosts plus GitHub's published web/api IP ranges (fetched live from
`api.github.com/meta` at session start; static fallback in `run-copilot.sh`). The CIDRs
are unavoidable: GitHub's load balancer rotates IPs between DNS resolutions, so per-host
snapshots fail (`api.githubcopilot.com` measured 0/15 reachable without them). Because
GitHub serves `github.com` and the Copilot API **from the same address pool**, IP-level
filtering cannot separate them — `github.com` (where the real `Documentation` repo
lives) is *technically connectable in every Copilot session*, and `--login` differs
only in intent, not network reach. The no-push barrier is therefore layered above the
network: built-in github-mcp-server disabled, `git push`/`git remote`/`gh` deny-ruled,
fetch-tool `--deny-url` on GitHub hosts, **no git credentials in the container** (a
stray `git push` 401s), no `gh` binary, no SSH keys, no git remotes, human review gate.
This is a meaningfully wider egress surface than Claude's Anthropic-only lockdown — for
maximum-paranoia overnight runs, prefer `run-agent`. Hostname-level separation would
require an SNI-aware filtering proxy (squid + owner-match iptables) — a possible future
hardening step. GitHub-side backstop: keep branch protection / PR-required on
`coloradopera/Documentation`.

### 5. Review from Windows

```powershell
wsl -d centos-9 -- git -C /home/su/pera-sandbox/prj log --oneline -20

# Pull into a review branch (works from any checked-out branch; fetch never touches
# your working tree). <your-working-branch> = the branch your working copy was on when
# the sandbox was assembled (the agent committed onto it). Use +<your-working-branch>:...
# to force-update an existing review branch.
cd C:\work\pera\prj
git fetch \\wsl$\centos-9\home\su\pera-sandbox\prj <your-working-branch>:review/agent-work
git diff <your-working-branch>...review/agent-work   # three dots: only the agent's changes
# integrate: push as a Bitbucket PR branch (recommended), merge, or cherry-pick
git push origin review/agent-work:feature/EPD-xxx
```

Repeat against `pera-sandbox/Documentation` if the task changed docs (two repos, two
harvests). On the first harvest, eyeball `git diff --stat` for whole-file rewrites —
that pattern would indicate line-ending noise (prj has no .gitattributes).

VS Code option: install the Dev Containers extension, set `dev.containers.dockerPath` to
`podman`, and open `\\wsl$\centos-9\home\su\pera-sandbox` → Reopen in Container.

## Caveats & known limits

- **Unit tests only** in the sandbox. Integration tests need the dev AS400/Oracle —
  unreachable by design. DB-dependent verification happens after review, on-network.
- **Credentials:** the agent can read anything in the container, including `~/.claude` auth.
  `.secrets/` + `~/.npmrc` are purged before every run and deny rules block reading them,
  but keep unrelated secrets out of the sandbox. Dev DB creds committed in test code are
  inert behind the firewall.
- **DNS egress stays open** (needed to resolve the API); the threat model is agent mistakes
  on a trusted repo, not malware exfiltration.
- **Maven "connection refused" at runtime** = the firewall doing its job. Re-run
  `prepare-sandbox` (network open) if a genuinely new dependency is needed. You cannot
  reopen a container that has locked down (see next item) — prepare is a separate
  container, so that path still works.
- **Lockdown is one-way, by design.** `init-firewall.sh open` exits 3 once the
  `CLAUDE_LOCKDOWN` marker chain exists, and the first successful lockdown pins its domain
  list in `/run/claude-lockdown-domains` (root-owned, unreadable to the agent); later
  lockdowns reuse it and ignore their arguments. The 15-min refresh loop and Copilot's
  `--login` mode are unaffected — each container's domain set is fixed before its first
  lockdown. To get an open network again, start a fresh container.
- **`/tmp` is writable inside the native sandbox** (`sandbox.filesystem.allowWrite`).
  Required, not incidental: Java ignores `$TMPDIR`, so `java.io.tmpdir` stays `/tmp` and
  the WAR assembly fails on a read-only `/tmp`. Everything else keeps full filesystem
  isolation. See the FAQ entry for the measurements.
- **Sudo is scoped to `init-firewall.sh`.** Not `NOPASSWD:ALL` — that would have made the
  agent effectively root, able to flush the firewall or read past the settings deny rules.
  Any new call site must use the absolute path, since `Defaults secure_path` excludes
  `/usr/local/bin`.
- **ipset fallback:** under rootless podman, init-firewall.sh auto-falls back to per-IP
  iptables rules when ipset can't be created in the user namespace.
- **Login not persisting?** Two past causes, both fixed in the current image: the
  `pera-claude-config` volume must be created by a `--userns=keep-id` container (one made
  without it is unwritable — `podman volume rm pera-claude-config` and re-login), and
  `CLAUDE_CONFIG_DIR=/home/vscode/.claude` must be set (baked into the image) so
  `.claude.json` lands in the volume instead of the ephemeral container home.
- **Rebuilding the image after an agent run:** `run-agent` purges `.secrets/`, so re-stage
  the npm secret first (`cp /mnt/c/Users/<you>/.npmrc ~/pera-sandbox/.secrets/npmrc`) or
  re-run `new-sandbox.sh`.
- **Recommended IT follow-up:** a Nexus `raw` proxy of `nodejs.org/dist` would remove the
  node-tarball assembly workaround for everyone (Windows devs included).

## Files

| File | Role |
|---|---|
| `QUICKSTART.md` / `FAQ.md` | Newcomer path / common questions & troubleshooting |
| `new-sandbox.sh` | Assemble `~/pera-sandbox` inside the WSL distro (**primary path**) |
| `New-Sandbox.ps1` | Windows/Docker-Desktop variant of the same (kept for parity) |
| `.devcontainer/{devcontainer.json,Dockerfile}` | Container definition (CentOS Stream 9) |
| `container/init-firewall.sh` | `open` \| `lockdown [domains...]` (atomic swap, REJECT; smoke-tests first listed domain) |
| `container/prepare.sh` → `prepare-sandbox` | Warm caches via Nexus with network open |
| `container/run-agent.sh` → `run-agent` | Lockdown (Anthropic) → purge creds → start Claude |
| `container/run-copilot.sh` → `run-copilot` | Lockdown (Copilot hosts; `--login` adds github.com once) → purge creds → start Copilot CLI |
| `container/copilot-settings.json` | Seeded model default (claude-opus-4-8) for `~/.copilot` |
| `container/certs/` | (generated) corp root CAs staged by new-sandbox.sh |
| `overlay/CLAUDE.md` | Sandbox-adapted instructions the agent boots with |
| `overlay/.claude/settings.json` | bypassPermissions + deny rules + native sandbox |
