# Quick Start — PERA Agent Sandbox (Claude Code / GitHub Copilot CLI)

Spin up an isolated environment where a coding agent — **Claude Code** or **GitHub
Copilot CLI** (your choice at step 4; both drive Claude Opus 4.8) — works **autonomously**
on a disposable copy of the PERA codebase rather than your real working copies.
Guarded startup installs an address-based firewall and removes build credentials.
The required workflow is local commits followed by human review and push; it is not
a guarantee that every external write is technically impossible, particularly in
Copilot sessions using shared GitHub IP ranges.

> Full design, caveats, and file-by-file details: [README.md](README.md) · common
> questions and troubleshooting: [FAQ.md](FAQ.md)

## What you need (once)

| Prerequisite | Notes |
|---|---|
| `centos-9` WSL distro with podman | IT-standard setup; check with `wsl -d centos-9 -- podman --version` |
| `%USERPROFILE%\.m2\settings.xml` | Normal PERA Maven setup (Nexus mirror + credentials) |
| `%USERPROFILE%\.npmrc` | Normal PERA npm setup (Nexus registry + auth) |
| Working copies at `C:\work\pera\{prj,Documentation}` | The sandbox clones their **committed** state |
| Corp network / VPN | Needed for steps 1–3 only (Nexus access); the agent itself runs locked-down |
| Agent account | Claude subscription (step 4) **or** Copilot Enterprise license (step 4-alt) |

## Spin-up (4 commands + one login)

### 1. Assemble the sandbox — from Windows PowerShell

```powershell
wsl -d centos-9 -- bash /mnt/c/work/pera/claude-sandbox/new-sandbox.sh --force
```

Clones both repos into `~/pera-sandbox` (inside WSL), overlays the git-ignored AI assets
(`prj/.github`, `prj/.agents`), and stages the corp CAs + your Nexus credentials
(credentials are deleted again before the agent ever starts).
**`--force` deletes the old workspace, including unharvested work and caches.** Harvest
first. To install E1 into an existing sandbox, use the update section below instead.

### 2. Build the image — inside WSL (`wsl -d centos-9`)

```bash
cd ~/pera-sandbox
podman build --secret id=npmrc,src=.secrets/npmrc -t pera-sandbox -f .devcontainer/Dockerfile .
```

Build time depends on which layers are invalidated. Rebuild when the Dockerfile or
any image-installed file changes, including the firewall, launchers or policy hook.
The build uses the copies in `~/pera-sandbox`, not the working scaffold directly.
Agent CLIs
(Claude Code, Copilot) are refreshed to latest during `prepare-sandbox`, so new CLI
versions and newly released models do **not** require an image rebuild.

### 3. Warm the build caches — network open, one-time per sandbox

```bash
podman run -d --name pera-prepare --userns=keep-id --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/pera-sandbox:/workspace -v pera-claude-config:/home/vscode/.claude \
  -w /workspace pera-sandbox prepare-sandbox

podman logs -f pera-prepare     # wait for "BUILD SUCCESS" ... "Prepare complete."
```

~10–30 min. Downloads everything the locked-down agent will need: Maven deps, the pinned
node versions (assembled via Nexus), and npm packages.

**Choosing Maven profiles.** Default scope is the agency portal (`agencyWWW`). To warm
more portals, set `PREPARE_PROFILES` — the `-e` flag **must come before the image name**
(podman treats anything after `pera-sandbox` as arguments to the script, not options;
the script rejects that loudly). Full command:

```bash
podman run -d --name pera-prepare --userns=keep-id --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -e PREPARE_PROFILES="memberWWW" \
  -v ~/pera-sandbox:/workspace -v pera-claude-config:/home/vscode/.claude \
  -w /workspace pera-sandbox prepare-sandbox

podman logs -f pera-prepare     # wait for "BUILD SUCCESS" ... "Prepare complete."
```

Coverage rules (a profile only builds offline if its modules were warmed):

| Warmed profile | Also covers offline | Notes |
|---|---|---|
| `agencyWWW` | `agencyintra` | intra = internal WAR (`iagency`) — build with `-DBUILD=productionIntra`, no new downloads |
| `memberWWW` | `memberintra` (`imember`) | identical module set; member tests use Vitest |
| `vendorWWW` | — | `vendorintra` and `intra` add the **itools** module — warm those profiles explicitly |

