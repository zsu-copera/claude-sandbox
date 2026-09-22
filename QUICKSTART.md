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

**Before either agent's first ticket run:** follow
[the execution-evidence gate](OPERATOR.md#before-a-pilot-run-establish-execution-evidence).
Identify the actual CLI/session, demonstrate capture and retrieval with a harmless
separately approved probe, and assign human review/retention responsibility. The
basic launcher does not export transcripts. The recorded Copilot recipe below
adds host terminal capture, not a complete CLI tool transcript. Hold autonomous
ticket execution if the required evidence path has not been established.

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

# normal interactive sessions; replace the label with the approved run's label
bash /mnt/c/work/pera/claude-sandbox/sandbox-record.sh \
  --label TASK-1-R1 --workspace "$HOME/pera-sandbox" -- \
  podman run -it --rm --name pera-copilot --userns=keep-id \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    -v "$HOME/pera-sandbox:/workspace" -v pera-copilot-config:/home/vscode/.copilot \
    -w /workspace pera-sandbox run-copilot
```

Run that block in an interactive WSL terminal, not through a piped/non-interactive
shell. The recorder creates a fresh private run directory under
`${XDG_STATE_HOME:-$HOME/.local/state}/pera-sandbox-recordings`, prints its path,
and retains terminal output, timing, launch/outcome metadata and hashes. Keep
that directory outside every container mount and retain the selected CLI session
events separately. See [the recorder contract](OPERATOR.md#record-an-interactive-launch-on-the-host)
for incomplete captures, sensitive output and the actual-CLI demonstration still
needed before relying on this layer. No image rebuild or prepare is needed.

Model is pre-set to claude-opus-4-8 (check `/model`). Headless variant:
`... run-copilot --autopilot -p "Convert EPD-xxx per the migration guide"`.
That is an underlying-launcher option, not the interactive recorder recipe;
headless evidence needs its own qualification.

Copilot sessions allow GitHub's shared IP ranges, a wider surface than Claude's
Anthropic allowlist. Deny rules and the policy hook reduce accidental writes but have
known gaps; the firewall does not distinguish GitHub hosting from Copilot transport.
Read [README §4b](README.md#4b-github-copilot-cli-variant) before unattended use.

## Continue a task through review rounds

**Preferred: let the outside agent operate the handoff.** Point it to
`C:\work\pera\claude-sandbox\OPERATOR.md`, then ask it to register the existing task,
prepare the next committed brief for sending, or collect completed work for audit.
It will remember the workspace/source mappings and present one plan for approval.
You do not need to copy expected HEADs, manage packet filenames or run a new prepare.

Use [separate roles and one host-checkout writer](OPERATOR.md#agent-roles-and-single-writer-ownership):
the lead owns briefs and commits, an operator helper handles preparation/status/
collection, and a fresh reviewer returns findings outside the checkout. For this
setup the operator returns the exact plan to the lead; the lead executes apply only
after the designated human approves it directly. An agent cannot approve itself
or another agent. Agent session separation is not a technical permission boundary.

The task-aware commands are `register`, `send`, `status`, `launch-handoff` and `collect` in
`sandbox-task.sh`. Initial assembly/prepare and the existing guarded agent launch
remain separate. Attaching in-progress work requires an explicit audit baseline;
registration must not hide existing changes by assuming the latest HEAD is the start.

Before each send, the outside agent inventories required references and the documents
the sandbox will write back, not just the new brief. For persistent declared-context
tracking, explicitly opt in with a private `--handoff` file; see
[the schema and compatibility boundary](OPERATOR.md#context-aware-handoffs-explicit-opt-in).
Its brief selection changes per handoff while document declarations carry forward.
Legacy tasks retain the fixed registered `briefs` list and whole-selection `--brief`
override. Do not mix the two modes or edit a private registration to switch them.
Include needed host amendments to shared documents, and explicitly decide how the
agent should reconcile them with its canonical copies. Imports do not synchronize
those copies. See [context and ownership](OPERATOR.md#select-context-and-assign-document-ownership)
and [text-carried scripts](OPERATOR.md#carry-a-script-as-a-document).

A context-aware `needs-decision` result has no applicable plan ID: resolve the
reported shared-document handling before preparing again. Context-only changes
still require approval but create no import round. Opt-in upgrades private metadata
to version 2, not the registration configuration or warmed workspace; do not switch
an opted-in task back to older controller code or restore an obsolete record.
Context tracking does not start an agent, synchronize canonical documents, or
replace the outside audit.

After an approved v2 handoff is applied, ask the outside agent to run
`sandbox-task.sh launch-handoff TASK`. Its JSON `text` field supplies the selected
briefs, exact snapshot paths, canonical write-back ownership and approved handling.
See [the command's freshness and approval contract](OPERATOR.md#generate-a-checked-launch-handoff).
It refuses changed context even when repository status is `ready`; resolve that
through reviewed handling, not by resetting the workspace. Generating the text does
not authorize or perform the separately guarded, recorded agent launch.

Allow minutes for controller operations, not a short interactive-command timeout:
EEP-24's first send preview exceeded a 120-second client timeout. This is an observed
duration, not a deadline or a promise about future runs. Keep the same invocation
attached in a tracked long-running session and retrieve its eventual result rather
than starting a duplicate command. If the caller was interrupted and the outcome is
unknown, inspect controller/container status before retrying; do not kill it or
remove locks merely because the client timed out.

Agent stop and relaunch remain deliberate human/operator transitions. Finish and
commit the sandbox work, stop the agent/container, let the outside agent inspect
and collect, preserve the run's private execution evidence, then perform the
[two-pass review](OPERATOR.md#independent-review-in-two-passes) and approve any host
integration separately. The next send
gets its own plan approval; its success does not start another agent. The outside
agent supplies the [snapshot path map](OPERATOR.md#bridge-cited-paths-in-the-launch-handoff)
for the normal guarded relaunch. See [harvest and integration](OPERATOR.md#harvest-and-integrate-reviewed-work)
for bundle provenance, selection and conflict handling.

The operator returns receipt-backed ledger entries; the lead commits the sanitized
[handoff ledger](OPERATOR.md#handoff-ledger-and-evidence-references) in the host task
folder. The ledger records actual human approval references and missing evidence;
it never substitutes for private session/tool output or a completed human review.

The following low-level sequence is retained for manual diagnosis and recovery:

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
assume those references were also refreshed. For selected inputs, explicitly map
the cited original paths to their `files/<original-path>` snapshots; canonical
write-back targets are separate from those immutable inputs. For the next external
review, use a new round ID and packet. If both repos need inputs, import them separately: there
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

Ask the outside agent to inspect and collect the registered task after the sandbox
agent has committed and stopped. These are the task-aware operations, with the
actual registered ID substituted for `TASK-1`:

```powershell
wsl -d centos-9 -- bash /mnt/c/work/pera/claude-sandbox/sandbox-task.sh status TASK-1
wsl -d centos-9 -- bash /mnt/c/work/pera/claude-sandbox/sandbox-task.sh collect TASK-1
```

Diagnose a non-ready status before collecting; do not bypass the guards with direct
host Git commands on the agent repository. Running, dirty, busy or recovery-required
workspaces need resolution first. Committed input-integrity problems can still be
collected for audit under the runbook's existing rules; they must not be reset away.
Collection publishes one private package containing both repositories, not an
automatic merge into either host checkout.

The outside agent follows [the harvest runbook](OPERATOR.md#harvest-and-integrate-reviewed-work):
verify the package and bundle prerequisites, fetch into new retained provenance refs,
review full and focused changes, and propose the exact host integration for approval.
No force-updating refs, selecting an audit base from the current host branch, or
assuming import/log-sync commits belong on the host.

Host integration is separate per repository. Preserve any conflicting or withheld
document in the original package and record it as outstanding; a completed collection
does not mean every change was accepted, and the next collection may not repeat it.
Any push requires separate authorization.

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
