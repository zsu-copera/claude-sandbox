# Working on the sandbox scaffold

Loaded as `AGENTS.md` (GitHub Copilot CLI) and via `CLAUDE.md` (Claude Code). This file is
about working **on** the sandbox scaffold. It is not the file that gets deployed into a
sandbox — see the warning below, it matters.

## Read this first: `overlay/CLAUDE.md` is cargo, not instructions

`overlay/CLAUDE.md` is a **payload**. `new-sandbox.sh` copies it into the assembled sandbox as
that sandbox's `CLAUDE.md` and `AGENTS.md`, where it instructs an agent working on the PERA
codebase. If you read it as a description of *your* environment you will be wrong about
everything that matters:

| `overlay/CLAUDE.md` says | Here, on this host |
|---|---|
| Provider-oriented network restrictions | Full network access |
| Never push; sandbox repos have no remotes | This scaffold is its own Git repo; `prj`/`Documentation` next door have real remotes |
| Application unit tests only, no DB | Scaffold assertions and isolated firewall regressions; no application build |
| Platform is Linux (bash) | Windows host; PowerShell primary, bash via Git Bash / WSL |
| `/workspace/prj`, `/workspace/Documentation` | `C:\work\pera\prj`, `C:\work\pera\Documentation` |

Treat `overlay/CLAUDE.md` as a text file you may be asked to edit. Never as your own briefing.

## What this directory is

`C:\work\pera\claude-sandbox` is the **working copy** of the agent sandbox scaffold — the
build definition, egress firewall, entrypoint scripts, and agent-instruction overlay that
together produce an isolated container for autonomous work on the PERA codebase.

There are deliberately two copies:

| Copy | Role |
|---|---|
| `C:\work\pera\claude-sandbox` (**this one**) | Where the scaffold is edited and proven. Kept separate so sandbox work can proceed while `Documentation` and `prj` are checked out for other tickets. |
| `Documentation` repo, branch `claude-sandbox`, at `External-Team/ai-resources/Sandbox-Workspace/claude-sandbox/` | The shared copy other developers consume. Changes are promoted here after they are proven. |

The shared copy is currently **behind** this one. Do not "fix" the scaffold's own docs to point
at the repo path — they name `C:\work\pera\claude-sandbox` on purpose, because that is where a
consumer deploys it.

Read `README.md` for the design and the file-by-file table, `QUICKSTART.md` for the operating
procedure, `FAQ.md` for troubleshooting. Do not duplicate their content here.

## Your environment

- **Windows host.** PowerShell is the primary shell; bash is available through Git Bash and
  through `wsl -d centos-9`. Path separators and line endings both matter (below).
- **Runtime scripts execute inside WSL or the container.** `verify-scaffold.sh` also runs
  in Git Bash on Windows; `verify-firewall.sh` uses WSL/Podman and disposable containers.
  `New-Sandbox.ps1` is unsupported drift, not the supported assembly path.
- **This directory is its own git repository** (standalone, default branch `main`, no remote
  yet — see Promotion). Inspect the current branch before working; E1 is being maintained
  on `fix/e1-firewall-transitions`, round intake on `feat/sandbox-round-imports`, and
  outside-agent task operations on `feat/sandbox-task-operator`, separately from `main`.
  Commit as you go, in small
  reviewable steps; a change that cannot be described in
  one line is usually two changes. `git diff` is the review surface, so leave the tree clean
  when you stop.

## Hard rules

1. **LF line endings, always.** Every `*.sh`, the `Dockerfile`, `dockerignore`, and every
   `*.json` must contain zero CR bytes. `container/*.sh` are `\r`-stripped by the Dockerfile,
   but **`new-sandbox.sh` runs on the host with no such safety net** — a CRLF shebang or
   `set -euo pipefail` fails outright. This has already broken once. If your editor or tool
   writes CRLF, fix it before finishing.
2. **Never introduce a personal path or name.** No `/home/su`, no `Users/su`, no hardcoded
   person as a default. Host-specific values are resolved at runtime or passed in.