A profile the prepare didn't warm fails fast and loudly offline (that's the firewall
working, not a bug) — re-run this step with the profile added.

### 4. Run the agent — option A: Claude Code

```bash
podman run -it --rm --name pera-agent --userns=keep-id --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/pera-sandbox:/workspace -v pera-claude-config:/home/vscode/.claude \
  -w /workspace pera-sandbox run-agent
```

**First-ever run:** complete the Claude login in the terminal and confirm the
bypass-permissions prompt. Auth persists in a podman volume — it's once per machine.

Then hand it work, e.g.:

> Convert EPD-xxx per the agency-jsp-to-angular skill

Headless variant (overnight runs):

```bash
... pera-sandbox run-agent -p "Convert EPD-xxx per the agency-jsp-to-angular skill" \
    --output-format stream-json --verbose
```

### 4-alt. Run the agent — option B: GitHub Copilot CLI

Steps 1–3 are identical and shared (one sandbox serves both agents). Copilot teammates
swap only step 4:

```bash
# one-time login: /login device flow, trust /workspace, exit. The CLI will note that
# no system vault is available and ask to store the token in plain text — answer YES
# (containers have no keyring; the token lives in the pera-copilot-config volume,
# same protection level as the Claude auth volume — see README §4b).
podman run -it --rm --userns=keep-id --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/pera-sandbox:/workspace -v pera-copilot-config:/home/vscode/.copilot \
  -w /workspace pera-sandbox run-copilot --login

# normal sessions
podman run -it --rm --userns=keep-id --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/pera-sandbox:/workspace -v pera-copilot-config:/home/vscode/.copilot \
  -w /workspace pera-sandbox run-copilot
```

Model is pre-set to claude-opus-4-8 (check `/model`). Headless variant:
`... run-copilot --autopilot -p "Convert EPD-xxx per the migration guide"`.

