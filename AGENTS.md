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
| Network locked to the AI provider's endpoints | Full network access |
| Never push; repos have no remotes | You are outside any repo by default; `prj`/`Documentation` next door have real remotes |
| Unit tests only, no DB | No tests here at all — this directory has no build |
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
- **Nothing here builds or runs on the host.** The shell scripts execute inside WSL or inside
  the container. `New-Sandbox.ps1` is the only file intended to run on Windows, and it is
  unsupported drift — see `README.md`.
- **This directory is its own git repository** (standalone, `main`, no remote yet — see
  Promotion). Commit as you go, in small reviewable steps; a change that cannot be described in
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
  is an escape hatch.
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
  `--deny-tool` / `--deny-url` / `--disable-builtin-mcps` flags are the tool-layer barrier that
  compensates for GitHub's IP ranges being unavoidably reachable in Copilot sessions.

## Verifying a change

Most of this scaffold cannot be checked by reading it. Work down this ladder and stop at the
cheapest rung that actually covers your change.

1. **Static checks — no container.** Run `./verify-scaffold.sh`. It checks line endings, shell
   syntax, JSON validity, the absence of personal paths, and that every isolation invariant
   above is still present in the source. **Run it after every edit**, and expect a clean run to
   report `19 passed, 1 failed` — S7 fails on purpose until findings I1/I2/I3 are fixed, and
   S11 warns until E1 is. A *new* failure is yours.
2. **Container, already built.** An image (`localhost/pera-sandbox`) and an assembled, warmed
   sandbox (`~/pera-sandbox` inside the `centos-9` WSL distro) already exist, so in-container
   assertions run in seconds rather than after a 30–60 minute prepare. Anything touching the
   firewall, capabilities, or the purge belongs here.
3. **Full rebuild + prepare — 30–60 minutes.** Only for Dockerfile changes or a new Maven
   profile. Say so rather than doing it unasked.

Nothing in this repository is currently checked by CI or by any script. Until
`VERIFY-ASSERTIONS.md` is implemented, "verified" means a human ran something and watched it.

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

An audit of this scaffold (2026-09-09) lists 27 findings with file and line references, ranked,
with a suggested order. Ask for the current link rather than re-deriving its contents. The two
prior point-in-time reports are in the repo copy alongside the scaffold:
`Agent_Sandbox_Findings_2026-07-28.md` and `Agent_Sandbox_Verification_2026-08-05.md`.

If you are picking up a finding, the audit says which tier it is in: some are mechanical and
safe to complete unsupervised, some need a written spec and a human reviewing the diff, and the
firewall and settings-precedence items are explicitly not delegable without review.