3. **Do not weaken an isolation invariant without a human reviewing it.** The list is in the
   next section. These were expensive to get right and several are non-obvious.
4. **Do not edit `prj/.github/copilot-instructions.md`** anywhere. It is generated; regenerate
   it from the canonical file in `Documentation`.
5. **State what you could not verify.** Most changes here cannot be proven without a container
   run. Saying "edited, unverified, needs a container run" is correct and useful. Claiming a
   firewall change works when you did not test it is not.

## Isolation invariants — change only with human review

Each of these is load-bearing, and each has a comment in place explaining why. Read the comment
before touching the code.

- **Capabilities are dropped before the agent starts.** `run-agent.sh` / `run-copilot.sh` exec
  the agent through `setpriv --inh-caps=-all --ambient-caps=-all`. This both takes
  `CAP_NET_ADMIN` away from the agent and is what lets bubblewrap run at all — podman puts the
  firewall's capabilities in the *ambient* set, and bwrap refuses to start when a non-setuid
  binary holds capabilities. Removing it breaks the Claude native sandbox on every Bash call.
- **Lockdown is a one-way door.** `init-firewall.sh open` refuses once the container has locked
  down, and the first successful lockdown pins its domain list in
  `/run/claude-lockdown-domains` (root-owned) so later lockdowns cannot substitute a different
  allowlist. The agent has passwordless sudo for this one script; without both guards that sudo
  is an escape hatch. A root-owned lock serializes operations. Refresh never flushes live
  rules: it swaps an ipset or one jump to a staged per-IP chain. Interrupted initial
  installation also blocks reopening; do not delete its state to recover.
- **Sudo is scoped to `init-firewall.sh`, not `ALL`.** Call sites must use the absolute path
  `/usr/local/bin/init-firewall.sh` — `Defaults secure_path` excludes `/usr/local/bin`.
- **Blocked egress REJECTs rather than DROPs**, so an autonomous agent fails fast instead of
  hanging on TCP timeouts.
- **`prepare.sh` strips `_remote.repositories` from the warmed Maven cache.** Without it the
  cache is present but unusable offline, because the `settings.xml` declaring the repository id
  is credentialed and gets purged by design.
- **`run-agent` / `run-copilot` purge credentials after locking down, not before**, and refuse
  to start if the firewall self-test fails.
- **`sandbox.filesystem.allowWrite: ["/tmp"]`** in `overlay/.claude/settings.json` is required,
  not incidental: Java ignores `$TMPDIR`, so `java.io.tmpdir` stays `/tmp` and the WAR assembly
  fails on a read-only `/tmp`.
- **`gh` is deliberately not installed** in the image, and the Copilot entrypoint's
  `--deny-tool` / `--deny-url` / `--disable-builtin-mcps` flags remain required
  defense-in-depth for reachable GitHub ranges. They and the policy hook have documented
  gaps; do not remove them or describe them as complete no-push enforcement.

## Verifying a change

Most of this scaffold cannot be checked by reading it. Work down this ladder and stop at the
cheapest rung that actually covers your change.

1. **Static checks — no container.** Run `./verify-scaffold.sh`. It checks line endings, shell
   syntax, JSON validity, the absence of personal paths, and that every isolation invariant
   above is still present in the source. **Run it after every edit**, and expect a clean run to
   report `21 passed, 1 failed` — S7 remains an unresolved failure until findings
   I1/I2/I3 are fixed; S3 and S20 skip without shellcheck and VERSION. A *new* failure is
   yours. S11/S12 check source structure, not runtime containment.
2. **Container, already built.** An image (`localhost/pera-sandbox`) and an assembled, warmed
   sandbox (`~/pera-sandbox` inside the `centos-9` WSL distro) already exist, so in-container
   assertions run in seconds rather than after a 30–60 minute prepare. Anything touching the
   firewall, capabilities, or the purge belongs here. Run `bash verify-firewall.sh` inside
   WSL for focused E1 regressions using disposable containers; never run adversarial
   firewall probes against an existing agent session.
   `bash verify-rounds.sh` covers round imports with disposable repositories; do not
   exercise failure recovery against a real task workspace.