Copilot sessions allow GitHub's shared IP ranges, a wider surface than Claude's
Anthropic allowlist. Deny rules and the policy hook reduce accidental writes but have
known gaps; the firewall does not distinguish GitHub hosting from Copilot transport.
Read [README §4b](README.md#4b-github-copilot-cli-variant) before unattended use.

## Continue a task through review rounds

Assemble and warm once for the task. For each subsequent brief or external review,
keep the same workspace: **export committed documents -> preview -> apply -> run
the agent -> review/harvest**. Stop the agent and other users of that workspace
before importing. Commit or otherwise resolve its pending work; the importer does
not stash, discard or merge it automatically.

These commands run inside WSL from the trusted scaffold. The example uses
`Documentation`; use `--repository prj` and the corresponding source repo for briefs
committed in the codebase. Replace the example task and document paths.

```bash
SCAFFOLD=/mnt/c/work/pera/claude-sandbox
PACKETS="$HOME/sandbox-round-packets"
mkdir -p "$PACKETS"
chmod 700 "$PACKETS"

bash "$SCAFFOLD/sandbox-round.sh" export \
  --source /mnt/c/work/pera/Documentation \
  --repository Documentation --ref HEAD --task EPD-123 --round 02 \
  --path External-Team/EPD-123/review-findings.md \
  --output "$PACKETS/EPD-123-02.json"

bash "$SCAFFOLD/sandbox-round.sh" preview \
  --workspace "$HOME/pera-sandbox" --repository Documentation \
  --packet "$PACKETS/EPD-123-02.json" > "$PACKETS/EPD-123-02.preview.json" \
  && jq . "$PACKETS/EPD-123-02.preview.json"
```

Commit the external brief before export: `HEAD` selects committed contents, not the
source working tree. Additional `--path` arguments select more documents from that
same commit. Only those files move; external code changes and unselected references
do not come with them. Export refuses to overwrite an existing packet.

Stop if preview fails; do not apply. Inspect the saved preview, then run this separate
block. It extracts the full target `head` for you, rather than using a placeholder,
an abbreviated hash or the packet's external `sourceCommit`. Invalid/empty preview
output stops the block before apply:

```bash
(
    set -euo pipefail
    EXPECTED_HEAD=$(jq -ser '
      select(length == 1) | .[0] |
      select(.status == "ready" or .status == "already-imported") |
      .head | strings | select(test("^[0-9a-f]{40}([0-9a-f]{24})?$"))' \
      "$PACKETS/EPD-123-02.preview.json")
    bash "$SCAFFOLD/sandbox-round.sh" apply \
      --workspace "$HOME/pera-sandbox" --repository Documentation \
      --packet "$PACKETS/EPD-123-02.json" --expected-head "$EXPECTED_HEAD"
)
```

Apply creates a local commit containing
`Documentation/sandbox-rounds/EPD-123/02/README.md`, the provenance manifest and
`files/<original-path>` snapshots. It does not overwrite the originals or bring in
the source branch's commits. Imported bytes are preserved with directory-local Git
attributes; no global Git or agent settings are changed.

Restart with the usual guarded step-4 command and explicitly tell the agent to read
`/workspace/Documentation/sandbox-rounds/EPD-123/02/README.md` and follow that round's
brief. Resolve referenced files using the original paths in the manifest; do not
assume those references were also refreshed. For the next external review, use a
new round ID and packet. If both repos need inputs, import them separately: there
is no cross-repository atomic transaction.

No prepare is required merely for the imported documents. If the resulting task
needs new dependencies or an unwarmed profile, use a separate prepare container;
never reopen the agent container. A changed code baseline requires separate,
reviewed integration or assembly, not a brief import masquerading as a branch sync.

**Interrupted import:** keep the original packet and recovery state. The error
identifies a pending import; use `recover` with that packet, repository/workspace and
the current expected HEAD. Before the Git commit activates, recovery removes only
the matching round snapshot. After activation, it completes the matching prepared
index. Changed HEAD/index/snapshot contents require inspection rather than a forced
reset. Do not delete Git locks or private recovery files to bypass the guard.

The tool does not start an agent, enforce the internal reviewer loop or harvest
results. Those remain explicit steps; a completed import is not task acceptance.

## Update the firewall without resetting the workspace

For the E1 update, the sequence is **reviewed scaffold -> refreshed build context ->
rebuilt image -> new container**. A fresh container from the old image still has the
old firewall. E1 originated on `fix/e1-firewall-transitions` and is included in the
review-round feature branch; deployment is a
separate step tracked in [SECURITY-REVIEW.md](SECURITY-REVIEW.md#e1-remediation-on-a-separate-branch).

1. Exit the current agent normally. Confirm that the working scaffold contains the reviewed
   E1 changes. Review the assembled build context before building from it;
   agent-written files are not automatically trusted. Do not run `new-sandbox.sh --force`
   for this update.
2. Refresh the E1 build inputs from the trusted scaffold, inside WSL:

```bash
(
    set -e
    SCAFFOLD=/mnt/c/work/pera/claude-sandbox
    for path in "$HOME/pera-sandbox" "$HOME/pera-sandbox/.devcontainer" "$HOME/pera-sandbox/container"; do
        if [ ! -d "$path" ] || [ -L "$path" ]; then
            echo "Expected a real directory, not a symlink: $path" >&2
            exit 1
        fi
    done
    cd ~/pera-sandbox
    cp --remove-destination "$SCAFFOLD/.devcontainer/Dockerfile" .devcontainer/Dockerfile
    cp --remove-destination "$SCAFFOLD/container/init-firewall.sh" \
       "$SCAFFOLD/container/run-agent.sh" \
       "$SCAFFOLD/container/run-copilot.sh" container/
    cp --remove-destination "$SCAFFOLD/overlay/CLAUDE.md" CLAUDE.md
    cp --remove-destination "$SCAFFOLD/overlay/CLAUDE.md" AGENTS.md
)
```

3. If `.secrets/npmrc` was purged, recreate `.secrets` with mode 700 and copy your
   host npm credential file into it with mode 600. Do not print or commit its contents.
4. Re-run the `podman build` command in **Spin-up, step 2**. Use the refreshed build context; the
   Dockerfile installs the firewall and both launchers into the rebuilt image.
5. Start a new container with the command in **Spin-up, step 4 or 4-alt**. Existing containers
   are not updated in place. Do not manually transplant the script into a locked-down
   container or remove its `/run` state.

The workspace's repos, commits, warmed caches and auth volumes are preserved.
A firewall-only update does not require another prepare if the needed build inputs
and profiles remain warmed. Missing dependencies still require a separate prepare
container. Source-mounted regression results do not prove the rebuilt image was
deployed; record its image ID and startup outcome in the review record.

## Review & harvest — from Windows

You can be on **any** branch in your real repo — `git fetch` only creates a ref; your
checked-out branch matters only at the final merge step.

```powershell
# Inspect what the agent committed (and which branch it's on)
wsl -d centos-9 -- git -C /home/su/pera-sandbox/prj branch --show-current
wsl -d centos-9 -- git -C /home/su/pera-sandbox/prj log --oneline -15

# Fetch into a review branch. <your-working-branch> = the branch your working copy was
# on when the sandbox was assembled — the agent committed onto it (check with step 1
# above). Use +<your-working-branch>:... to force-update an existing review branch.
cd C:\work\pera\prj
git fetch \\wsl$\centos-9\home\su\pera-sandbox\prj <your-working-branch>:review/agent-work

# Review: three dots = only what the agent changed, even if your branch moved on
git log  --oneline <your-working-branch>..review/agent-work
git diff <your-working-branch>...review/agent-work

# Integrate — pick one:
git push origin review/agent-work:feature/EPD-xxx   # (recommended) Bitbucket PR + CI
# or: git checkout <your-working-branch>; git merge --no-ff review/agent-work; git push
# or: cherry-pick selected commits

git branch -D review/agent-work                     # cleanup
```

If the task touched docs, repeat against `...\pera-sandbox\Documentation` into
`C:\work\pera\Documentation` — two repos, two harvests.

## Reset for the next task

```powershell
wsl -d centos-9 -- bash /mnt/c/work/pera/claude-sandbox/new-sandbox.sh --force
```

Then re-run step 3 (prepare). The image and both agent logins (Claude + Copilot volumes)
survive. If the reset copied updated image-installed scaffold files, rebuild at step 2
before preparing or running. Any unharvested commits or uncommitted work are lost on
reset — review first.

## Things to know

- **Exiting the agent ≠ losing the sandbox.** The container and firewall vanish on exit
  (nothing keeps running); the workspace, commits, caches, and logins all persist. Re-run
  the step-4 command to start again — `run-agent --continue` (Claude) or
  `run-copilot --continue` (Copilot) resumes the previous conversation.
- **Treat sandbox contents as unreviewed input** until they pass review: inspect with
  `git diff`, don't run builds or scripts out of `~/pera-sandbox` on the host, don't open
  it in an IDE that auto-runs tasks. The sandbox repos have no git remotes — that's
  intentional.
- **Guarded startup is mandatory.** Use `run-agent` or `run-copilot`, not a bare CLI
  from an uninitialized shell. All configured domain names must resolve, the first
  non-CIDR endpoint must answer the positive probe, and `example.com` must fail the
  negative probe. CIDR-only lists skip the positive probe. This is not an exhaustive
  test of every permitted or forbidden destination.
- **Unit tests only.** The dev AS400/Oracle databases are unreachable *by design*.
  DB-dependent verification happens after review, on-network.
- **Never push from the sandbox.** Review and publish from the host; do not treat
  command-pattern restrictions as complete containment.
- **"Connection refused" inside a session is the firewall working**, not a bug. If the
  agent genuinely needs a new dependency, re-run step 3 (network open) to fetch it.
- **Lockdown is one-way.** Once a container has locked down it cannot be reopened: the
  agent has passwordless sudo for `init-firewall.sh` only, and the script refuses `open`
  and pins the initial allowlist and backend. Interrupted initialization also blocks
  reopening and another lockdown; start a fresh container using the same workspace,
  rather than deleting state or resetting the workspace. Step 3 (prepare) is a separate
  container, so the fetch-a-dependency path above still works.
- **Refresh errors are visible.** Every 15 minutes, addresses are staged and activated
  without flushing live rules. Failure before activation keeps the old restrictions;
  cleanup/probe failure after activation keeps the new ones. The agent may continue,
  but provider connectivity can degrade. See the [FAQ](FAQ.md#troubleshooting).
- The sandbox instructions (`CLAUDE.md` for Claude, `AGENTS.md` for Copilot — same
  content) are auto-loaded by the agent and already explain all of this — you don't need
  to repeat it in your prompts.
- **Login doesn't persist between runs?** Recreate the affected auth volume and log in
  once more: `podman volume rm -f pera-claude-config` (Claude) or
  `podman volume rm -f pera-copilot-config` (Copilot) — see README "Login not
  persisting?" for why.
