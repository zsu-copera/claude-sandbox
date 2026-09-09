# Quick Start — PERA Agent Sandbox (Claude Code / GitHub Copilot CLI)

Spin up an isolated environment where a coding agent — **Claude Code** or **GitHub
Copilot CLI** (your choice at step 4; both drive Claude Opus 4.8) — works **autonomously**
on a disposable copy of the PERA codebase. The agent cannot touch your real working
copies, cannot push, cannot reach internal databases, and its network is locked to its
own AI provider's endpoints. You review its local git commits afterward and push only
what you approve.

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

### 2. Build the image — inside WSL (`wsl -d centos-9`)

```bash
cd ~/pera-sandbox
podman build --secret id=npmrc,src=.secrets/npmrc -t pera-sandbox -f .devcontainer/Dockerfile .
```

~5–10 min. Only needed once per machine, or when the Dockerfile changes. Agent CLIs
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

Copilot sessions allow GitHub's IP ranges (its API shares them — unavoidable), a wider
surface than Claude's Anthropic-only lockdown; pushes to GitHub are blocked by deny
rules and absent credentials, not the network. See README §4b for the full picture and
when to prefer `run-agent` (short version: maximum-paranoia overnight runs).

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

Then re-run step 3 (prepare). The image (step 2) and both agent logins (Claude + Copilot
volumes) survive. Any un-harvested agent commits are lost — review first.

## Things to know

- **Exiting the agent ≠ losing the sandbox.** The container and firewall vanish on exit
  (nothing keeps running); the workspace, commits, caches, and logins all persist. Re-run
  the step-4 command to start again — `run-agent --continue` (Claude) or
  `run-copilot --continue` (Copilot) resumes the previous conversation.
- **Treat sandbox contents as unreviewed input** until they pass review: inspect with
  `git diff`, don't run builds or scripts out of `~/pera-sandbox` on the host, don't open
  it in an IDE that auto-runs tasks. The sandbox repos have no git remotes — that's
  intentional.
- **`run-agent` / `run-copilot` refuse to start** unless the firewall self-test passes:
  the agent's own provider endpoints reachable AND everything else refused. If it aborts,
  the lockdown failed — investigate before running the agent.
- **Unit tests only.** The dev AS400/Oracle databases are unreachable *by design*.
  DB-dependent verification happens after review, on-network.
- **The agent cannot push.** Commits stay local until a human fetches and pushes them.
- **"Connection refused" inside a session is the firewall working**, not a bug. If the
  agent genuinely needs a new dependency, re-run step 3 (network open) to fetch it.
- **Lockdown is one-way.** Once a container has locked down it cannot be reopened: the
  agent has passwordless sudo for `init-firewall.sh` only, and the script refuses `open`
  and pins the allowlist its first lockdown committed to. Step 3 (prepare) is a separate
  container, so the fetch-a-dependency path above still works. Need an open network in the
  same container? Start a fresh one.
- The sandbox instructions (`CLAUDE.md` for Claude, `AGENTS.md` for Copilot — same
  content) are auto-loaded by the agent and already explain all of this — you don't need
  to repeat it in your prompts.
- **Login doesn't persist between runs?** Recreate the affected auth volume and log in
  once more: `podman volume rm -f pera-claude-config` (Claude) or
  `podman volume rm -f pera-copilot-config` (Copilot) — see README "Login not
  persisting?" for why.