3. **Packaging / prepare.** Dockerfile or image-installed script/policy changes require
   a refreshed build context, rebuilt image and new container for deployment. An image
   rebuild does not automatically require another prepare of an existing warmed workspace;
   new build dependencies/profiles or a workspace reset do. Either operation can be
   expensive; do not perform a full rebuild/prepare unasked.

There is no CI gate. Static assertions and focused firewall regressions do not implement
the complete P/A/G/X runtime specification in `VERIFY-ASSERTIONS.md`. Editing a script here
does not update its baked image copy; packaging and real-session rollout are separate steps.

## Persistent task rounds

**The outside agent is the default operator.** Read `OPERATOR.md` when asked to
register a task, send a brief, inspect handoff status or collect work for audit.
Use the task-aware controller and present one concise approval summary; do not hand
the user a chain of shell variables or hashes to copy.

Use `sandbox-task.sh` for the normal workflow and `sandbox-round.sh` from this trusted
scaffold for low-level diagnosis and operator-controlled brief intake.
It exports explicitly selected committed documents and imports append-only snapshots,
not external branches, into an existing warmed task repository. Do not reset, re-clone,
rewarm, stash changes or overwrite canonical instructions merely to advance a review round.
Packets and recovery journals stay outside the workspace; only the imported snapshots
are visible to the agent. Read QUICKSTART for the command sequence and recovery contract.

Keep import containers network-disabled and unprivileged, with only the selected repo
and private recovery state writable. Do not replace this with host Git operations that
can execute hooks or filters from agent-controlled repository configuration.
Task definitions and approval plans belong in private operator state, never in the
agent workspace. Do not infer an audit baseline from the currently checked-out host
branch, automatically merge collected work, or treat a partial two-repo operation
as complete. Registration and collection do not authorize a real task run.

## Promotion, and an open decision

As of 2026-09-09 this directory is a standalone git repository with its own history. It has
**no remote**, so nothing here is backed up off this machine yet.

The shared copy other developers consume is still the one in `Documentation`, on branch
`claude-sandbox` under `External-Team/ai-resources/Sandbox-Workspace/claude-sandbox/`, and it is
behind. **Which of the two becomes the source of truth is not yet decided** — the options are a
real remote for this repo with the Documentation copy retired or reduced to a pointer, or
keeping Documentation as the distribution point and treating this as an upstream. Do not assume
one; ask.

Until that is settled, if you are asked to help promote:

- Both copies now have a `.gitattributes`, but they differ in scope: Documentation's is
  selective (scripts and JSON pinned to LF, human-facing docs left at the platform default);
  this one is uniform LF. A promotion that copies this folder over that one replaces the rule
  as well as the files — deliberate or not, notice it.
- Exclude `.git`, `.gitattributes`, `.gitignore` and `.claude` from any file-level copy.
- No branch in `Documentation` other than `claude-sandbox` contains a single file under
  `Sandbox-Workspace/`, so sandbox commits there cannot conflict with ticket work.

## Known findings

Start with `SECURITY-REVIEW.md`: it links the original 27-finding audit, records the
reconciliation plus N1/N2, and tracks E1's implementation commits, evidence and outstanding
deployment. Keep original findings distinct from later remediation; do not re-audit from
scratch or mark the deployed image fixed based only on source-mounted regressions.
`VERIFY-ASSERTIONS.md` distinguishes implemented checks from planned lifecycle coverage.
The two prior point-in-time reports are in the shared Documentation branch alongside
the scaffold:
`Agent_Sandbox_Findings_2026-07-28.md` and `Agent_Sandbox_Verification_2026-08-05.md`.

If you are picking up a finding, the audit says which tier it is in: some are mechanical and
safe to complete unsupervised, some need a written spec and a human reviewing the diff, and the
firewall and settings-precedence items are explicitly not delegable without review.
