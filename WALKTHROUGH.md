# Walkthrough — how the agent sandbox works, step by step

This is the end-to-end path through the sandbox, from an empty machine to reviewed work on a
host branch. Every step has the same four parts:

- **Who** does it: the human, the ticket lead, the operator subagent, a reviewer, or the
  sandbox agent.
- **Do**: the command or action.
- **Mechanism**: what actually happens, with the file and line that does it.
- **Refuses when**: the checks that stop it, and what a refusal means.

It was written on 2026-10-07 against `main` at `ddfa351`, by reading the scripts, not the
other guides. Where it and the code disagree, the code is right; where it and README,
QUICKSTART or FAQ disagree, see [Where the older guides drifted](#where-the-older-guides-drifted).
OPERATOR.md stays the rulebook for agent-operated ticket work; this guide explains it.

## Contents

- [The pieces](#the-pieces)
- [Once per machine](#once-per-machine)
- [1. Assemble a workspace](#1-assemble-a-workspace)
- [2. Build the image](#2-build-the-image)
- [3. Warm the caches](#3-warm-the-caches)
- [4. Register a task](#4-register-a-task)
- [5. Write and review the brief](#5-write-and-review-the-brief)
- [6. Prepare the send](#6-prepare-the-send)
- [7. Approve and apply](#7-approve-and-apply)
- [8. Launch the agent](#8-launch-the-agent)
- [9. While the agent works](#9-while-the-agent-works)
- [10. Collect](#10-collect)
- [11. Review](#11-review)
- [12. Fix rounds](#12-fix-rounds)
- [13. Harvest and integrate](#13-harvest-and-integrate)
- [Keeping track](#keeping-track)
- [What every operator command has in common](#what-every-operator-command-has-in-common)
- [Claude Code and Copilot compared](#claude-code-and-copilot-compared)
- [Changing the scaffold itself](#changing-the-scaffold-itself)
- [Known gaps](#known-gaps)
- [Where the older guides drifted](#where-the-older-guides-drifted)

---

## The pieces

### Places

| Place | What it is | Who writes it |
|---|---|---|
| `C:\work\pera\prj`, `C:\work\pera\Documentation` | Your real working copies on Windows | The human and the ticket lead only |
| `C:\work\pera\claude-sandbox` | This scaffold: scripts, image definition, policies, docs | Scaffold maintenance only |
| `~/pera-sandbox-<campaign>` in the `centos-9` WSL distro | A **workspace**: disposable clones of both repos, warmed caches, staged image inputs. One per campaign is the recommended layout; `~/pera-sandbox` is only the default name | `new-sandbox.sh`, `prepare`, the import step, and the sandbox agent |
| `localhost/pera-sandbox` | The **image**: CentOS Stream 9 with the toolchain, both agent CLIs, the firewall and both policies, root-owned | `podman build` |
| Containers | Throwaway: one per prepare, one per agent launch, one per operator command. Each is removed when it exits (`--rm`) | — |
| `pera-claude-config`, `pera-copilot-config` | Podman **volumes** holding each CLI's login and session history. They persist between launches | The CLIs |
| `pera-copilot-token` | A podman **secret**: your Copilot-only token | You, once |
| `~/.local/state/pera-sandbox-tasks/<TASK>/` | The task controller's **private state**: record, plans, collections, lock. Mode 700 | `sandbox-task.sh` only |
| `~/.pera-evidence/<TASK>-<ROUND>/` | Exported session evidence. Mode 700 | The lead, by recipe |

### Actors

| Actor | Where | Does | Never does |
|---|---|---|---|
| **Human** | Windows / WSL terminal | Reviews each brief, approves each send, launches or approves the launch, approves integration, pushes | — |
| **Ticket lead** | One persistent Claude Code session in `C:\work\pera` | Owns the ticket: drafts briefs, commits them, applies approved plans, harvests, integrates after approval. **The only agent that writes to the host checkouts** | Approve its own plans |
| **Operator** | A subagent of the lead | `register`, `send` (prepare only), `status`, `collect` | Apply, launch, recover or integrate unless told to |
| **Reviewers** | Fresh subagents (or another vendor's CLI) per pass | Read a review packet, return findings | Edit, stage or commit anything |
| **Sandbox agent** | Inside a locked container | Implements the round's brief, commits locally, stops | Push (no remotes, no credentials, no route) |

The roles are working discipline, not an authentication boundary: the controller does not
know which agent called it. OPERATOR.md "Agent roles and single-writer ownership" is the rule.

### One round at a glance

| # | Who | Step | Guide section |
|---|---|---|---|
| 1 | Lead | Draft the brief | [5](#5-write-and-review-the-brief) |
| 2 | **Human** | Review the brief | [5](#5-write-and-review-the-brief) |
| 3 | Lead | Commit the reviewed brief | [5](#5-write-and-review-the-brief) |
| 4 | Operator | `send`: export, preview, plan ID | [6](#6-prepare-the-send) |
| 5 | **Human** | Approve that exact send | [7](#7-approve-and-apply) |
| 6 | Lead | `send --apply` | [7](#7-approve-and-apply) |
| 7 | **Human** | Launch the agent, or approve a headless launch | [8](#8-launch-the-agent) |
| 8 | Sandbox agent | Implement, commit, stop | [9](#9-while-the-agent-works) |
| 9 | Operator | `collect` | [10](#10-collect) |
| 10 | Reviewers | Two review passes | [11](#11-review) |
| 11 | Lead | Next round, or harvest and integrate after approval | [12](#12-fix-rounds), [13](#13-harvest-and-integrate) |
| 12 | **Human** | Push | [13](#13-harvest-and-integrate) |

Steps 1 to 4 of this guide (assemble, build, warm, register) happen once per campaign or
task, before the first round.

---

## Once per machine

**Who:** the human.

| Need | Check |
|---|---|
| `centos-9` WSL distro with rootless podman | `wsl -d centos-9 -- podman --version` |
| Nexus credentials | `%USERPROFILE%\.m2\settings.xml` and `%USERPROFILE%\.npmrc`, as for any PERA build |
| A git identity inside WSL | `git config --global user.name` / `user.email` in `centos-9`; or pass `SANDBOX_GIT_NAME` / `SANDBOX_GIT_EMAIL` |
| Working copies | `C:\work\pera\prj` and `C:\work\pera\Documentation` |
| The scaffold | `C:\work\pera\claude-sandbox`, cloned from `main` of its GitHub repository (by invitation) |
| The git-ignored skills | `prj/.agents/skills/agency-jsp-to-angular/` and `prj/.agents/skills/angular-developer/` in your `prj` checkout (`new-sandbox.sh:115-118` requires them) |
| Corporate network | For assembly, build and prepare only |
| An agent account | A Claude subscription, or a Copilot Enterprise licence |

**Copilot only — a narrow token.** Create a GitHub fine-grained token with *Account
permissions: Copilot Requests* and nothing else, then store it without echoing it:

```bash
# inside WSL
read -rsp 'Copilot fine-grained PAT: ' pat; printf '%s' "$pat" | podman secret create pera-copilot-token -; unset pat; echo
```

*Mechanism:* GitHub's addresses are reachable from Copilot sessions (see step 8), so the
token is what stops a push. `run-copilot` refuses anything that is not a `github_pat_`
token (`container/run-copilot.sh:31-34`). Rotate it with `podman secret rm` and `create`.

**Claude only — the login.** The first `run-agent` asks you to log in and to accept the
bypass prompt. The login lands in the `pera-claude-config` volume
(`CLAUDE_CONFIG_DIR=/home/vscode/.claude` is baked into the image).

---

## 1. Assemble a workspace

**Who:** the human, or the lead with approval. **When:** once per campaign, and again
whenever the campaign's host branch has moved on (see [Fix rounds](#12-fix-rounds)).

**Do** (inside WSL; check out the campaign's branches in your host `prj` and
`Documentation` first — the clone takes whatever is checked out):

```bash
SANDBOX_ROOT=~/pera-sandbox-eep24 bash /mnt/c/work/pera/claude-sandbox/new-sandbox.sh
```

**Mechanism** (`new-sandbox.sh`):

1. **Checks inputs** (`:45-133`): `SANDBOX_ROOT` must be inside your WSL home, not reached
   through a symlink, and not overlap the sources or the scaffold; a git identity must
   exist; both credential files must exist; the two required skills must be present as
   regular files.
2. **Clones both repos** (`:270-273`) from your Windows working copies with
   `--single-branch`, `core.autocrlf=false` and LF endings. The agent gets the **full history
   of the current branch only**, and only **committed** state: uncommitted edits are left
   behind on purpose.
3. **Strips the remotes** (`:279-280`). Harvest never needs them: work leaves through
   `collect` (step 10).
4. **Sets the commit identity** in each clone (`:283-287`).
5. **Overlays the git-ignored AI assets** (`:291-305`): copies `prj/.agents` (and
   `prj/.github` if present) into the clone, then proves the required skills arrived.
6. **Drops in the agent's instructions and settings** (`:308-321`): `overlay/CLAUDE.md` as
   both `CLAUDE.md` and `AGENTS.md` at the workspace root (Copilot reads `AGENTS.md`), the
   canonical `.claude/settings.json`, and the `.devcontainer/` and `container/` folders the
   image is built from, all normalised to LF.
7. **Stages the corporate root CAs** from `/etc/pki/ca-trust/source/anchors/` (`:324-329`).
8. **Stages the Nexus credentials** into `.secrets/` with mode 600 (`:332-335`). They exist
   only for the build and prepare steps; every agent launch deletes them.
9. **Marks the directory** as assembled (`:263-264`), so `--force` will only ever delete a
   directory it created.

**Resetting an existing workspace** needs `--force`, and it **refuses** (finding V2) when:
a task is registered to the workspace; a repo has uncommitted or in-progress work, linked
worktrees, or commits no host ref has; or the root holds files assembly didn't create. It
reads the old workspace through `sandbox-round.sh inspect` in a network-less container,
never with host Git, because the agent controls those repos' config and hooks.
`--discard-unharvested` overrides the work checks, never a running container or a pending
import recovery. **Harvest before every reset**: a reset deletes the repos' objects, so
nothing is recoverable afterwards.

**Do not** use `--force` to update the image; see step 2.

---

## 2. Build the image

**Who:** the human. **When:** the first time, and whenever the Dockerfile or any file it
copies changes.

**Do:**

```bash
cd ~/pera-sandbox-eep24
podman build --secret id=npmrc,src=.secrets/npmrc -t pera-sandbox -f .devcontainer/Dockerfile .
```

**Mechanism** (`.devcontainer/Dockerfile`):

- **Base and trust** (`:5-13`): `quay.io/centos/centos:stream9`, because Zscaler blocks the
  Debian mirrors. The staged corporate CAs go into the system store; on RHEL-family
  `update-ca-trust` regenerates the Java store too. Node is pointed at the same bundle
  (`NODE_EXTRA_CA_CERTS`).
- **Toolchain:** JDK 17; Maven 3.9.9 from Nexus `maven-public`; the **official** Node
  22.13.0 binary installed **at `/usr/bin/node`** (`:48-57`), assembled from the
  `node-linux-x64` npm package because nodejs.org is blocked, and because dnf's node
  segfaults on Angular's native build pipeline; global `@angular/cli@21` (grunt strips the
  child environment on Linux, so builds need it on the default PATH); Chromium plus its
  headless shell, with `CHROME_BIN` naming the headless shell (`:83-86, 106`) because it is
  the one that starts inside Claude's sandbox (finding G2).
- **Both agent CLIs are baked in:** Copilot from the Nexus npm proxy (`:74`), Claude Code
  from its installer (`:177`). The build secret feeds the npm installs without leaving the
  credential in a layer. **Every rebuild installs the current release of each** (backlog
  S-3), so record both versions after a rebuild.
- **Root-owned policy, installed read-only to the agent:**
  - Claude's **managed settings** at `/etc/claude-code/managed-settings.json` (`:150-159`),
    plus a copy of the canonical project settings that `run-agent` compares against;
  - Copilot's **policy hook** at `/etc/github-copilot/policy.d/10-guardrails.json` and its
    script (`:133-139`);
  - the **guarded wrappers** at `/usr/local/lib/pera-sandbox/bin/{claude,copilot}`, first on
    `PATH` (`:165, 193`);
  - `init-firewall.sh`, `prepare-sandbox`, `run-agent`, `run-copilot` (`:113-116`).
- **Sudo is scoped to one script** (`:96-98`): `vscode ALL=(ALL) NOPASSWD:
  /usr/local/bin/init-firewall.sh`. The agent cannot `sudo` anything else.

**Updating an existing workspace's image** without losing work: copy the reviewed
`Dockerfile`, `container/*` and `overlay/CLAUDE.md` into the workspace, re-stage
`.secrets/npmrc` if a launch purged it, rebuild, and start a new container (QUICKSTART
"Update the image without resetting the workspace"). Running containers are never updated
in place. **A rebuild changes the image ID, and every registered task pins the old one**
(see [Keeping track](#keeping-track)). Remove old images with `podman rmi --no-prune`:
plain `rmi` also deletes untagged parents a task may still pin.

---

## 3. Warm the caches

**Who:** the human. **When:** once per workspace, before the first agent run that builds or
tests; again only for a new profile or dependency.

**Do** (one workspace at a time needs no suffix; give every container a suffix when two
workspaces run at once):

```bash
podman run -d --name pera-prepare-eep24 --userns=keep-id --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -e PREPARE_PROFILES="agencyWWW" \
  -v ~/pera-sandbox-eep24:/workspace -w /workspace pera-sandbox prepare-sandbox
podman logs -f pera-prepare-eep24     # wait for "Prepare complete."
podman rm pera-prepare-eep24
```

`-e PREPARE_PROFILES` must come **before** the image name, or podman passes it to the script.
Member work needs `memberWWW`; `agencyWWW` also covers `agencyintra`.

**Mechanism** (`container/prepare.sh`), in a container with the network **open** and **no
agent login mounted**, because it runs the repositories' own build scripts:

1. Builds a Node tarball for every `<nodeVersion>` the module poms pin (agency and member
   are on 22.13.0; shared, tools and investment on 18.10.0) from Nexus npm packages, and
   feeds them to Maven with `-DnodeDownloadRoot=file:///workspace/.node-cache/`, so the poms
   stay untouched.
2. Runs the root `npm ci` for the grunt tooling.
3. Runs `mvn clean install -P <profiles> -DskipTests` with the credentialed `settings.xml`,
   which fills `/workspace/.m2` and gives each module its `node/` and `node_modules/`.
4. **Deletes every `_remote.repositories` file** from the Maven cache. Maven stamps each
   artifact with the repository id it came from; that id is declared only in the
   credentialed settings, which every launch deletes, so without this step the warm cache
   refuses to resolve offline.

The caches live on the **workspace**, not in the image: they survive rebuilds and are lost
only when the workspace is reassembled. A module that wasn't warmed fails offline, loudly;
that is the firewall working.

---

## 4. Register a task

**Who:** the operator. **When:** once per ticket, against the campaign's workspace.

**Do:** write a private task file (outside every repo and workspace), then:

```bash
bash /mnt/c/work/pera/claude-sandbox/sandbox-task.sh register --config /absolute/private/task.json
```

```json
{"version":1,"task":"EEP-24-A11Y","workspace":"/home/<you>/pera-sandbox-eep24",
 "image":"localhost/pera-sandbox","profiles":["agencyWWW"],
 "repositories":{
   "prj":{"source":"/mnt/c/work/pera/prj","ref":"refs/heads/<branch>",
     "auditBase":"<full commit id>","briefs":[]},
   "Documentation":{"source":"/mnt/c/work/pera/Documentation","ref":"refs/heads/<docs-branch>",
     "auditBase":"<full commit id>","briefs":["<path/to/brief.md>"]}}}
```

**Mechanism:**

- The schema is closed: every field is required, nothing else is accepted
  (`sandbox-task.sh` usage text). Paths must be real, absolute, non-symlinked and must not
  overlap each other, the scaffold or the controller state.
- Each `auditBase` must already be an ancestor of the workspace repo's HEAD. For a new task
  that is usually the commit the workspace was cloned at; for work already in progress it is
  the last audited commit. Choosing today's HEAD would hide earlier work from collection.
- It writes `~/.local/state/pera-sandbox-tasks/<TASK>/record.json` (mode 600, directory 700),
  pinning the **image by its ID**, not its tag, and recording each repo's branch and HEAD.
- Registering the identical definition again changes nothing. A changed definition needs a
  **new task ID**; the record is never edited by hand.
- Registration clones, warms and launches nothing. From now on, `new-sandbox.sh --force`
  refuses to reset this workspace.

---

## 5. Write and review the brief

**Who:** the ticket lead drafts; the human reviews. **When:** every round.

**Do:**

1. The lead drafts the brief. Every claim about existing code is checked at the baseline
   commit and cited with file and line, or it is not written. Acceptance criteria are
   **quoted** from their source with line citations, not paraphrased.
2. The lead **presents the draft before committing it**. The human may also have other agent
   reviewers read it; their findings go back through the lead, which stays the only writer.
   The loop repeats until the human accepts it. The lead records which version was reviewed.
3. The lead commits the reviewed brief in its source repository — only the intended files.

**Mechanism:** nothing is enforced here; this is OPERATOR's "Send a committed brief". It
matters because the next step reads **only committed bytes**: an edit that isn't committed
never reaches the sandbox, and the approval in step 7 is tied to the exact committed bytes.

---

## 6. Prepare the send

**Who:** the operator.

**Do:**

```bash
bash /mnt/c/work/pera/claude-sandbox/sandbox-task.sh send EEP-24-A11Y                    # registered briefs
bash /mnt/c/work/pera/claude-sandbox/sandbox-task.sh send EEP-24-A11Y --brief Documentation:path/R2.md
bash /mnt/c/work/pera/claude-sandbox/sandbox-task.sh send EEP-24-A11Y --handoff /abs/private/handoff.json
```

`--brief` replaces the whole selection for that send. `--handoff` opts the task into
context tracking (version 2): it also declares supporting documents with a role
(`reference`, `shared` or `host-owned`) and a handling decision for each.

**Mechanism:**

1. **Export** (`tools/rounds/rounds.js` `exportPacket`): a throwaway container mounts the
   **host source repo read-only** and reads the selected `.md` / `.txt` files **as committed
   on the registered branch**. It writes a packet: path, blob ID, SHA-256 and content per
   file. Uncommitted edits, other files and branch history never travel. A script travels as
   a document.
2. **Preview:** another container mounts the **workspace repo read-only** and works out what
   the import would change. An unchanged brief creates no new round.
3. **Plan:** the result is saved under `plans/<plan-id>/` in the task state. The **plan ID is
   a fingerprint** of the exact operation: the image ID, both target repos' heads and
   branches, the source commits and the packet bytes.
4. The operator returns a summary to the lead: destination, inputs with their pinned commits
   and each brief's blob, which repos will change, any blocking state, and the copyable
   phrase `Approve apply <PLAN_ID>`.

**Refuses when:** the workspace is dirty, has untracked files, a Git operation in progress,
or a running container mounted; paths are unsafe; or the registered state no longer matches
(see [What every operator command has in common](#what-every-operator-command-has-in-common)).
A context-aware send with an undecided document returns `needs-decision` and no plan ID.

---

## 7. Approve and apply

**Who:** the human approves; the lead applies.

**Do:**

1. The lead checks each selected brief's pinned blob against the version the human
   reviewed in step 5. If they differ, the human reviews the committed version first.
2. The human approves the exact plan, ideally with the phrase `Approve apply <PLAN_ID>`.
   An agent-written "approved" is not approval.
3. The lead runs:

```bash
bash /mnt/c/work/pera/claude-sandbox/sandbox-task.sh send EEP-24-A11Y --apply <PLAN_ID>
```

**Mechanism** (`rounds.js` `importPacket`): the only operator command that writes into a
workspace.

- A container mounts **that one repo read-write** and the packet read-only.
- It revalidates the plan and **uses the pinned packet, never newer source**. If the source
  branch has moved since, apply still imports the approved snapshot; preparing a new plan is
  how newer content gets in.
- It writes `sandbox-rounds/<task>/<round>/` — `README.md` (what the agent reads first),
  `manifest.json` (every file's blob ID and SHA-256 plus the packet's SHA-256) and `files/` —
  and commits it, plus a provenance commit, **on top of the existing sandbox branch**.
  Nothing is merged, reset or re-warmed, and earlier agent commits stay.
- A journal and locks make an interrupted apply recoverable. A partly applied send is
  retried only with the **same** plan ID.

**Then,** for a context-aware task, `sandbox-task.sh launch-handoff EEP-24-A11Y` generates
the launch text: which round README to read, the snapshot paths, the write-back paths and
their owners. It refuses changed context or unsafe repository state, and it does not launch
or approve anything. Older (version 1) tasks write the launch text by hand.

---

## 8. Launch the agent

**Who:** the human launches interactively, **or** approves a headless launch the lead runs.
**When:** after apply. Every launch is a new container.

### The commands

**Claude Code, interactive.** You see the CLI and can type to steer it, or press Esc to
interrupt:

```bash
podman run -it --rm --name pera-agent-eep24 --userns=keep-id --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/pera-sandbox-eep24:/workspace -v pera-claude-config:/home/vscode/.claude \
  -w /workspace pera-sandbox run-agent
```

Then paste the launch text. Wrap the command in `sandbox-record.sh` (below) to keep a
terminal record; capture of an interactive Claude session has not been demonstrated yet.

**Claude Code, headless,** with the event stream kept as evidence. The launcher's banner
shares stdout, so the JSON events are the lines starting with `{`:

```bash
install -d -m 700 ~/.pera-evidence/EEP-24-A11Y-R1
podman run --rm --name pera-agent-eep24 --userns=keep-id --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/pera-sandbox-eep24:/workspace -v pera-claude-config:/home/vscode/.claude \
  -w /workspace pera-sandbox run-agent -p "<launch text>" --output-format stream-json --verbose \
  > ~/.pera-evidence/EEP-24-A11Y-R1/stream.jsonl
```

**Copilot CLI, interactive,** recorded:

```bash
bash /mnt/c/work/pera/claude-sandbox/sandbox-record.sh --label EEP-24-A11Y-R1 --workspace ~/pera-sandbox-eep24 -- \
  podman run -it --rm --name pera-copilot-eep24 --userns=keep-id --cap-add=NET_ADMIN --cap-add=NET_RAW \
    --secret pera-copilot-token,type=env,target=COPILOT_GITHUB_TOKEN \
    -v ~/pera-sandbox-eep24:/workspace -v pera-copilot-config:/home/vscode/.copilot \
    -w /workspace pera-sandbox run-copilot
```

Headless Copilot passes `--autopilot -p "<launch text>"` to `run-copilot`.

These lines are still copied by hand; nothing checks that the right workspace is mounted.
A launcher that builds them from the task record is backlog S-14.

### What `run-agent` does, in order (`container/run-agent.sh`)

1. **Checks what the last session could have changed** (finding N5, `:34-84`). The workspace
   and the login volume persist and the agent can write both, so one session could loosen
   the next. It refuses with **exit 78, before touching the network**, when:
   - `/workspace/.claude/settings.json` differs from the canonical copy baked in the image;
   - a `settings.local.json`, `.mcp.json`, or a `.git` at the workspace root exists (a root
     `.git` would move where Claude reads local settings);
   - any checked file is a symlink or has a second hard link;
   - the volume's user settings set a key outside a reviewed allowlist, a server-managed
     settings cache holds anything, or `.claude.json` configures MCP servers.
   Recovery is QUICKSTART "Startup refusals". Treat a refusal as a finding, not a nuisance.
2. **Locks the firewall** (`:89`): `sudo /usr/local/bin/init-firewall.sh lockdown` (below).
   If it fails, nothing starts.
3. **Purges the credentials** (`:92-94`): `.secrets/`, `~/.m2/settings.xml`, `~/.npmrc`.
   After lockdown, never before.
4. **Starts a refresh loop** (`:96-101`): every 15 minutes it re-runs `lockdown`, which
   re-resolves the allowlisted names. A failure keeps the previous rules.
5. **Drops capabilities and starts the baked CLI** (`:108-127`):
   `setpriv --inh-caps=-all --ambient-caps=-all`, then the root-owned `claude` wrapper, then
   `claude --dangerously-skip-permissions`. Dropping the capabilities takes `CAP_NET_ADMIN`
   away from the agent, and is what lets bubblewrap run at all: it refuses to start while a
   non-setuid process holds capabilities.

### The firewall (`container/init-firewall.sh`)

- **Default deny, REJECT not drop:** outbound HTTPS only to the provider's resolved IPv4
  addresses (Anthropic for Claude; Copilot's hosts plus GitHub's published ranges for
  Copilot). Loopback and established traffic are allowed. Everything else is rejected, so
  tools fail fast instead of hanging.
- **No DNS for the agent** (finding E6): port 53 is rejected for every non-root user. The
  allowlisted names are written into a root-owned `/etc/hosts` block on each activation;
  any other lookup fails in milliseconds.
- **IPv6 is default-deny** (finding N4); lockdown refuses if it cannot filter IPv6.
- **Self-test:** it requires the provider to be reachable **and** `example.com` to be
  refused, or it fails.
- **One-way:** `open` exits 3 once the container has locked down. The **first** successful
  lockdown pins its domain list in `/run/claude-lockdown-domains`, root-owned and unreadable
  to the agent; later lockdowns ignore their arguments. Without both guards, the agent's
  scoped sudo would be an escape hatch. Refresh swaps an ipset (or one jump to a staged
  chain) and never flushes live rules.
- To get an open network again, start a new container. Every launch is one anyway.

### Claude's per-command sandbox

`/etc/claude-code/managed-settings.json` wraps **every Bash command** in bubblewrap: writes
only to the workspace and `/tmp` (Java ignores `$TMPDIR`, so WAR assembly needs `/tmp`), no
reads of `.secrets` or `~/.claude`, network only through a proxy for `api.anthropic.com`,
and no unsandboxed fallback. It also holds the deny rules and locks out lower-scope
permission rules, hooks and MCP servers. Claude's own file tools are governed by the deny
rules instead. Copilot has no equivalent yet (backlog S-13); see
[Claude Code and Copilot compared](#claude-code-and-copilot-compared).

### The wrappers (finding E5)

`claude` and `copilot` on the image `PATH` are root-owned wrappers
(`container/agent-cli-guard.sh`). They refuse, with exit 78, to start an agent before
lockdown or while capabilities are held, so a `podman exec`, a bare shell or a devcontainer
cannot start one unguarded. `--version` and `--help` still pass through.

---

## 9. While the agent works

**Who:** the sandbox agent; the human may watch an interactive session.

- **What it reads first:** `/workspace/CLAUDE.md` (or `AGENTS.md`), then the round's
  `sandbox-rounds/<task>/<round>/README.md`. The workspace instructions tell it to keep
  verification exit statuses, check current-build artifacts, report actual test counts, and
  send long output to a file under `/workspace` or `/tmp`.
- **What it can do:** build and test offline (unit tests only; integration tests need the dev
  AS400 and Oracle, which are blocked by design), and commit locally. It cannot push: no
  remotes, no Git credentials, and common push commands are denied.
- **When it stops:** it commits and exits. Exiting removes the container and its firewall.
  The workspace, commits, caches, login and transcripts persist.
- **Usage-limit stops (Claude):** the result says `subtype: "success"` but
  `is_error: true` with a 429, and the launcher exits 1. Resume in a new container with
  `run-agent --resume <session-id> -p "…"`, writing to a separate evidence folder. Judge a
  run by `is_error`, not `subtype`.
- **Resume by session ID, not `--continue`:** every workspace mounts at `/workspace`, so all
  Claude sessions share one session folder in the volume, and `--continue` picks the most
  recent one, which may belong to another task (backlog S-12).

**Evidence.** `collect` does not export transcripts. After the container stops, export only
the session's own files, through a read-only mount (OPERATOR "Claude Code session evidence"):

```bash
SID=<session-id>
EV="$HOME/.pera-evidence/EEP-24-A11Y-R1"; install -d -m 700 "$EV"
podman run --rm --pull never --network=none --userns=keep-id \
  -v pera-claude-config:/v:ro -v "$EV:/out" --entrypoint bash localhost/pera-sandbox -c \
  'cd /v/projects && find . -path "*$0*" -type f -print0 | tar --null -T - -cf /out/session-files.tar' "$SID"
(cd "$EV" && sha256sum -- * > manifest-sha256.txt && chmod 600 -- *)
```

Never copy the whole volume, and never commit raw transcripts. Scripting this export is
backlog S-15.

---

## 10. Collect

**Who:** the operator. **When:** after the agent has committed and stopped.

**Do:**

```bash
bash /mnt/c/work/pera/claude-sandbox/sandbox-task.sh collect EEP-24-A11Y
```

**Mechanism** (`rounds.js` `collectRepository`, `:1032-1085`; `sandbox-round.sh:320-334`).
This is the only operator command that reads the agent's code, and it does so read-only:

1. For each repo, a container mounts the **workspace repo read-only** and an empty output
   folder read-write.
2. It requires a clean tree, no pending import, and a HEAD equal to the expected one; both
   bases must be ancestors of HEAD.
3. It writes:
   - `changes.patch` — `git diff --binary` from the **last collection point** (the audit base,
     the first time) to HEAD;
   - `work.patch` — the same from the **last import** to HEAD, so only the agent's work for
     this round;
   - `history.bundle` — every new commit (`git bundle create HEAD ^base`), checked with
     `git bundle verify` before it counts;
   - `manifest.json` — the head, branch, both bases, every changed path, and which changed
     paths are imported inputs under `sandbox-rounds/`; a SHA-256 for every file.
4. It confirms HEAD and the index didn't change while it ran. Output is written to a staging
   folder and moved into `collections/<id>/<repo>/` only when complete, with a
   `collection.json` and `provenance.json` over the whole package.
5. **Only a complete, checksummed package advances the task's collection point.** An
   interrupted collection changes nothing.

**Refuses when:** the tree is dirty, an import is pending, a container is running on the
workspace, or new Git LFS pointer files appear anywhere in the new history (a bundle doesn't
carry LFS payloads).

A package holds commits. It is not a transcript, and it is not proof that a test passed.

---

## 11. Review

**Who:** the lead builds the packet; fresh reviewers read it. **Never** in the sandbox
clones: the agent controls their Git config and hooks, so host Git or an IDE pointed at them
would run whatever it left there. The package is the only thing that leaves the sandbox.

**Do:**

1. **Copy the package out and re-verify it.** Copy only the needed artifacts from the task
   state to a private folder **outside every Git repository**, then re-hash them against
   `collection.json`. JWA-2906 R1 used `C:\work\pera\.review\JWA-2906-R1\package\`. Keep the
   path short: Copilot's file viewer refuses paths over 260 characters and reports it as
   "Permission denied".
2. **Check the bundle against the host repos:** `git bundle verify <bundle>` in each host
   repository confirms the prerequisite commits exist there. It imports nothing.
3. **Build the packet:** the patches, a changed-path inventory, the acceptance criteria
   quoted from the brief at its pinned blob, the candidate and baseline commit IDs, and the
   relevant code and tests at the baseline (and, where needed, at the candidate). Evidence
   carries its method, not just its result. If you export files with `git archive`, pass
   `-c core.autocrlf=false`, or the files come out CRLF and no longer match their blobs.
4. **Pass 1 — independent technical review.** A fresh reviewer with the packet only: none of
   the lead's reasoning, preferred solution or status prose. **Start it from the review
   folder**, not `C:\work\pera`: a session started in the workspace auto-loads the campaign's
   narrative, which broke pass-1 independence on JWA-2906 R1.
5. **Pass 2** also checks the extracted criteria against their source text, so a faulty
   extraction can't quietly rewrite the contract.
6. Reviewers return findings only. A reviewer from a different vendor or model gives more
   independence than one Opus reviewing another.

Reviewing doesn't need the round's commits on the host at all. On JWA-2906 R1 the packet was
issued before any provenance ref existed.

---

## 12. Fix rounds

**Who:** the lead, the human, the operator — the same loop as steps 5 to 11.

**Do:** the lead weighs the findings and drafts a fix brief; the human reviews it; the lead
commits it in the host task folder; the operator sends it; the human approves; the lead
applies it as round R2; the agent is relaunched (resume its session by ID to keep its
context); the operator collects again.

**Mechanism:**

- R2 is imported **on top of the same sandbox branch**, so round 1's commits are still there
  and the agent fixes forward.
- **Round work never touches the host working branch while rounds run.** Only briefs (docs
  commits) and the ledger are committed on the host.
- R2's collection is **incremental**: `changes.patch` and the bundle start at the previous
  collection point. That's why earlier bundles' commits must stay available on the host (see
  step 13): a later bundle needs them as prerequisites.
- **What can't come in:** newer host **code**. Briefs are the only thing that travels. If the
  campaign's host branch has moved on (host-first work, a rebase), the next round needs a
  freshly assembled workspace, registered as a new task.

---

## 13. Harvest and integrate

**Who:** the lead, with a separate human approval for integration and another for the push.

**Do** (OPERATOR "Harvest and integrate reviewed work"):

1. **Verify:** the package's root manifest against the recorded receipt, and each artifact's
   SHA-256 against its manifest.
2. **`git bundle verify`** in the host repo. Missing prerequisites mean locating the matching
   earlier collection; never fetch some other branch to make it work.
3. **Import into a provenance ref, without checking it out:**

   ```bash
   git fetch <path>/history.bundle HEAD:refs/sandbox/<task>-<round>
   ```

   Choose a new name. An existing name is accepted only if it is exactly the recorded
   candidate; never force-update it. **Keep these refs:** the next incremental bundle builds
   on them. The working tree and current branch don't change.
4. **Decide what belongs on the host,** from the full diff, the focused diff and the history
   together, never from commit subjects:

   | Collected change | Treatment |
   |---|---|
   | Reviewed implementation or documentation work | Candidate for integration |
   | Import snapshots and provenance bookkeeping | Stays in the ref and the audit package |
   | A sync change the host already has | Confirm the host equivalent, then leave it out |
   | Mixed or uncertain | Stop and propose a split |

5. **Present for integration approval:** target branch and HEAD, the candidate, exactly what
   is included and excluded. Send approval doesn't cover this, and integration approval
   doesn't cover a push.
6. **Integrate:** fast-forward only when the candidate descends from the approved host HEAD
   and everything in between belongs; otherwise apply only the reviewed commits. Record what
   was excluded and any rewritten commit IDs.
7. **Keep withheld work visible.** Collection points advance when a package is published, not
   when the host accepts it, so a withheld edit won't appear in the next collection. List it.
8. **The human pushes.**

JWA-2906 is the worked example: its candidate is `refs/sandbox/JWA-2906-R1`, and only the code
was integrated; the round's `sandbox-logs/` stayed with the audit record.

---

## Keeping track

**The controller only knows tasks.** A campaign is our convention: one workspace with several
tasks registered to it, one per ticket.

**A task's private state** (`~/.local/state/pera-sandbox-tasks/<TASK>/`):

| Item | Holds |
|---|---|
| `record.json` | The task definition and its digest; the **image ID** it pins; each repo's branch and HEAD at registration; the source heads; every plan and the active one; `executionHeads` and `lastRound` (where the last import left each repo); `collectionHeads` and `lastCollection`; `version` (2 once `--handoff` is used). Written only by the controller |
| `plans/<id>/` | One fingerprinted plan per prepared send: `plan.json` plus a per-repo file |
| `collections/<id>/` | One per complete package: per-repo artifacts, `collection.json`, `provenance.json` |
| `task.lock` | Makes operations on the task run one at a time |

**Two ways to see it:**

- `sandbox-task.sh status <TASK>` — live state per repo: planned, partly applied, applied,
  dirty, running or recovery-required, reported separately; damaged imported inputs
  separately from Git dirt; for version 2 tasks, a `context` report comparing each declared
  document with its last applied observation. It never presents an old HEAD as fresh while
  an agent is running.
- **The handoff ledger** — a readable index the lead commits in the host task folder. After
  each prepare, apply, run and collection the operator returns an entry with the plan ID, the
  human's approval reference, receipts, checksums, review passes and integration outcome. It
  indexes the private state; it doesn't replace it.

---

## What every operator command has in common

Every `sandbox-task.sh` and `sandbox-round.sh` command:

- **Runs in a throwaway container** from the task's pinned image: `--network=none`,
  `--cap-drop=all`, with the tool code mounted read-only from the scaffold
  (`sandbox-task.sh:253-265`, `sandbox-round.sh:198-230`). Output is JSON.
- **Checks first:** the image tag still resolves to the pinned image ID; each workspace repo
  is on its registered branch; the last import is still an ancestor of that branch's HEAD.
  After a rebuild, the first check fails and the task is refused until the old image is
  tagged again.
- **Runs Git defensively** (`rounds.js:249-310`): through a private, empty Git directory that
  shares the repo's objects and refs as data only. It never loads the repo's config, hooks or
  filters (`core.hooksPath=/dev/null`, no system or global config, no attribute files,
  `autocrlf=false`, `protocol.allow=never`), and works on a copy of the index. It refuses
  linked worktrees, alternate object stores and symlinked object directories.
- **Won't touch a busy workspace:** it refuses while any running container mounts it.
- **Never clears a refusal by force.** Don't stash, reset, kill another session, or delete a
  journal or lock to make a command proceed; find the cause.

`sandbox-round.sh inspect` is the low-level health check behind `status`. It reports HEAD,
branch, clean / dirty / busy / recovery-required, and an inventory of imported rounds, each
**re-verified byte-for-byte** against its manifest (`rounds.js:837-859`), so an edited brief
snapshot shows. With `--path` it returns blob ID, mode, size and SHA-256 for named files —
the hash, never the contents. It does not read or judge the agent's code.

---

## Claude Code and Copilot compared

Both use the same image, workspace, instructions, firewall lockdown, credential purge,
capability drop, wrappers and send / collect / review flow. Switch by using `run-copilot`
and its own volume; one agent per workspace at a time.

| | Claude Code | Copilot CLI |
|---|---|---|
| Sign-in | Subscription login in `pera-claude-config` | Your Copilot-Requests-only token, as a podman secret |
| Network | Anthropic's addresses only | Copilot's hosts plus GitHub's published ranges, so **github.com is reachable**: it shares the address pool |
| Per-command sandbox | Bubblewrap on every command, required by the managed policy | **None yet.** The CLI's own experimental sandbox is backlog S-13 |
| Command guards | Managed deny rules | `--deny-tool` / `--deny-url` flags plus a root-owned hook; they match spellings, so `git -C . push` passes a rule for `git push` |
| What stops a push | Network, no remotes, deny rules | Mainly the token, which can't write |
| Model | Opus 5.5 | Seeded to `claude-opus-5.5` on first run; `/model` changes it |

For supervised runs the owner accepted this difference; for unattended runs it matters
(Security and IT sign-off, finding C5, is outstanding).

---

## Changing the scaffold itself

Work in `C:\work\pera\claude-sandbox`, in its own session, never mixed with ticket work.
AGENTS.md is the rulebook. The verification ladder, cheapest rung first:

1. `./verify-scaffold.sh` after every edit — line endings, syntax, JSON, no personal paths,
   every isolation invariant present. Clean is `25 passed, 0 failed, 2 skipped`.
2. Disposable-container regressions inside WSL: `verify-firewall.sh`, `verify-rounds.sh`,
   `verify-assembly.sh`, `verify-startup.sh` (`--baked` checks a rebuilt image). Never against
   a real workspace or a running session.
3. Rebuild and prepare: expensive; only when the change needs it.

There is no CI. "Edited, unverified, needs a container run" is a correct report.

---

## Known gaps

| Gap | Backlog |
|---|---|
| Each rebuild installs the current CLI releases | S-3 |
| No list of tasks, no retire, no move to a rebuilt image | S-6, S-11 |
| `--continue` can resume another task's session | S-12 |
| Copilot has no per-command sandbox | S-13 |
| Launch and prepare commands are copied by hand | S-14 |
| Workspace refresh, build-context refresh and evidence export are pasted recipes | S-15 |
| Operator and reviewer roles are prose, not definitions | S-16 |
| Security and IT sign-off for unattended runs | C5 (deferred) |

---

## Where the older guides drifted

Found while writing this guide, against `main` at `ddfa351`. None is fixed yet.

| Where | Says | Actually |
|---|---|---|
| README "Session lifecycle", QUICKSTART:534, FAQ:52 | Resume with `run-agent --continue` | All workspaces share one session folder; resume by session ID (S-12) |
| README header | Security status link to `#open-items-as-of-2026-09-23` | The section is now "Open items, as of 2026-09-27" |
| README §3 | Shows two `prepare` commands back to back, the second without `PREPARE_PROFILES` | One command, with `-e PREPARE_PROFILES` before the image name |
| README §1, QUICKSTART step 1 | Overlays `prj/.github` and `prj/.agents` | Only the two `prj/.agents` skills are required; `.github` is copied if present (`new-sandbox.sh:112-118`) |
| README, QUICKSTART | Commands assume `~/pera-sandbox` | Any `SANDBOX_ROOT` works; one workspace per campaign is the recommended layout |
| `new-sandbox.sh` closing message | "Review from Windows: `\\wsl$\centos-9\…`" | Review reads the collected package; the clones are agent-controlled (README's own review model) |
| QUICKSTART step 4 | The human launches | The human launches interactively, or approves a headless launch the lead runs |
| OPERATOR "Send a committed brief", before `ddfa351` | Write, then commit | The human reviews the brief before it is committed (now in OPERATOR) |
