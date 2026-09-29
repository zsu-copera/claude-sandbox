# Operating model and portability

**Status:** written 2026-09-29 as a reference for the owner and for teams considering the
sandbox. It describes the current design, checked against the scripts, `OPERATOR.md` and
the live task records on that date. It proposes a direction for generalizing but makes no
decisions, and nothing here changes an isolation invariant.

## 1. How work moves in and out of a locked-down sandbox

Nothing passes through a locked-down container. Lockdown is a firewall on one container's
network namespace, and it is one-way for that container. The workspace (for example
`~/pera-sandbox-eep24` in WSL) is an ordinary directory that each container mounts at
`/workspace`. The operator works on it only while no container is running, so the cycle is:

```
agent stops -> operator imports or collects -> a new container starts and locks down again
```

"Lockdown is one-way" therefore costs nothing: every launch is a new container.

**In: `sandbox-task.sh send`.**

1. The ticket lead commits a brief in the host `prj` or `Documentation` checkout.
2. `send TASK` exports only the selected committed `.md`/`.txt` blobs into a packet
   outside the workspace. Uncommitted edits and branch ancestry are never taken; a script
   travels as a document (OPERATOR, "Carry a script as a document").
3. It previews the import and returns a plan ID binding the image ID, both target heads
   and branches, the source commits and the packet bytes.
4. After the designated human approves, `send TASK --apply PLAN_ID` commits a snapshot
   under `sandbox-rounds/<task>/<round>/` and a provenance commit on the existing sandbox
   branch. Original files, branches and caches are unchanged.
5. The human launches `run-agent`, which locks down again, and gives the agent the round
   README path. `run-agent --resume <session-id>` continues the earlier conversation.

**Out: `sandbox-task.sh collect`.** Once the agent has committed and stopped, `collect`
mounts both repositories read-only and writes a private package under
`~/.local/state/pera-sandbox-tasks/<task>/collections/`: per-repository manifests,
`changes.patch`, `work.patch`, `history.bundle` where there are new commits, and checksums.
The lead verifies the bundle in the host repository, fetches it into
`refs/sandbox/<task>-<round>` and integrates with a separate approval
(OPERATOR, "Harvest and integrate reviewed work").

**Session evidence** (the Claude JSONL in the config volume) leaves by a separate recipe
that exports selected files, never the volume (OPERATOR, "Claude Code session evidence").
A collection holds commits, not proof that tests ran.

Export, import, inspection and collection all run in throwaway containers from the pinned
image with `--network=none` and `--cap-drop=all`. The import container ignores the
repository's hooks and filters and never mounts auth volumes, credentials or the Maven
cache.

**What cannot come in this way.** New dependencies need a network-open prepare in a
separate container (section 2). Host Git commands against the workspace are not a
substitute for the controller: the workspace's hooks and configuration are
agent-controlled.

## 2. What warming a profile means

A Maven profile selects the modules that build: `agencyWWW` builds `shared`, `common`,
`agency` and `agencySecurityRealm`, and `memberWWW` builds `member`. Warming runs
`prepare.sh` once in a prepare container with the firewall open and the Nexus
credentials staged. It has no agent login volume. In order, it:

1. builds a node dist tarball from the Nexus npm packages for each `<nodeVersion>` pinned
   in the module poms, because Zscaler blocks nodejs.org;
2. runs the root `npm ci` for the Grunt tooling;
3. runs `mvn clean install -P <profiles> -DskipTests` with the credentialed
   `settings.xml`, which fills `/workspace/.m2` and, through frontend-maven-plugin, gives
   each built module its own `node/` and `node_modules/`;
4. deletes `_remote.repositories` from the cache, so it resolves offline after
   `run-agent` purges the credentialed settings.

The result lives on the workspace, not in the image. It survives agent launches and image
rebuilds, and is lost only when the workspace is reassembled. A module that was not
warmed fails offline. That is why member work needs a `memberWWW` workspace. The
`profiles` field in a task record is a label, not evidence of what is cached.

## 3. Sessions and roles

OPERATOR's role table is the rule. In practice it gives two agent sessions for ticket
work:

| Session | Where | Responsibility |
|---|---|---|
| Ticket lead, persistent | Host, `C:\work\pera` | Briefs, commits and integration; the only agent writer to the host checkouts. Runs the **operator helper** as a subagent for registration, send preparation, status and collection, and a **fresh reviewer subagent** for each review pass, given the evidence but not the lead's reasoning. |
| Sandbox implementer | Inside the container, launched by the human | Implements the brief and commits. Talks to the lead only through imported briefs and collected commits. |
| Scaffold maintenance | Host, `claude-sandbox` | Changes to the sandbox itself. Not part of ticket flow. |

The human approves each exact plan, launches the sandbox session, approves integration
and pushes. The one hand-carried item is the launch prompt, because launching is a human
gate.

A separate operator *session* would add relaying of plan IDs and paths, which OPERATOR
explicitly avoids, and would gain nothing: the role split is working discipline, not an
authentication boundary. A reviewer from a different vendor or model, as used for
JWA-2906, gives more independence than one Opus instance reviewing another.

## 4. Task registration and state

`register --config FILE` takes a closed JSON schema: task ID, workspace, image, profiles,
and for each repository its source path, branch, audit base and brief list. It checks
that each audit base is an ancestor of the workspace HEAD. It then writes
`~/.local/state/pera-sandbox-tasks/<task>/record.json` (mode 600, directory 700) holding:

