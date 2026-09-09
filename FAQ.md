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
Whichever you're licensed for; both drive Claude Opus 4.8 against the same sandbox and
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
Note the container started by VS Code does NOT lock the firewall for you — run
`sudo init-firewall.sh lockdown` (plus the Copilot domain set if applicable) before
letting an agent loose from a VS Code terminal.

## Running & sessions

**I exited the agent — is the sandbox gone?**
No. The container and its firewall vanish (nothing keeps running on your machine), but
the workspace, commits, uncommitted edits, build caches, and logins all persist. Re-run
the same command to start again; `run-agent --continue` / `run-copilot --continue`
resumes the previous conversation.

**How do I start over with a fresh copy of the code?**
Harvest anything you want to keep first, then `new-sandbox.sh --force` + re-run prepare.
The image and both agent logins survive; the workspace (including un-harvested commits
and the `.m2` cache) does not. This also picks up whatever branch your Windows working
copies currently have checked out.

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
Advanced shortcut: keep the existing warmed sandbox and switch its branch from the host
(`git -C ~/pera-sandbox/prj fetch /mnt/c/work/pera/prj <branch>:<branch>` + checkout) —
prepare stays skippable as long as poms/lockfiles/nodeVersion pins didn't change and the
task stays in warmed modules. Only do this when the previous task was cleanly harvested;
a wrong guess fails fast with "connection refused" and you just run prepare then.

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
network beyond its provider's endpoints. What lands in the sandbox is inert data until a
human reviews and merges it. Corollary: treat sandbox contents as unreviewed input —
review via `git diff`, don't run builds from it on the host.

**Can the agent see git history / read old commits?**
Yes — the full history of the working branch, deliberately: `git blame`, prior-conversion
diffs, and revert context are part of how conversion work gets verified (Phase-8 legacy
deletion relies on revertability). The clone is `--single-branch`, so other branches'
objects aren't in the sandbox at all. If old commits contain retired secrets, rotate
them — they're equally present in every dev machine's clone, not a sandbox-specific
exposure.

**Can the agent push code anywhere?**
Not by design, with layered barriers: the sandbox repos have no git remotes, `git push`
is deny-ruled for both agents, Bitbucket is firewalled off in all sessions, and the
container holds no git credentials or SSH keys. Copilot sessions can technically reach
GitHub's IP space (its API shares those IPs — unavoidable), which is why Copilot
additionally gets `git push`/`git remote`/`gh` deny rules and a disabled
github-mcp-server. Full analysis: README §4b.

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
takes `CAP_NET_ADMIN` away from the agent at the same time. Verified: bwrap runs, and Bash
tool calls work.

**A build fails under the native sandbox with "Read-only file system". Why?**
Java ignores `$TMPDIR`. The sandbox makes only the working directory and a session temp
directory writable, and points `$TMPDIR` at the latter — but `java.io.tmpdir` defaults to
`/tmp` regardless, so jansi's native-library extraction and the WAR plugin's staging both
write to a read-only `/tmp` and the `agency` WAR assembly dies. `overlay/.claude/settings.json`
therefore sets `sandbox.filesystem.allowWrite: ["/tmp"]`. Don't remove it: without it the
build fails every time and only recovers if the agent happens to retry unsandboxed.

**Why is the image CentOS and why does everything come from Nexus?**
Zscaler on this network blocks Debian mirrors, nodejs.org, registry.npmjs.org, and most
direct downloads (it kills full downloads even where small probes succeed). CentOS
mirrors + EPEL + the internal Nexus proxies are the allowed channels. Baked-in corp CAs
handle the TLS interception. Details: README "Environment assumptions".

## Git & harvesting

**Which branch is the agent's work on?**
The branch your working copy had checked out when you assembled the sandbox — check with
`wsl -d centos-9 -- git -C /home/su/pera-sandbox/prj branch --show-current`.

**Do I need to be on a particular branch to harvest?**
No. `git fetch <sandbox> <branch>:review/agent-work` only creates a ref; your checked-out
branch matters only at the final merge/push step. Same-branch (the normal case) works
identically — and if you haven't committed locally since assembly, integration can be a
clean `git merge --ff-only review/agent-work`.

**Why the three-dot diff (`branch...review/agent-work`)?**
It diffs from the merge-base — exactly what the agent changed — even if your local
branch gained commits while the agent worked. Two dots would mix in changes the agent
never saw.

**The agent changed files in Documentation too — one harvest or two?**
Two: `prj` and `Documentation` are independent repos in the sandbox just like on your
machine. Repeat the fetch/review against `.../pera-sandbox/Documentation`.

**I reset the sandbox and lost commits. Recoverable?**
No — `--force` deletes the workspace including its git objects. Harvest before every
reset. (The reflog trick doesn't help: the entire repo is gone, not just the ref.)

## Troubleshooting

**Login doesn't persist between container runs.**
Recreate the affected volume and log in once more: `podman volume rm -f
pera-claude-config` (Claude) or `pera-copilot-config` (Copilot). Root cause: a volume
first created by a container without `--userns=keep-id` is unwritable — details in
README.

**Copilot: "sign in error" after authorizing in the browser.**
Should be fixed (the firewall now allowlists GitHub's published IP ranges — GitHub's
load balancer rotates IPs faster than per-host snapshots can track). If it recurs, run
the session again — and check `run-copilot`'s startup output for the
"could not fetch api.github.com/meta" fallback warning.

**Copilot: "system vault is not available — store in plain text?"**
Answer yes. Containers have no OS keyring; the token lives in the `pera-copilot-config`
volume at the same protection level as every other credential on your machine
(`~/.m2/settings.xml`, `.npmrc`). Revoke server-side (GitHub → Settings → Applications)
if a machine is ever compromised.

**`run-agent`/`run-copilot` aborts with a firewall error before the agent starts.**
Working as intended: the lockdown self-test failed (provider endpoint unreachable, or —
worse — the negative probe found open egress). Don't bypass it; investigate. First
checks: is WSL networking up (`curl` from centos-9 directly), did Zscaler change
behavior, does `podman run` have `--cap-add=NET_ADMIN --cap-add=NET_RAW`?

**Maven build fails wanting `.secrets/settings.xml` during prepare.**
`run-agent`/`run-copilot` purge `.secrets/` at every start (by design). Re-stage before
re-running prepare or rebuilding the image: copy your `~\.m2\settings.xml` and `~\.npmrc`
back into `~/pera-sandbox/.secrets/` (or just re-run `new-sandbox.sh`).

**`ng build` segfaults / Angular builds die silently.**
You're probably not in the sandbox container (its image ships the official node binary
specifically because the dnf/RHEL node build segfaults on Angular's build pipeline). On
any RHEL-family machine outside the sandbox: install official node binaries, don't use
`dnf install nodejs`.
