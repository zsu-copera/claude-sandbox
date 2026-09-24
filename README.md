# PERA Claude Code Sandbox

> **New here? Start with [QUICKSTART.md](QUICKSTART.md)** — 4 commands + one login.
> Questions? Check the [FAQ](FAQ.md) first.
> **Security status:** the current work list is
> [Open items in SECURITY-REVIEW.md](SECURITY-REVIEW.md#open-items-as-of-2026-09-23).
> To update an existing sandbox's image, follow the
> [existing-sandbox update procedure](QUICKSTART.md#update-the-image-without-resetting-the-workspace).

Runs a coding agent **autonomously** inside an isolated container that holds a disposable
copy of both repos. Two entrypoints share one image and one prepared workspace:
**`run-agent`** (Claude Code, `bypassPermissions`) and **`run-copilot`** (GitHub Copilot
CLI, `--allow-all-tools`). Isolation layers:

1. **Container** (rootless podman) — agent sees only the sandbox copy of the workspace,
   never your real working copies or the Windows filesystem.
2. **Firewall** — guarded startup restricts outbound HTTPS to the active provider's
   resolved IPv4 addresses and configured CIDRs. Copilot includes shared GitHub ranges;
   loopback and established/related traffic remain allowed. **The agent has no DNS**
   (finding E6): only root, meaning the firewall helper and its refresh loop, may query
   the container's configured resolvers. The agent resolves the allowlisted names from
   a root-owned `/etc/hosts` that each lockdown and refresh rewrites, and every other
   lookup fails immediately. The policy is intended
   to block dependency registries, Bitbucket and dev databases (AS400 / Oracle), not
   provide a hostname-level or complete no-exfiltration boundary. Blocked connections
   are REJECTed so tools fail fast.
   **Lockdown is one-way:** the agent holds passwordless sudo for `init-firewall.sh` alone,
   so the script refuses `open` once its container has locked down, and pins the allowlist
   the first lockdown committed to — a later `lockdown <other-domains>` is ignored.
   Firewall operations are serialized. Refresh stages a replacement allowlist without
   flushing live rules; an interrupted initial installation also prevents reopening.
3. **Agent-native guardrails** — Claude: a root-owned **managed policy**
   (`/etc/claude-code/managed-settings.json`) that requires the bubblewrap sandbox with
   no unsandboxed fallback, carries the deny rules, and locks out lower-scope permission
   rules, hooks and MCP servers (findings E2/E3). Copilot: deny-tool/deny-url flags,
   built-in GitHub MCP disabled, and a root-owned
   **policy hook** with known matching gaps. Both agents run
   without `CAP_NET_ADMIN`, so neither can touch the firewall
   directly, and sudo is scoped to `init-firewall.sh` rather than `ALL`.
4. **Guarded, checked startup** — root-owned `claude` / `copilot` wrappers refuse to
   start an agent before lockdown or while capabilities are held (E5); `run-agent`
   refuses when a previous session left the workspace or config volume a looser policy;
   and only the image-baked CLIs run (N5).

The required workflow is **local commits only**: the sandbox repos have no remotes,
common push commands are deny-ruled, and a human reviews and pushes from Windows.
These controls do not prove that every equivalent command or subprocess upload is
blocked. E1, E6 and N4 are deployed. E2/E3, E5 and N5 are implemented in source (Phase 3)
and count as deployed only after the rebuilt image passes the live checks in
[the Phase 3 spec](design/phase3-inner-sandbox-and-startup.md#6-verification-plan); N1 remains open.

**Review model in one sentence:** the bind-mounted `~/pera-sandbox` is the intended
review channel — a disposable copy whose contents are inert data until a human
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
[collect]  sandbox-task.sh   stopped, committed work -> private two-repo audit package
[review]   (host)            inspect collected work -> approve explicit host integration
```

For repeated review rounds, keep the same workspace and caches. The operator can
export selected committed brief files with `sandbox-round.sh`, preview the intake,
then explicitly apply them as a new local round commit. This does not clone/reset
the workspace, merge an outside branch or invoke prepare. The agent then reads
`sandbox-rounds/<task>/<round>/README.md` in the selected repository.
See [the round workflow](QUICKSTART.md#continue-a-task-through-review-rounds).

The preferred operator is now the **outside agent**, using task registration,
`send`, `status`, `launch-handoff` and `collect` rather than asking a person to manage packets and
expected HEADs. See [OPERATOR.md](OPERATOR.md). The low-level commands remain available
for diagnostics and recovery; the guarded agent launch is unchanged.

For agent-operated ticket work, the lead is the sole writer to shared host checkouts,
the operator helper prepares/collects, and fresh reviewers return findings outside
those checkouts. Only the designated human approves the exact apply plan; the
human-facing lead executes it. Follow OPERATOR's
[roles](OPERATOR.md#agent-roles-and-single-writer-ownership),
[two-pass review](OPERATOR.md#independent-review-in-two-passes) and
[pre-run evidence gate](OPERATOR.md#before-a-pilot-run-establish-execution-evidence).
These are operating rules, not newly enforced controller permissions.

Each handoff must account for required context and shared write-back documents.
The optional private `--handoff` contract carries declared documents forward and
binds committed-version observations and handling decisions to an approval plan.
Legacy tasks retain their existing workflow until explicitly opted in.
Snapshots still do not refresh canonical files or discover every stale reference.
For an applied v2 context, `launch-handoff` generates copy-ready snapshot/ownership
guidance from validated provenance. It refuses changed context or unsafe repository
state; it does not start an agent or authorize a run. See
[the checked launch handoff](OPERATOR.md#generate-a-checked-launch-handoff).
Collection likewise does not merge or publish work: host integration and any push
remain separate decisions. See the [harvest procedure](OPERATOR.md#harvest-and-integrate-reviewed-work).

## Usage

### 1. Assemble the sandbox (from Windows)

```powershell
wsl -d centos-9 -- bash /mnt/c/work/pera/claude-sandbox/new-sandbox.sh --force
```

Clones `prj` + `Documentation` from the local Windows working copies (committed state of the
current branch — no SSH keys, LF endings), overlays the git-ignored AI assets
(`prj/.github`, `prj/.agents`), drops in the sandbox `CLAUDE.md` + the canonical `.claude/settings.json`,
stages the corp CAs, and copies `~\.m2\settings.xml` + `~\.npmrc` into `.secrets/`
(purged before the agent runs). The Windows profile is resolved through WSL interop and
the commit identity comes from WSL git config, written per-repo; neither has a built-in
default (findings I1/I2, see [QUICKSTART step 1](QUICKSTART.md#1-assemble-the-sandbox--from-windows-powershell)
for the overrides). `--force` deletes and recreates the workspace and its caches. It only
deletes a directory inside `$HOME` that it assembled, and refuses while work would be lost
or a task is registered to it, unless given `--discard-unharvested` (finding V2; details
in [QUICKSTART step 1](QUICKSTART.md#1-assemble-the-sandbox--from-windows-powershell)).
Harvest first; do not use it merely to
update the firewall image.

### 2. Build the image (when the Dockerfile or image-installed files change)

```bash
# inside: wsl -d centos-9
cd ~/pera-sandbox
podman build --secret id=npmrc,src=.secrets/npmrc \
  -t pera-sandbox -f .devcontainer/Dockerfile .
```

(The secret feeds the global `@angular/cli` install through the Nexus npm proxy without
persisting credentials in an image layer.)

Assembly, image building, cache preparation and container startup are separate operations.
`new-sandbox.sh` copies scaffold files into `~/pera-sandbox`; it does not build an image.
The Dockerfile then bakes those copies into the image. Recreating a container from the
old image, or rebuilding from an outdated assembled directory, does not deploy a fix.
Existing running containers are never updated in place.

For E1, use the reviewed branch's Dockerfile and all three changed runtime scripts,
not just `init-firewall.sh`. Follow the
[existing-sandbox update procedure](QUICKSTART.md#update-the-image-without-resetting-the-workspace)
to retain a warmed workspace. A firewall-only update does not itself require another
prepare; changed build inputs or newly requested Maven profiles may.

### 3. Prepare (network open — one-time per sandbox, ~30–60 min)

Default warms `agencyWWW` (which also covers `agencyintra` — intra twins share modules
and need no extra downloads; `-DBUILD=productionIntra` selects them offline). To warm
more portals, set the env var — **before the image name**, or podman passes it as a
script argument instead (the script rejects that with a pointed error):

```bash
podman run -d --name pera-prepare --userns=keep-id --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -e PREPARE_PROFILES="agencyWWW,memberWWW" \
  -v ~/pera-sandbox:/workspace \
  -w /workspace pera-sandbox prepare-sandbox
# note: vendorintra / intra additionally pull in the itools module — warm those
# profiles explicitly if the task needs them
```

```bash
podman run -d --name pera-prepare --userns=keep-id \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/pera-sandbox:/workspace \
  -w /workspace pera-sandbox prepare-sandbox
# No agent login volume: prepare runs repository build scripts with the network open.
podman logs -f pera-prepare        # watch; exits when done
podman rm pera-prepare             # after it exits, so a re-run can reuse the name
```

The fixed container names assume the single default workspace. A second workspace
running at the same time needs its own name suffix on every container; see
[QUICKSTART step 3](QUICKSTART.md#3-warm-the-build-caches--network-open-one-time-per-sandbox).

### 4. Run the agent (locked down)

```bash
podman run -it --name pera-agent --rm --userns=keep-id \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/pera-sandbox:/workspace -v pera-claude-config:/home/vscode/.claude \
  -w /workspace pera-sandbox run-agent
# headless:  ... pera-sandbox run-agent -p "Convert EPD-xxx per the agency-jsp-to-angular skill" \
#                --output-format stream-json --verbose
```

`run-agent` first checks the inputs that persist between sessions (finding N5): the
workspace's `.claude/settings.json` must equal the canonical copy, no
`settings.local.json` or `.mcp.json` may exist, and the config volume's user settings,
server-managed settings cache and `.claude.json` may not add commands, hooks or MCP
servers. Any change refuses with exit 78 before the network is touched (recovery:
[QUICKSTART](QUICKSTART.md#startup-refusals)). It then locks the firewall (Anthropic-only;
self-tests that api.anthropic.com is reachable AND example.com is refused — refuses to
start otherwise), purges `.secrets/` and `~/.npmrc`, schedules allowlist IP refreshes
every 15 min, then starts `claude --dangerously-skip-permissions` through the guarded
wrapper. The mandatory policy comes from the image's managed settings, which outrank
everything the agent can write. First ever run: complete the login flow (auth persists
in the `pera-claude-config` volume) and confirm the bypass prompt.

**Firewall refresh and recovery:** the initial installation creates the default-deny
rules and pins both the domain list and the selected backend. Later refreshes keep those
rules in place: an ipset swap, or replacement of one jump to a staged per-IP chain,
activates the new addresses. All configured domains must resolve; incomplete DNS results
or staging failures leave the previous snapshot active. Right after activation, the pinned
`/etc/hosts` block is rewritten to the new addresses. Errors are visible on stderr.
An error after activation (for example, obsolete-rule cleanup or a provider probe) does
not undo the new restrictions. The agent can continue under the retained rules, but
provider connectivity may degrade until a refresh succeeds.

The root-owned `/run/claude-firewall` state and `/run/claude-lockdown-domains` belong to
one container, not the workspace. Interrupted initial installation or inconsistent state
refuses both reopening and another lockdown; start a fresh container using the same
workspace instead of deleting that state or flushing its firewall. Existing containers
created by older firewall scripts are not migrated in place.

**Session lifecycle:** exiting Claude removes the container (`--rm`) and its firewall with
it — nothing keeps running on the host (`podman ps` should be empty). The workspace, agent
commits, uncommitted working-tree changes, build caches, login, and session transcripts all
persist. Restart anytime with the same command; `run-agent --continue` resumes the previous
conversation (arguments pass through to `claude`). If you stop mid-task, prefer
`--continue` over a fresh session so the agent keeps its context.

Persistent CLI state is not an independently retained audit package. Establish
capture/retrieval for the actual session and preserve selected private execution
evidence before reset or cleanup; `collect` does not export transcripts. Do not
copy the entire auth/config volume or treat the committed handoff ledger as a
replacement for execution evidence.

### 4b. GitHub Copilot CLI variant

Same sandbox, same image, same prepare — different entrypoint and auth volume:

```bash
# ONE-TIME per developer: store a fine-grained PAT with the Copilot Requests account
# permission ONLY as a podman secret (QUICKSTART step 4-alt has the exact settings).
read -rsp 'Copilot fine-grained PAT: ' pat; printf '%s' "$pat" | podman secret create pera-copilot-token -; unset pat; echo

# Normal interactive session; replace TASK-1-R1 with the approved run label.
bash /mnt/c/work/pera/claude-sandbox/sandbox-record.sh \
  --label TASK-1-R1 --workspace "$HOME/pera-sandbox" -- \
  podman run -it --rm --name pera-copilot --userns=keep-id \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    --secret pera-copilot-token,type=env,target=COPILOT_GITHUB_TOKEN \
    -v "$HOME/pera-sandbox:/workspace" -v pera-copilot-config:/home/vscode/.copilot \
    -w /workspace pera-sandbox run-copilot
```

The host-only recorder retains private output/timing files, exact launch arguments,
exit outcomes and hashes without changing guarded startup. It requires a WSL
terminal; do not use this wrapper to claim headless capture is qualified.
For headless use, the underlying launcher accepts `--autopilot -p "task"`, but
establish that mode's evidence path separately.
Follow [the recording and retention contract](OPERATOR.md#record-an-interactive-launch-on-the-host):
keep storage outside every container mount, retain selected CLI events alongside
the terminal record, and demonstrate the actual CLI/setup before ticket use.
A zero launch exit is not proof that the agent's tests passed.

On first run only, `run-copilot` seeds `~/.copilot/settings.json` with a **default** of
`claude-opus-5.5` at high effort on the long-context tier (finding C3). It never
overwrites an existing file, so a volume created earlier keeps its model, and `/model`
changes it at any time; this is a starting point, not a pin. Confirm with `/model` on
first run: Enterprise policy must expose the model, and Copilot's IDs use dots
(`claude-opus-4.7`), unlike Anthropic's hyphenated API IDs. `--continue`/`--resume` work
like Claude's. Autopilot continuation limit defaults to 5 (`--max-autopilot-continues`).

**Copilot authenticates with a narrow PAT, not `/login` (finding N3).** The agent can
read whatever credential Copilot uses, and GitHub's address ranges are reachable (below).
The `/login` OAuth token carries the `repo` and `gist` scopes: a command that slipped past
the deny rules could push to any repository you can write to, or publish a gist. A
fine-grained PAT with only the **Copilot Requests** account permission cannot. It is
passed as `COPILOT_GITHUB_TOKEN` from a podman secret, which lives outside the workspace and the auth
volume. `run-copilot` refuses a missing or non-PAT token, the retired `--login` mode, and
any sign-in token left in `~/.copilot/config.json`. It cannot inspect a PAT's
permissions, so creating the PAT narrowly is each developer's step. The volume still
holds session state and history; treat it as private and mount it only into
`run-copilot` sessions. Rotate the PAT (`podman secret rm`/`create`) when it expires or
if a machine is compromised.

**Firewall difference & residual risk (read this):** Copilot sessions allowlist the
Copilot API hosts plus GitHub's published web/api IP ranges (fetched live from
`api.github.com/meta` at session start; static fallback in `run-copilot.sh`). The CIDRs
are unavoidable: GitHub's load balancer rotates IPs between DNS resolutions, so per-host
snapshots fail (`api.githubcopilot.com` measured 0/15 reachable without them). Because
GitHub serves `github.com` and the Copilot API **from the same address pool**, IP-level
filtering cannot separate them — `github.com` (where the real `Documentation` repo
lives) is *technically connectable in every Copilot session*. The barrier against
writes is therefore the credential: the only GitHub token present should be the
Copilot-Requests-only PAT above. Additional accident-prevention controls include
disabled built-in github-mcp-server, `git push`/`git remote`/`gh` deny rules,
fetch-tool `--deny-url` on GitHub hosts, the policy hook, no `gh` binary, no staged
Git/SSH credentials, no git remotes, and human review. A PAT created with wider
permissions than Copilot Requests restores the N3 exposure, and URL-tool denials do not
constrain subprocess HTTPS.

Weight those layers correctly. The `--deny-tool` rules match a command-identifier
**prefix**, so `git push` is denied but `git -C . push` and `env git push` are not
(verified 2026-09-09, v1.0.83); any global option between `git` and its subcommand
walks past them. The root-owned hook at
`/etc/github-copilot/policy.d/10-guardrails.json` catches some additional spellings
and cannot be disabled through `disableAllHooks`, but equivalent commands and script
indirection still evade its matching. Hook timeouts can fail open. Removing remotes
does not prevent an explicit destination either.

Claude's address allowlist is narrower. Its inner-sandbox findings (E2/E3, and E5/N5)
are implemented in source but not yet observed on a rebuilt image, which also matters
before unattended use. Stronger guarantees require a separately reviewed
network/credential design; adding command regexes is not sufficient. See
[E2-E6 and N1/N2](SECURITY-REVIEW.md#security-findings). GitHub branch protection and
PR requirements remain useful backstops, not protection for every possible write path.

### 5. Review from Windows

After the sandbox work is committed and its agent/container stopped, ask the outside
agent to inspect the registered task and `collect` it. The resulting package covers
both `prj` and `Documentation`, with explicit full/focused diff bases and candidate
heads. Open the collected diffs in the host editor; reviewing them does not require
reopening the agent workspace or running host Git against its configuration.

Follow [OPERATOR.md: harvest and integrate reviewed work](OPERATOR.md#harvest-and-integrate-reviewed-work)
to verify the package, import bundles into retained provenance refs and select the
work that actually belongs on each host branch. Do not force-update an old review
ref or blindly merge import bookkeeping into the application history.

The outside agent presents an integration summary for approval. Documentation may
need reconciliation with independent host amendments even when code can fast-forward.
Record incomplete integration explicitly; collection, integration and pushing are
separate decisions.

## Caveats & known limits

- **Unit tests only** in the sandbox. Integration tests need the dev AS400/Oracle —
  unreachable by design. DB-dependent verification happens after review, on-network.
- **Credentials:** the agent can read anything in the container, including `~/.claude` auth.
  `.secrets/` + `~/.npmrc` are purged before every run and deny rules block reading them,
  but keep unrelated secrets out of the sandbox. Dev DB creds committed in test code are
  inert behind the firewall.
- **Agent DNS is closed (E6).** Port 53 is refused for every non-root user, including
  to loopback resolvers, and root may reach only the IPv4 nameservers in
  `/etc/resolv.conf`. Allowlisted names come from the pinned `/etc/hosts` block. An
  unlisted name such as `github.com` does not resolve, and the lookup fails in
  milliseconds. IPv6 is default-deny, with only loopback allowed (finding N4), whenever
  `ip6tables` works. Lockdown refuses if a non-loopback IPv6 interface exists but cannot
  be filtered, and a refresh refuses if the IPv6 policy has been changed.
  Data can still be encoded in HTTPS to the allowlisted provider endpoints.
- **Maven "connection refused" at runtime** = the firewall doing its job. Re-run
  `prepare-sandbox` (network open) if a genuinely new dependency is needed. You cannot
  reopen a container that has locked down (see next item) — prepare is a separate
  container, so that path still works.
- **Lockdown is one-way, by design.** `init-firewall.sh open` exits 3 once the
  root-owned state or `CLAUDE_LOCKDOWN`/`CLAUDE_HTTPS` chains indicate initialization.
  Incomplete initialization also prevents reopening. The first installed lockdown pins
  its domain list in `/run/claude-lockdown-domains` (root-owned, unreadable to the agent);
  later lockdowns reuse it and ignore their arguments. The 15-min refresh loop is
  unaffected — each container's domain set is fixed before its first
  lockdown. To get an open network again, start a fresh container.
- **`/tmp` is writable inside the native sandbox** (`sandbox.filesystem.allowWrite` in the
  managed policy). Required, not incidental: Java ignores `$TMPDIR`, so `java.io.tmpdir`
  stays `/tmp` and the WAR assembly fails on a read-only `/tmp`.
- **Why the startup checks exist (N5).** Managed settings win for single values, but
  list settings merge from every scope, and the CLI has no managed-only lock for
  `sandbox.excludedCommands` or `allowWrite`. A project `allowWrite` was observed to
  widen sandboxed writes past the managed policy ([spec §10](design/phase3-inner-sandbox-and-startup.md#10-live-observations-on-a-test-image-2026-09-24)).
  User settings may also set command-running keys such as `statusLine` or `apiKeyHelper`.
  The workspace and config volume are agent-writable and persist, so `run-agent`
  checks them, and a managed `Edit` deny keeps the agent's file tools off both stores.
- **CLI updates are image rebuilds.** The launchers run only the baked CLIs: a copy on
  the workspace would be agent-writable and carry into the next session.
- **Sudo is scoped to `init-firewall.sh`.** Not `NOPASSWD:ALL` — that would have made the
  agent effectively root, able to flush the firewall or read past the settings deny rules.
  Any new call site must use the absolute path, since `Defaults secure_path` excludes
  `/usr/local/bin`.
- **ipset fallback:** initial lockdown selects per-IP rules if ipset cannot be created
  in the user namespace. That selection is fixed for the container; a refresh failure
  never triggers a live backend migration.
- **Login not persisting?** Two past causes, both fixed in the current image: the
  `pera-claude-config` volume must be created by a `--userns=keep-id` container (one made
  without it is unwritable — `podman volume rm pera-claude-config` and re-login), and
  `CLAUDE_CONFIG_DIR=/home/vscode/.claude` must be set (baked into the image) so
  `.claude.json` lands in the volume instead of the ephemeral container home.
- **Rebuilding the image after an agent run:** both launchers purge `.secrets/`.
  Recreate that directory with mode 700 and copy the host npm credential file to
  `.secrets/npmrc` with mode 600 before building. Do not reset the workspace simply
  to re-stage a secret; the update procedure above preserves existing work.
- **Recommended IT follow-up:** a Nexus `raw` proxy of `nodejs.org/dist` would remove the
  node-tarball assembly workaround for everyone (Windows devs included).

## Files

| File | Role |
|---|---|
| `QUICKSTART.md` / `FAQ.md` | Newcomer path / common questions & troubleshooting |
| `new-sandbox.sh` | Assemble `~/pera-sandbox` inside the WSL distro (**primary path**) |
| `.devcontainer/{devcontainer.json,Dockerfile}` | Container definition (CentOS Stream 9) |
| `container/init-firewall.sh` | Serialized `open` \| `lockdown [domains...]`; durable one-way state, staged refresh, REJECT |
| `container/prepare.sh` → `prepare-sandbox` | Warm caches via Nexus with network open |
| `container/run-agent.sh` → `run-agent` | Check persistent inputs (N5) → lockdown (Anthropic) → purge creds → start Claude |
| `container/claude-managed-settings.json` → `/etc/claude-code/managed-settings.json` | Claude's mandatory policy: sandbox required, deny rules, lower scopes locked (E2/E3); root-owned, empty drop-in directory |
| `container/claude-project-settings.json` | Canonical `/workspace/.claude/settings.json`: bypass mode plus a repeat of the managed deny rules and sandbox lists, inert under the managed policy; assembly copies it, the image bakes it for `run-agent` to compare |
| `container/agent-cli-guard.sh` → `/usr/local/lib/pera-sandbox/bin/{claude,copilot}` | Guarded wrappers first on `PATH`: refuse before lockdown or with capabilities held, then exec the baked CLI (E5) |
| `container/run-copilot.sh` → `run-copilot` | Refuse a non-PAT/missing token or stored sign-in token (N3) → lockdown (Copilot hosts) → purge creds → start Copilot CLI |
| `container/copilot-settings.json` | First-run default model settings (claude-opus-5.5, high effort, long context) for `~/.copilot` |
| `container/copilot-policy.json` → `/etc/github-copilot/policy.d/10-guardrails.json` | Machine-policy `preToolUse` hook registration (root-owned; survives `disableAllHooks`) |
| `container/guard-shell-command.js` | Selected command-pattern vetoes; known matching gaps, not a complete no-push boundary |
| `container/certs/` | (generated) corp root CAs staged by new-sandbox.sh |
| `overlay/CLAUDE.md` | Sandbox-adapted instructions the agent boots with |
| `sandbox-record.sh` | Optional WSL-host PTY recorder around an explicitly approved guarded launch; private output/timing, outcomes and hashes |
| `verify-recording.sh` | Disposable local PTY checks for recording, signals, exit propagation and retention; no agent/container |
| `verify-scaffold.sh` | Host-side static assertions |
| `verify-firewall.sh`, `tests/firewall/` | E1 regressions in disposable containers, without workspace or credential mounts |
| `SECURITY-REVIEW.md` | Original audit reconciliation, E1 commit/evidence record and deployment status |
| `VERIFY-ASSERTIONS.md` | Implemented checks, planned lifecycle assertions and coverage limits |
| `sandbox-round.sh`, `tools/rounds/rounds.js` | Operator-only export/preview/apply/recover for append-only committed brief snapshots |
| `verify-assembly.sh` | Disposable `new-sandbox.sh` assembly and reset-safety regressions (V2, D5, I1), in a throwaway tree under `$HOME` |
| `verify-startup.sh`, `tests/startup/` | Disposable `--network=none` regressions for `run-agent`'s input checks and the guarded wrappers (N5, E5), with a recorder in place of the real CLIs; `--baked` checks a rebuilt image's copies |
| `design/` | Written specs for owner review, e.g. the Phase 3 inner-sandbox and startup spec |
| `verify-rounds.sh`, `tests/rounds/` | Disposable round-import and recovery regressions |
| `sandbox-task.sh`, `tools/tasks/` | Registered task plans, checked launch-handoff text, status and audit collection; no automatic agent launch |
| `OPERATOR.md` | Outside-agent procedure, approval rules and audit boundaries |
| `verify-tasks.sh`, `tests/tasks/` | Disposable task-controller and read-only collection coverage |

## Review-round import boundary

The importer is an operator tool run from the trusted scaffold in WSL. Export reads
only explicitly selected committed `.md`/`.txt` blobs; it ignores uncommitted source
edits. Apply adds a versioned snapshot under `sandbox-rounds/<task>/<round>/` and
commits it on the existing sandbox branch, preserving original files and earlier
agent commits. The source commit and blob/content hashes are recorded, but outside
Git ancestry is not imported. Packet checksums establish integrity, not authorship
or trustworthiness of the instructions.

Export and import use separate network-disabled, capability-free maintenance
containers. The import container never mounts the external working copy, auth
volumes, workspace-root build credentials or Maven cache. Git runs with private
control metadata rather than the repository's executable hooks/filter configuration.
Only the selected target repo and its private recovery state are writable.

Keep packets and recovery state outside the agent workspace. The wrapper serializes
operations and refuses known active containers with overlapping workspace mounts;
also stop manual edits and Git operations. This is a cooperative workflow guard,
not protection from another host process deliberately ignoring locks.

The initial tool supports ordinary clones with `.git` directories, not linked
worktrees, submodules or alternate object stores. It refuses dirty/non-ignored
untracked work, ongoing Git operations, unsafe/symlinked paths, stale expected HEADs
and conflicting round IDs. Identical repeated packets do not create another commit.
Materialized Git LFS assets are recognized as unchanged only when their regular-file
mode, size and SHA-256 match a canonical staged LFS v1 pointer under `filter=lfs`.
This comparison does not run LFS filters or download anything. Modified payloads,
staged changes and unsupported pointer forms still block import; refusals name the
affected paths without printing their contents.
Apply also requires an existing per-repository Git identity; it does not invent an
author or borrow the source commit's identity. Snapshots are Git-versioned task data,
not root-owned policy: the importer detects changed replay content, while the agent
is instructed to leave input snapshots unchanged.
It does not replace canonical instructions, change model settings, launch reviewers,
modify dependency manifests, restore deleted caches or automate result harvesting.