| Field | Meaning |
|---|---|
| `config`, `configDigest` | The definition. A changed definition needs a new task ID. |
| `imageId` | The image's sha256, not its tag. |
| `registered` | The branch and HEAD of each workspace repository at registration. |
| `sourceHeads` | The source branch heads. |
| `plans`, `activePlan` | Send plans. Each ID is a hash of the exact operations; only that plan can be applied. |
| `executionHeads`, `lastRound` | The head after the last applied import, which the work diff starts from. |
| `collectionHeads`, `lastCollection` | Advanced only when a complete, checksummed package is published. The next collection starts there. |
| `version` | 1 for a legacy task; 2 once `--handoff` opts into context tracking. |

**How it works.** A bash wrapper runs `tools/tasks/*.js` inside the pinned image, in
network-less, capability-free containers. Output is JSON, and `task.lock` serializes
operations. Every command after registration checks that:

- the image tag resolves to `imageId`;
- each workspace repository is on its registered branch;
- the recorded execution base is an ancestor of its HEAD.

**What affects a record.**

- **Resetting the workspace.** `new-sandbox.sh --force` refuses while any record names
  the workspace (tests T15 and T16). A new task needs a new `SANDBOX_ROOT`.
- **No retire command (BACKLOG S-6).** A finished task keeps its workspace blocked from
  reset. `~/pera-sandbox` is named by both EEP-24 and JWA-2906.
- **Deleting a workspace by hand.** The record then points at nothing and its commands
  fail. Published packages and `refs/sandbox/*` refs in the host repositories survive.
- **Rebuilding the image.** The controller refuses with "Registered image changed;
  restore the pinned image before proceeding" when the tag no longer resolves to the
  pinned ID. On 2026-09-29:

  | Task | Pinned image | Workspace | Version |
  |---|---|---|---|
  | EEP-24 | `893d19013d16` | `~/pera-sandbox` | 1 |
  | JWA-2906 | `893d19013d16` | `~/pera-sandbox` | 2 |
  | EEP-24-A11Y | `6fa46c4bb3c3` | `~/pera-sandbox-eep24` | 1 |

  `localhost/pera-sandbox` resolves to `6fa46c4bb3c3`, so EEP-24 and JWA-2906 are refused
  until `893d19…` is tagged again. This is inferred from the source check and these
  values; the controller was not run against those tasks. There is no supported way to
  move a task to a new image.
- **Containers and login volumes.** Records do not depend on them.

**One Claude project for every workspace.** Every root mounts at `/workspace`, so all
sessions share one project directory, `-workspace`, in the `pera-claude-config` volume.
It held 18 sessions on 2026-09-29. `run-agent --continue` resumes the most recent
conversation in that project, which may belong to a different task. Resume a task by
session ID. This follows from how Claude Code keys sessions by working directory; it has
not been tested here.

## 5. Generalizing for other teams

The portable core is the isolation design, the one-way firewall, capability drop,
credential purge, managed policy and startup checks, and the
import -> run -> collect -> review model with its approval boundaries. Most of the rest is
written around PERA:

| PERA-specific today | Generalized form |
|---|---|
| Exactly two repositories, `prj` and `Documentation`, fixed in the controller schema, the round tool's `--repository` option and `new-sandbox.sh` | A configured list of repositories |
| `prepare.sh`: Maven, frontend-maven-plugin, Nexus URLs, the `NPM_FOR` map, the Zscaler node workaround, stripping `_remote.repositories` | Per-stack warm recipes, each with an offline self-check |
| Image: CentOS Stream 9, JDK 17, Maven, Node 22, Chromium | A base image plus a per-team toolchain layer |
| `overlay/CLAUDE.md`, the required skills in `new-sandbox.sh`, the test-runner notes | A template the team completes |
| Windows, WSL `centos-9`, rootless podman, `C:\work\pera` paths | A runtime adapter |
| Anthropic and Copilot allowlists, the corporate CA bundle | Per-provider and per-network configuration |

**Container runtimes.** Docker is a plausible port with work: `--userns=keep-id` is
podman-specific, and bubblewrap inside Docker needs seccomp or AppArmor adjustments. Both
points are from general knowledge and untested here. **No container at all** is a
different product. Claude's own sandbox gives per-command filesystem and network limits
but no one-way firewall and no credential purge. That tier needs its own security review;
it is not a configuration switch.

**Suggested order.**

1. Write down the boundary between the fixed core and the per-team parts.
2. Replace the two fixed repository names with a list. This touches the most code and
   tests.
3. Move build warming into per-stack recipes.
4. Turn the overlay into a template.
5. Pilot with **one** other team before abstracting further. An abstraction designed from
   one example will guess wrong.

## 6. What to ask a team

- **Host and runtime:** operating system; whether WSL2 or Hyper-V is allowed; container
  runtime, and whether rootless; admin rights; proxy or TLS inspection.
- **Repositories:** how many; hosting (Bitbucket, GitHub, Azure DevOps); sizes; Git LFS
  or submodules, neither of which is supported today; branch model.
- **Build:** languages and build tools with versions; package mirrors such as Nexus or
  Artifactory, and how their credentials are issued; which builds and tests run offline,
  and which need databases, browsers or other services.
- **Documentation and briefs:** where requirements live (Jira, Confluence, a
  repository); whether briefs can be committed as Markdown, since intake takes only
  committed `.md`/`.txt`; existing AI guidance files.
- **Agents and policy:** which CLIs and plans (Claude Team or Enterprise, an API key,
  Copilot); whether code may be sent to Anthropic or GitHub; what Security or IT sign-off
  is required, their equivalent of C5.
- **Process:** who approves plans, who pushes, review requirements, and how long run
  evidence must be kept and where.
