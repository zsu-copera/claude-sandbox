# FAQ — PERA Agent Sandbox

Quick answers, grouped by theme. Procedures live in [QUICKSTART.md](QUICKSTART.md); full
design and rationale in [README.md](README.md).

## Getting started

**Do I need Docker?**
No — the setup runs on rootless podman inside the `centos-9` WSL distro (the IT-standard
setup). No Docker Desktop, no podman machine. Check yours with
`wsl -d centos-9 -- podman --version`.

**Do I need to be on the VPN / corp network?**
Only for assembly, image build, and prepare (steps 1–3 — they pull from the internal
Nexus). Agent sessions run behind a locked-down firewall and only need the agent's own
API endpoints reachable.

**Which agent should I use — Claude Code or Copilot CLI?**
Whichever you're licensed for; both drive Claude Opus (5.5 as of 2026-09-29) against the same sandbox and
the same instructions. Claude sessions have the tighter network posture (Anthropic-only),
so prefer `run-agent` for unattended overnight runs. See README §4b.

**Why is the first prepare so slow? Can I skip it?**
It downloads every Maven/npm/node artifact the agent will need, because agent sessions
run (nearly) offline. It's one-time per sandbox reset (~10–30 min). Skip it only for
tasks that never build or test — see the next question.

**What is warming actually for? Do I always need it?**
It enables the agent's offline verify loop: compiling, building, and unit-testing behind
the firewall. That includes PERA's own inter-module artifacts (`agency` won't compile
without `shared`/`common` installed into `.m2`), and it doubles as a green baseline — if
prepare succeeded, a later build failure was caused by the agent's changes, not the
environment. For tasks with no build/test at all (doc-only work in `Documentation/`,
code review, analysis, planning), an un-warmed sandbox works fine: assemble → run the
agent. Conversion work always needs warming — the pipeline mandates unit tests.

**Can I use VS Code instead of the terminal?**
The workflow is terminal-first, but the Dev Containers extension works: set
`dev.containers.dockerPath` to `podman` and open `\\wsl$\centos-9\home\<you>\pera-sandbox`.
The container started by VS Code does NOT automatically perform guarded startup.
Launch `run-agent` or `run-copilot` in its terminal, using the appropriate auth volume,
before giving an agent work. These wrappers select the domain list, enforce startup
probes, purge build credentials and drop capabilities. Manually calling the firewall
alone does not perform the rest of that sequence. To switch providers, use a fresh
container: the first domain list is pinned.

## Running & sessions

**I exited the agent — is the sandbox gone?**
No. The container and its firewall vanish (nothing keeps running on your machine), but
the workspace, commits, uncommitted edits, build caches, and logins all persist. Re-run
the same command to start again; `run-agent --continue` / `run-copilot --continue`
resumes the previous conversation.

**How do I start over with a fresh copy of the code?**
Harvest anything you want to keep first, then `new-sandbox.sh --force` + re-run prepare.
The image and both agent logins survive; the workspace (including its `.m2` cache) does
not. `--force` refuses while it finds unharvested or uncommitted work, or a task
registered to the workspace, and lists them; `--discard-unharvested` overrides that. This also picks up whatever branch your Windows working
copies currently have checked out.

**Does a fresh container automatically get the updated firewall?**
Only if it uses an image rebuilt from the updated scaffold files. Assembly copies the
build inputs into `~/pera-sandbox`; building bakes those copies into the image;
starting a container uses that image. Reusing an old image or stale build context keeps
the old firewall. Running containers are not updated in place. Follow the
[E1 update procedure](QUICKSTART.md#update-the-image-without-resetting-the-workspace);
it preserves the workspace and does not require a reset or a new prepare solely for E1.

**Can I switch between Claude and Copilot on the same sandbox?**
Yes, freely — same workspace, same files, same instructions; swap only the entrypoint
(`run-agent` / `run-copilot`) and the auth volume (`pera-claude-config` /
`pera-copilot-config`). One at a time though: they share the working tree and would
trample each other's edits. Conversation history does not cross agents.

**Can I run two agents (or two sessions) at once?**
Not on one sandbox — same working tree, same git index. If you need parallel tasks,
create a second sandbox directory (`SANDBOX_ROOT=~/pera-sandbox-2 new-sandbox.sh`) and
prepare it separately.

**The agent needs a dependency that isn't installed. What now?**
That's the firewall doing its job. Exit the session, re-run the prepare step (network
open) — with an extended `PREPARE_PROFILES` if it's a whole new module — then restart
the agent. You *cannot* open the firewall for a live agent session: once a container has
locked down, `init-firewall.sh open` refuses (exit 3), and re-running `lockdown` with a
different domain list is ignored in favour of the list that container committed to. Both
are deliberate — the agent has passwordless sudo for that one script, so an unguarded
`open` (or a `lockdown attacker.example.com`) would have been its own escape hatch.
Prepare is a *separate* container, so it is unaffected.

**I reset the sandbox for a new task/branch — do I need to re-run prepare?**
Yes, if the task builds or tests anything: `--force` wipes the workspace *including* all
warmed caches (`.m2`, node installs, `node_modules`), so a fresh copy is a cold copy —
regardless of which branch it's on. Skip prepare only for prose/analysis-only tasks.
For another brief or review round of the same task, do not reset or switch branches.
Use the [round import workflow](QUICKSTART.md#continue-a-task-through-review-rounds)
with the existing warmed workspace. Moving to a different code baseline is a separate
integration decision, not an automatic side effect of importing instructions.

**How do I bring in external review findings without losing the agent's work?**
For the normal workflow, ask the outside agent to use `OPERATOR.md` and the registered
task's `send` command. It prepares one plan and explains the inputs/destinations.
With a delegated operator, the human-facing ticket lead receives your approval
and executes that exact plan; the operator helper does not approve or apply it.

Commit the selected brief documents outside the sandbox, export a packet, preview it,
then apply it with the previewed target HEAD while the agent is stopped.
`sandbox-round.sh` adds a new round directory and local commit; it does not merge the
external branch or overwrite canonical files. Reuse the workspace and normal guarded
launcher. No dependency download is needed simply to read another brief.

**Why did the import refuse a dirty repository or changed HEAD?**
The tool will not hide or discard work to make an import succeed. Finish/commit or
resolve the existing work, then preview again. A stale preview is not authorization
to overwrite a newer state. Ignored build assets may remain, but non-ignored untracked
files also need attention. Do not use a reset to bypass this check.

**"Expected HEAD must be a full lowercase Git object ID."**
Use the full `head` from a successful preview of the target repository, not a source
commit, shortened hash or `PASTE_FULL_HEAD...` placeholder. The current QUICKSTART
saves preview JSON and extracts that field with `jq`; a failed preview blocks apply.

**Documentation's materialized LFS files appear modified without actual edits.**
The importer deliberately does not execute repository filters. It now recognizes
canonical LFS v1 assets as clean by comparing their size and SHA-256 with the staged
pointer. Do not commit hydrated PDF/PowerPoint contents over their pointers or reset
files merely to silence this symptom. If the updated importer still refuses them,
inspect the reported paths: mismatched bytes, modes, staged changes or unsupported
pointer forms are not waived.

**Can I revise an already imported round?**
Use a new round ID. An identical packet can be replayed without another commit,
but different content or changes inside the existing snapshot are a conflict.
Round directories preserve what the agent was actually given, not a moving pointer
to the external branch. Relative links to unselected documents may need the original
repository paths recorded in the manifest.

**Does the importer need access to Nexus, agent credentials or the source working copy?**
The exporter reads the selected source repo read-only. The separate importer receives
only the packet, selected target repo, trusted helper and private recovery state.
Both run with networking disabled and no elevated capabilities. The source working
copy is never mounted into the importer, and repository hooks/filters are not executed.

**Does task registration clone or warm another workspace?**
No. It records an existing workspace, source branches, image and explicit audit bases.
It does not switch branches or prepare dependencies. The outside agent should confirm
those facts once, then use the task ID for subsequent handoffs.

**The new brief arrived, but its referenced file is missing or old. Why?**
Only selected committed documents move, and they arrive under
`sandbox-rounds/<task>/<round>/files/<original-path>`. The importer does not refresh
canonical copies, follow every link, or include files from other source branches.
Ask the outside agent to inventory required context and provide an explicit
[snapshot path map](OPERATOR.md#bridge-cited-paths-in-the-launch-handoff).
Stop for missing required context rather than assuming a relative link is usable.

**Does a ready status mean the README and implementation log match the host?**
No. Retained-input integrity and canonical-document freshness are different.
Legacy `status`/`send` do not detect drift in unselected shared documents.
Opted-in tasks report committed drift for their declared set in `context`; read
that report as well as workspace health. Undeclared dependencies are still unknown.
If the sandbox will update them, include needed host snapshots and explicitly
decide how to preserve both sides' changes, or leave those documents host-owned.
Importing a current snapshot is not automatic synchronization of the editable file.
See [context and ownership](OPERATOR.md#select-context-and-assign-document-ownership).

**Can a measurement script accompany a brief?**
Not as an `.mjs` attachment under the current document-only contract. A reviewed,
verbatim fenced block in committed Markdown can carry a script with its source
identity, SHA-256 and precise scratch-file extraction instructions. Compare the
extracted bytes before separately authorized execution; provenance is not permission.
Binary attachment transport remains unsupported. See
[text-carried scripts](OPERATOR.md#carry-a-script-as-a-document).

**Must I re-register whenever the next brief has a different filename?**
No. Legacy tasks use the complete explicit `--brief REPO:PATH` selection, which
replaces the registration's starting defaults for that invocation. Context-aware
tasks use `--handoff`: its briefs change per round while declarations carry forward
until explicitly retired. Include supporting context and write-back documents.
Do not edit private task state or create another task just to change this selection.

**Does `--handoff` merge host amendments into the sandbox README?**
No. It records declarations, observes committed versions and binds explicit handling
decisions to the approval plan. It still imports append-only snapshots, not canonical
replacements. Reconciliation is an instruction for the agent or host author, not an
automatic edit. See [context-aware handoffs](OPERATOR.md#context-aware-handoffs-explicit-opt-in).

**Why did a send ask for a decision without giving a plan ID?**
An active shared document differs or is absent canonically, and needs an applicable
per-handoff decision. A `needs-decision` report is not an approved or partially
applied handoff. Amend the private input and prepare again; missing/unsupported
required source content cannot be waived by a decision.

**Why is there a new collection even though no Git HEAD changed?**
A context-only approval changes the declarations/decisions that must accompany the
audit. The collection identity includes that context revision. No import directory
or artificial work-baseline advancement is needed just to preserve this provenance.

**Can the outside agent apply a different brief after a plan was approved?**
No. The plan binds the selected committed inputs, packets and target state. A change
requires a matching new plan/approval rather than silently refreshing captured values.
Partial progress across the two repos stays visible; it does not justify a reset.

**Why does an unchanged brief or completed plan now report an integrity problem?**
Stored delivery receipts are not proof that the inputs remain present. The controller
checks the current retained snapshots and checkpoints against the approved packets.
Missing or modified inputs block both a new no-op send and a completed-plan replay.
Ordinary later committed work is allowed, but it must preserve the recorded execution
ancestry and input history. Do not reset or recreate evidence to clear the warning;
collect the committed changes for audit where the normal collection requirements hold.

**Can I return to an earlier handoff after preparing a replacement?**
Yes: prepare the original selection again, rather than applying its superseded ID
directly. If the captured facts still match, a validated receipt-free plan can reuse
its original ID and become pending again. It still needs approval before apply.
Completed, applying or partially applied plans are not reopened, and import receipts
are never discarded. This prevents the A-to-B-to-A reselection failure; it does not
automatically repair a task record already made inconsistent by older code.

**What does collection do to my host repositories?**
Nothing automatically. It creates a local, unreviewed audit package from the stopped
sandbox's committed work. It does not check out, merge or push that work into the
external source repos. Dirty work or unsupported LFS artifacts must be addressed
explicitly rather than silently omitted.

**Should the reviewer write findings directly into the shared Documentation checkout?**
No. The ticket lead is the sole host-checkout/Git writer; even uncommitted reviewer
edits can collide. Reviewers return findings or use private artifacts outside the
checkout. The lead incorporates and commits the record. Use
[two-pass review](OPERATOR.md#independent-review-in-two-passes) to separate the initial
technical assessment from the later narrative/scope check without stripping required
domain facts or mandatory instructions.

**Is a reviewer outside the repository automatically independent?**
No. Start outside narrative-bearing workspace roots and inspect the context actually
loaded; parent instructions, attachments or inherited context can still expose the
campaign's case. Preserve mandatory safety instructions and disclose exposure.
The [review contract](OPERATOR.md#independent-review-in-two-passes) also requires
source-bound criteria and traceable execution evidence, not just the lead's summary.

**Does a reporting mistake always need another sandbox round?**
No. An evidence-backed, append-only erratum can correct a reporting-only mistake
without rewriting the original account. It does not make an unmet criterion pass,
resolve unknown behavior or authorize acceptance. See
[reporting corrections](OPERATOR.md#correct-reporting-without-rewriting-the-record).

**Can an operator agent authorize its own apply?**
No. Only the designated human's approval of the exact plan authorizes execution.
The default delegated operator prepares/collects; the human-facing lead executes
apply after receiving that approval directly. A dedicated operator session may
instead receive the human's approval directly under an explicitly chosen route.
A plan ID or agent-authored approval message does not authenticate the human.
New approval summaries should include `Approve apply PLAN_ID` with the full actual
ID substituted, while retaining the presented summary and the human response.

**Can the controller produce the launch handoff instead of making the operator assemble it?**
For a fully applied context-aware task, use `sandbox-task.sh launch-handoff TASK`.
It returns JSON with copy-ready `text`, snapshot mappings, approved ownership and
current repository identities. It does not start an agent or authorize work.
Legacy tasks retain the manual route. See
[the checked handoff](OPERATOR.md#generate-a-checked-launch-handoff).

**Why does `launch-handoff` refuse a task whose status is `ready`?**
`ready` describes repository/input health, not unchanged context. The new command
also requires no active send and selected context unchanged since its applied
approval. Legitimate host edits or sandbox write-back can require newly reviewed
handling before generating another handoff. Do not overwrite canonical files or
rewind state to clear the refusal. Separate launch approval remains required.

**Does a committed handoff log replace transcript review?**
No. The lead's sanitized ledger indexes proposals, human approvals, receipts,
collections and review outcomes. Raw session/tool evidence remains private and
must be captured/retrieved for the actual CLI/setup. Controller state survives
workspace reset and CLI volumes may retain history, but neither establishes that
a complete transcript was captured. Follow the
[pre-run evidence gate](OPERATOR.md#before-a-pilot-run-establish-execution-evidence);
do not copy entire auth volumes, commit raw transcripts or claim unavailable
evidence was reviewed.

**Can I finish a recorder's missing manifest after a crash?**
Not as if the original capture completed. Preserve the original directory and,
after verifying inactivity and obtaining approval, create a separately identified
recovery receipt with hashes of the surviving bytes. Do not synthesize the missing
outcome or overwrite original artifacts. See
[interrupted recordings](OPERATOR.md#preserve-an-interrupted-recording).

**Can I remove an old `.operation-*` or `stage-send-*` directory?**
Not based on age or matching packet bytes alone. The lead must establish ownership,
inactivity, absence of mount/recovery dependencies and approve exact-path disposal
with the human; recheck under the relevant locks. There is no bulk prune command.
See [orphaned preparation staging](OPERATOR.md#inspect-and-dispose-of-orphaned-preparation-staging).

**An import was interrupted. Should I delete its Git locks?**
No. Use the tool's `recover` operation with the original packet and current expected
HEAD. It either removes the exact pre-commit round snapshot or finishes a committed
import's index publication. Unexpected subsequent edits are not overwritten.
Keep recovery state outside the workspace; do not delete it to make the error disappear.

**Which Maven profiles work offline?**
Only what prepare warmed. Default `agencyWWW` also covers `agencyintra` (same modules;
`-DBUILD=productionIntra` selects the intra WAR + Angular configs offline). `memberWWW`
covers `memberintra`. `vendorintra`/`intra` add the `itools` module — warm those
explicitly. See the coverage table in QUICKSTART step 3.

## Network & isolation

**How is the agent isolated if its changes appear in `~/pera-sandbox` on my machine?**
That folder IS the deliberate, single output channel — a disposable copy containing
nothing you can lose. Isolation means a precisely scoped write surface, not a hermetic
seal: the agent can't see your real working copies, `C:\`, other WSL paths, or the
network without the configured firewall restrictions. Those restrictions include agent
DNS, which is closed (only pinned names resolve), and, for Copilot, shared GitHub address
ranges; the workspace is the intended review
channel, not a proven exclusive data channel. Treat sandbox contents as unreviewed
input until a human reviews and merges them: inspect with `git diff`, don't run builds
from it on the host.

**Why does `Could not resolve host` appear inside the sandbox?**
That's expected (finding E6). The agent has no DNS; only the allowlisted endpoints resolve,
from a root-owned `/etc/hosts` block the firewall rewrites on each refresh. Registries,
`github.com` and telemetry hosts fail at name lookup, quickly, where they previously failed
at connect. If an agent CLI itself stops working after an update, it may have started
using a new endpoint. Find its name with a separately approved discovery run, and add
it to the launcher's allowlist through review. Do not edit `/etc/hosts` or bypass the
wrapper.

**Can the agent see git history / read old commits?**
Yes — the full history of the working branch, deliberately: `git blame`, prior-conversion
diffs, and revert context are part of how conversion work gets verified (Phase-8 legacy
deletion relies on revertability). The clone is `--single-branch`, so other branches'
objects aren't in the sandbox at all. If old commits contain retired secrets, rotate
them — they're equally present in every dev machine's clone, not a sandbox-specific
exposure.

**Can the agent push code anywhere?**
The agent is instructed to commit locally only, and several controls block common
push paths. That is not a universal technical prohibition: explicit destinations,
script indirection and subprocess HTTPS are not fully covered by command-pattern
rules. Copilot can reach shared GitHub ranges and has its own API authentication.
E1 fixes refresh/reopen transitions, not these remaining gaps. See
[README §4b](README.md#4b-github-copilot-cli-variant) and the security review.

**Why can't the agent run integration tests?**
They hardcode live dev infrastructure (AS400, Oracle) that the firewall blocks — by
design. The sandbox is unit-tests-only; DB-dependent verification happens after review,
on-network. Never pass `-Drun.integration.tests=true` in the sandbox.

**"Connection refused" during a session — is something broken?**
No — that's the firewall REJECTing (deliberately fail-fast, no hanging timeouts). If it
blocked something the task legitimately needs, see "agent needs a dependency" above.

**Does the Claude native sandbox (`/sandbox`) actually work here?**
Yes, as of 2026-08-05 — it used to fail on every Bash call. bubblewrap refuses to start
when a non-setuid binary holds capabilities, and the `--cap-add=NET_ADMIN/NET_RAW` the
firewall needs landed in the *ambient* set, so bwrap and the firewall were mutually
exclusive. `run-agent`/`run-copilot` now drop capabilities (`setpriv --inh-caps=-all
--ambient-caps=-all`) after lockdown and before starting the agent, which fixes bwrap and
takes `CAP_NET_ADMIN` away from the agent at the same time. That historical check
established compatibility, not mandatory enforcement. Phase 3 makes the sandbox
mandatory from a root-owned managed policy: `sandbox.failIfUnavailable` refuses to start
without it and `allowUnsandboxedCommands: false` ignores `dangerouslyDisableSandbox`
(E2/E3). On a test image both held: a write outside `/workspace` and `/tmp` was refused
even with `dangerouslyDisableSandbox` (retained transcript). With capabilities still held,
the CLI did start but its Bash command failed rather than running unsandboxed. The same held
on the deployed image, where the live checks in the
[Phase 3 spec](design/phase3-inner-sandbox-and-startup.md#15-build-rehearsal-finding-g2-and-the-second-rebuild-2026-09-27)
passed on 2026-09-27.

**`run-agent` or `claude` says `REFUSED (finding N5)` or `(finding E5)`. What now?**
Nothing was changed. E5 means an agent CLI was started outside `run-agent` /
`run-copilot`. N5 means an input that survives between sessions would give the next
session a looser policy. That covers:
- the workspace's `.claude/` settings, `.mcp.json` or a root `.git`;
- the Claude config volume's user settings, server-managed settings cache or `.claude.json`;
- a package cache in the Copilot volume. Treat it as
something a previous session did until you know otherwise. Inspect and restore it as in
[QUICKSTART "Startup refusals"](QUICKSTART.md#startup-refusals).

**Why doesn't prepare refresh the agent CLIs any more?**
It used to stage them on the workspace for the launchers to prefer. The workspace is
agent-writable and persists, so one session could leave the next a modified CLI that
ignores every policy (finding N5, decision A of the Phase 3 spec). Only the image-baked
CLIs run now; a CLI update is an image rebuild. An old workspace's `.agent-cli/` is
removed by the next prepare and ignored until then.

**A build fails under the native sandbox with "Read-only file system". Why?**
Java ignores `$TMPDIR`. The sandbox makes only the working directory and a session temp
directory writable, and points `$TMPDIR` at the latter — but `java.io.tmpdir` defaults to
`/tmp` regardless, so jansi's native-library extraction and the WAR plugin's staging both
write to a read-only `/tmp` and the `agency` WAR assembly dies. The managed policy
(`container/claude-managed-settings.json`) therefore sets `sandbox.filesystem.allowWrite:
["/tmp"]`. Don't remove it: without it the build fails every time, and since Phase 3
there is no unsandboxed retry to recover with.

**Why is the image CentOS and why does everything come from Nexus?**
Zscaler on this network blocks Debian mirrors, nodejs.org, registry.npmjs.org, and most
direct downloads (it kills full downloads even where small probes succeed). CentOS
mirrors + EPEL + the internal Nexus proxies are the allowed channels. Baked-in corp CAs
handle the TLS interception. Details: README "Environment assumptions".

## Git & harvesting

**Which branch is the agent's work on?**
For a registered task, use `sandbox-task.sh status TASK` to distinguish the
registered branch from the current stopped-workspace observation. A running result
does not establish a fresh HEAD. The collected package records the exact branch and
candidate head for each repository; do not infer them from today's host checkout.

**Do I need to be on a particular branch to harvest?**
Importing a verified collection bundle into a new local provenance ref does not
change the checked-out branch. Integrating its changes is a separate approved
operation against an explicit host branch and HEAD. A fast-forward is appropriate
only if every intervening change belongs on that branch; import bookkeeping and
independent host edits often require more selective integration. Use the
[harvest runbook](OPERATOR.md#harvest-and-integrate-reviewed-work), not a direct
fetch from the agent-controlled repository.

**Which diff should the outside reviewer use?**
The collection's `changes.patch` uses its recorded full audit base; `work.patch`
focuses on work after the latest complete handoff. Review them together with the
history and input provenance. A three-dot diff from the host's current branch is
not a substitute for those explicit bases and does not remove import bookkeeping
or already-present document synchronization changes.

**The agent changed files in Documentation too — one harvest or two?**
One task `collect` packages both repositories, with separate candidates and artifacts.
Host integration remains per repository and can be partial. Record any withheld
document and retain its original collection: later collection bases have already
advanced and may not include that outstanding edit again.

**I reset the sandbox and lost commits. Recoverable?**
No — `--force` deletes the workspace including its git objects. It now refuses when a
branch, HEAD or stash holds commits that no ref in the source repo has, so this takes
`--discard-unharvested`, or work it does not look for: tags and other non-branch refs,
and reflog-only commits. Unexpected files at the workspace root are reported, but only by
name. Harvest before every reset.
(The reflog trick doesn't help: the entire repo is gone, not just the ref.)

## Troubleshooting

**Login doesn't persist between container runs.**
Recreate the affected volume and log in once more: `podman volume rm -f
pera-claude-config` (Claude) or `pera-copilot-config` (Copilot). Root cause: a volume
first created by a container without `--userns=keep-id` is unwritable — details in
README.

**Copilot: "sign in error" or "not authenticated".**
Check that the session was started with
`--secret pera-copilot-token,type=env,target=COPILOT_GITHUB_TOKEN`, and that the PAT
has not expired and has the Copilot Requests account permission. The firewall allowlists
GitHub's published IP ranges; also check `run-copilot`'s startup output for the
"could not fetch api.github.com/meta" fallback warning.

<a id="copilot-refused-finding-n3"></a>
**Copilot: `REFUSED (finding N3)`, exit 78.**
`run-copilot` accepts only a fine-grained PAT in `COPILOT_GITHUB_TOKEN`. Set it up per
QUICKSTART step 4-alt. If the message names `config.json`, the auth volume still holds a
sign-in token from the retired `/login` flow, which carries the `repo` and `gist` scopes.
Remove it without printing it, inside WSL:

```bash
podman run --rm --userns=keep-id --network none -v pera-copilot-config:/home/vscode/.copilot \
  --entrypoint bash pera-sandbox -c 'f=$HOME/.copilot/config.json; { grep "^[[:space:]]*//" "$f"; grep -v "^[[:space:]]*//" "$f" | jq "del(.copilotTokens, .lastLoggedInUser, .loggedInUsers)"; } > "$f.new" && chmod 600 "$f.new" && mv "$f.new" "$f"'
```

Deleting the local copy does not invalidate the token. Also revoke it: GitHub → Settings →
Applications → Authorized OAuth Apps → **GitHub Copilot CLI** → Revoke. That signs out
every Copilot CLI OAuth session for your account, including a Copilot CLI on the host,
which then needs `/login` again. Do not use `/login` inside the sandbox.

**`run-agent`/`run-copilot` aborts with a firewall error before the agent starts.**
Do not bypass the wrapper. DNS resolution, rule staging/installation, state consistency,
lock acquisition or a smoke probe can fail; read the error before assuming the cause.
Check WSL networking, Zscaler behavior and the container's NET_ADMIN/NET_RAW flags.
A DNS/staging failure before initial installation can be retried once corrected.
Incomplete installation or inconsistent state requires a fresh container.

**The error says "incomplete lockdown state" or "use a fresh container".**
Exit and recreate the agent container from the intended image, retaining the same
workspace and auth volume. Do not delete `/run/claude-firewall`,
`/run/claude-lockdown-domains` or kernel chains to force a retry. This state makes
interrupted initialization non-reopenable. A new container is not a workspace reset;
`new-sandbox.sh --force` is unnecessary and would destroy work and caches.

**"Allowlist refresh failed" appears during a session. Is the network open?**
The refresh does not flush live rules or deliberately reopen networking on failure.
Before activation, errors leave the old snapshot active; after activation,
cleanup/probe errors leave the new snapshot active. The warning is visible while
the agent continues, and provider connectivity may degrade. Read the preceding
firewall error; do not widen the allowlist or disable the firewall to recover.
Interrupted initialization or inconsistent state calls for a fresh container.

**The script selected per-IP rules instead of ipset. Is that a failure?**
No. Initial lockdown selects the per-IP backend if ipset is unavailable. That backend
is fixed for the container. Both backends stage replacements without flushing the
live firewall; an ipset error during refresh does not trigger a backend migration.

**Maven build fails wanting `.secrets/settings.xml` during prepare.**
`run-agent`/`run-copilot` purge `.secrets/` at every start (by design). Re-stage before
re-running prepare or rebuilding the image: copy your `~\.m2\settings.xml` and `~\.npmrc`
back into `~/pera-sandbox/.secrets/`, protecting the directory with mode 700 and files
with mode 600. Only the npm file is needed for the image build; prepare also needs
Maven settings. Do not reset the workspace just to re-stage credentials.

**`ng build` segfaults / Angular builds die silently.**
You're probably not in the sandbox container (its image ships the official node binary
specifically because the dnf/RHEL node build segfaults on Angular's build pipeline). On
any RHEL-family machine outside the sandbox: install official node binaries, don't use
`dnf install nodejs`.
