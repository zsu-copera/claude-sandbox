# Phase 3 spec: Claude inner sandbox (E2/E3), guarded startup (E5), next-session integrity (N5)

**Status:** approved by the owner 2026-09-24 with the recommended option on every
decision (§5); implemented on `feat/phase3-inner-sandbox-startup`, **not deployed**. §9
records the decisions and every place the implementation departs from or adds to this
text. This is firewall-adjacent and settings-precedence work: under `AGENTS.md` it is not
delegable without review, and the implementation diff needs a second review.

## 1. Goal

The unattended tier ([Containment decisions](../SECURITY-REVIEW.md#containment-decisions-2026-09-23))
requires that the agent cannot weaken its own mandatory policy, **in this session or the
next one**. The outer container, the firewall (E1/E6/N4) and the Copilot PAT (N3) are
unchanged; this phase is about Claude's inner bubblewrap sandbox and about how sessions start.

Supervised runs are unaffected in threat tier. They gain the same protections.

## 2. What was established (2026-09-23, disposable `--network=none` containers)

| Fact | Evidence |
|---|---|
| Baked Claude CLI is **2.1.280**, installed as `vscode` under `~/.local` (agent-owned inside the container, pristine in the image) | `readlink`, `ls -l` in the image |
| The staged Claude tarball in `/workspace/.agent-cli/claude-local.tgz` holds **2.1.269 and 2.1.274**: older than the baked CLI, yet `run-agent` unpacks it over `$HOME` and prefers it | `tar -t` of the workspace tarball |
| Baked Copilot is root-owned under `/usr/local/lib/node_modules`; the staged Copilot under `/workspace/.agent-cli/copilot` is preferred by `run-copilot` | `ls -l`, `run-copilot.sh` |
| The CLI reads `/etc/claude-code/managed-settings.json` and a `managed-settings.d/` drop-in directory; a file that does not parse **refuses startup** (fails closed) | binary strings; [managed settings docs](https://code.claude.com/docs/en/managed-settings.md) |
| Managed settings win for scalar keys; **lists merge across all scopes** | [settings docs](https://code.claude.com/docs/en/settings.md), "Lists merge instead of overriding" |
| `sandbox.failIfUnavailable: true` refuses to start without a sandbox; `sandbox.allowUnsandboxedCommands` defaults to **true**, and `false` makes the CLI ignore `dangerouslyDisableSandbox` | schema text in the binary; [sandboxing docs](https://code.claude.com/docs/en/sandboxing.md) |
| Deny rules and the sandbox still apply under `bypassPermissions` | [permission modes docs](https://code.claude.com/docs/en/permission-modes.md) |
| Managed-only locks present in 2.1.280: `allowManagedPermissionRulesOnly`, `allowManagedHooksOnly`, `allowManagedMcpServersOnly`, `allowManagedDomainsOnly`, `sandbox.filesystem.allowManagedReadPathsOnly` (plus `strictKnownMarketplaces`) | binary strings, docs |
| **No managed-only lock** exists for `sandbox.excludedCommands` (which run outside the sandbox), `sandbox.filesystem.allowWrite`, `sandbox.bwrapPath`, `enableWeakerNestedSandbox`, `enableWeakerNetworkIsolation`, or the command-running keys `statusLine`, `apiKeyHelper`, `proxyAuthHelper`, `awsCredentialExport`, `awsAuthRefresh`, `gcpAuthRefresh`, `otelHeadersHelper`, `processWrapper` | binary schema |
| An **undocumented** `CLAUDE_CODE_MANAGED_SETTINGS_PATH` hands the process "a managed-settings directory explicitly" | binary strings; the docs say no such variable is documented |
| The Claude config volume holds a server-managed settings cache (`remote-settings.json`, currently `[]`) and `policy-limits.json`. When several managed sources exist the CLI **selects one** and reports the rest as skipped | volume keys (read-only); docs "Read the source in /status" |
| `/workspace/.claude/settings.json` (keys `permissions`, `sandbox`) and the volume's `settings.json` (keys `model`, `skipDangerousModePermissionPrompt`, `theme`, `tui`) are agent-writable and persist; no `.mcp.json`; no MCP servers in `.claude.json` | read-only key listing |

Not established: the effective settings of a live session. Everything above is static or
documentary. §6 lists the live observations that must precede any claim that E2/E3 are fixed.

## 3. New finding N5: agent-writable inputs to the next session

| # | Severity | Location | Issue |
|---|---|---|---|
| N5 | 🟡 MEDIUM (unattended tier; accepted residual while a human reviews every session) | `/workspace/.agent-cli`, `/workspace/.claude`, the `pera-claude-config` volume | Three stores persist between sessions and are writable by the agent. A session can leave behind (a) a modified CLI that the next launch runs, (b) lower-scope settings that run commands outside bubblewrap (hooks, `statusLine`, `apiKeyHelper` …, MCP servers), or loosen it (`excludedCommands`, `allowWrite`, `bwrapPath`, `enableWeaker*`), or (c) a server-managed settings cache that displaces the managed file. |

Managed settings alone cannot close (a) or most of (b). E2 as originally written ("make
mandatory policy non-writable") is necessary but not sufficient.

## 4. Design

### 4.1 Managed policy (E2/E3)

Bake `container/claude-managed-settings.json` to `/etc/claude-code/managed-settings.json`,
`root:root 0644`, directory `root:root 0755`, and create an **empty root-owned
`managed-settings.d/`** so nothing else can supply drop-ins. Proposed content:

```json
{
  "permissions": {
    "deny": ["Bash(git push)", "Bash(git push *)",
             "Read(//workspace/.secrets/**)", "Read(//home/vscode/.claude/**)"]
  },
  "allowManagedPermissionRulesOnly": true,
  "allowManagedHooksOnly": true,
  "allowManagedMcpServersOnly": true,
  "strictKnownMarketplaces": [],
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "bwrapPath": "/usr/bin/bwrap",
    "enableWeakerNestedSandbox": false,
    "enableWeakerNetworkIsolation": false,
    "filesystem": { "allowWrite": ["/tmp"], "allowManagedReadPathsOnly": true },
    "network": { "allowedDomains": ["api.anthropic.com"], "allowManagedDomainsOnly": true }
  }
}
```

- `allowWrite: ["/tmp"]` stays an isolation invariant (Java ignores `$TMPDIR`); it moves
  from the overlay into this file.
- `disableBypassPermissionsMode` is **not** set: sessions run in bypass mode by design.
- To confirm during implementation: the exact placement of `strictAllowlist` (seen next to
  the network schema; its text says it denies unlisted hosts "instead of prompting", which
  matters under bypass), whether `bwrapPath` is honoured from managed settings, and whether
  the schema accepts every key above for 2.1.280 (an unknown key is reported, not fatal;
  the check is `claude doctor`).
- The overlay's `.claude/settings.json` shrinks to `{"permissions":{"defaultMode":"bypassPermissions"}}`.
  **S10 moves to the managed file.** It is an isolation-invariant assertion, so that move is
  part of what this review approves.

### 4.2 Environment hygiene

`run-agent` and the `claude` wrapper (§4.4) unset `CLAUDE_CODE_MANAGED_SETTINGS_PATH`,
`CLAUDE_CODE_REMOTE_SETTINGS_PATH`, `CLAUDE_CODE_MOCK_REMOTE_SETTINGS` and
`CLAUDE_CODE_DISABLE_ADMIN_ENV_UNION` before the CLI starts. The launch environment comes from
the operator's `podman run`; this closes it against a mistaken or copied `-e`.

### 4.3 Startup validation of persistent inputs (N5)

`run-agent` runs these checks after lockdown and before the CLI starts, while no agent
process exists. Any failure refuses with exit 78 and names the file and keys; nothing is
silently repaired, so a human sees that something changed.

| Input | Accepted |
|---|---|
| `/workspace/.claude/settings.json` | byte-equal to the baked canonical copy, **or** to the legacy overlay content (by SHA-256) so existing workspaces start |
| `/workspace/.claude/settings.local.json`, `/workspace/.mcp.json` | absent |
| `~/.claude/settings.json` (volume) | top-level keys only from an allowlist: `model`, `effortLevel`, `theme`, `tui`, `skipDangerousModePermissionPrompt`, `outputStyle`, `language`, `viewMode`, `$schema` |
| `~/.claude/remote-settings.json` | absent, or exactly `[]` / `{}` |
| `~/.claude.json` | no `mcpServers` anywhere (belt and braces; managed settings already block them) |

The allowlist is deliberately closed: a future CLI adding another command-running key is
refused until someone reviews it. The real volume passes today.

### 4.4 Guarded startup (E5)

Root-owned wrappers at `/usr/local/lib/pera-sandbox/bin/{claude,copilot}` (0755), first on
`PATH` in the image `ENV`, ahead of `~/.local/bin`:

- `--version`, `-v`, `--help`, `-h` on their own pass straight through.
- Otherwise they require that `/run/claude-lockdown-domains` exists as a root-owned regular
  file, meaning this container locked down, and that `CapInh`, `CapPrm`, `CapEff` and
  `CapAmb` in `/proc/self/status` are all zero. If not, they refuse with exit 78: "start agents
  with run-agent / run-copilot".
- They then exec the real binary by absolute path (see §5, decision 1) after §4.2's unsets.

The launchers already satisfy both conditions, so they need no change beyond §4.2 and §4.3.
Prepare is unaffected: it invokes CLIs by absolute path.

**This guards against operator mistakes, not the agent.** A process in the container can
still exec the real binary by path. Inside a guarded session that gains nothing, because
the lockdown, dropped capabilities and managed policy already apply to it.

**Devcontainer:** declared unsupported for agent work (owner decision). The wrappers refuse
there, because the container holds `NET_ADMIN` and never locked down. With
`failIfUnavailable`, bubblewrap cannot start while capabilities are held, so even the VS Code
extension's bundled CLI, which bypasses `PATH`, refuses rather than running unsandboxed. That
second point is to be observed, not assumed. `devcontainer.json` and the docs say so.

### 4.5 Copilot

Copilot has no inner sandbox, so its persistent config grants nothing beyond the agent's own
privileges. It gets the wrapper and the §5 decision 1 CLI change. Its tool-layer defenses
depend on running an untampered CLI.

## 5. Decisions for the owner

1. **CLI integrity (N5a).** *Recommended: A.*
   - **A. Run only the image-baked CLIs.** Drop the workspace staging from `prepare.sh` and the
     launchers. This is the simplest option and fits D2/D3 (immutable, versioned inputs), but a
     CLI update needs an image rebuild.
   - **C. Keep refreshing, from a separate volume** mounted read-write in prepare and read-only
     in agent runs, with the launcher refusing if the mount is writable. This keeps CLI updates
     without a rebuild, but every documented launch command gains a `-v`.
2. **Tampered inputs.** Refuse (recommended), or restore from canonical and continue.
3. **User-settings allowlist** (§4.3). Accept the list as proposed, or name additions.
4. **Live verification credentials.** §6 needs headless Claude runs, which use a Claude login.
   Either mount the real `pera-claude-config` volume into disposable containers (their
   sessions and tamper probes would then touch the real volume), or provide a throwaway login.
5. **S10 moves to the managed file** (§4.1). This is an isolation-invariant change; it needs an
   explicit yes.

## 6. Verification plan

The source is mounted into disposable containers first; then the baked image is checked
after the rebuild. Nothing runs against a live agent session.

| # | Observation | Pass condition |
|---|---|---|
| L1 | `claude doctor`; `/status` in an interactive probe | Managed source `(file)` selected, nothing skipped, no rejected keys |
| L2 | Headless `-p` probe: a Bash call writes outside `/tmp` and `/workspace`, and a call with `dangerouslyDisableSandbox` | Both refused by the sandbox |
| L3 | Start without dropping capabilities (bwrap cannot run) | CLI refuses to start; no unsandboxed fallback |
| L4 | Project settings seeded with each of: `excludedCommands`, `allowWrite: ["/"]`, `bwrapPath`, a hook, `statusLine`, `apiKeyHelper` | `run-agent` refuses (§4.3). Also recorded: what the CLI does with each when started directly, to document which keys managed settings alone leave open |
| L5 | `CLAUDE_CODE_MANAGED_SETTINGS_PATH` pointing at a permissive directory | Launcher and wrapper remove it; policy unchanged. Also recorded: the effect when set on a direct start |
| L6 | A permissive `remote-settings.json` in a copy of the cache | Launcher refuses |
| L7 | With DNS closed (E6), a sandboxed Bash call and a model round trip | The model is reachable; the proxy resolves through `/etc/hosts`; an unlisted host fails |
| L8 | Wrappers: a bare shell, after lockdown with capabilities still held, and a guarded session; `--version` in all three | Refuse, refuse, run; version always prints |
| L9 | Existing suites: `verify-scaffold` (S10 moved; new assertions for managed-file ownership and mode, the wrapper `PATH` order, and the §4.3 checks), `verify-firewall`, `verify-rounds`, `verify-tasks`, `verify-assembly` | All green |

## 7. Rollout

- **One image rebuild** carries this plus Phase 1's `prepare.sh` identity check and Copilot
  seed. Coordinate with the ticket lead; registrations pin image IDs, so rebuild before the
  next registration.
- Keep `893d19…` and `fda0c678…` for existing records.
- The existing `~/pera-sandbox` keeps working: its project settings match the legacy hash,
  and its user settings pass the allowlist.
- **After the rebuild, E2/E3/E5/N5 count as deployed only after L1–L8 have been observed
  on the baked image.** Unattended runs additionally need C5 (Security/IT sign-off). This
  spec, its evidence and the observed results form that sign-off packet's technical core.

## 8. Out of scope

N1 (hook pattern gaps) stays accepted. So does HTTPS to allowlisted providers. Nor does this
phase add a hostname-level egress proxy, or enforce anything for processes that deliberately
exec the real CLI inside an already-guarded container.

## 9. Decisions and implementation record (2026-09-24)

**Decisions.** The owner took the recommendation on each item in §5:

1. **A**, baked CLIs only.
2. Refuse.
3. The allowlist as proposed.
4. My proposal, since §5 offered none: the tamper probes (L4–L6) are refused before any CLI
   starts, so they need no login and run against synthetic files. Only probes that must
   reach the model (L1, L2, L7) use the real `pera-claude-config` volume, in disposable
   containers, and nothing tampered is ever written to it. Refined and confirmed by the
   owner in §13.
5. Yes, S10 moves.

**Confirmed from the 2.1.280 binary** (static, disposable `--network=none` container):

- `strictAllowlist` sits under `sandbox.network`. With `allowManagedDomainsOnly` the
  network proxy's ask callback blocks unlisted hosts, so it is belt and braces.
- `bwrapPath` is honoured from managed settings (its error text says "Fix the path in
  managed settings").
- Three key groups are **ignored from project settings** but honoured from user
  settings:
  - the command-running keys: `apiKeyHelper`, `awsAuthRefresh`, `awsCredentialExport`,
    `fileSuggestion`, `gcpAuthRefresh`, `otelHeadersHelper`, `processWrapper`,
    `policyHelpers`, `proxyAuthHelper`, `statusLine`, `subagentStatusLine`;
  - `bwrapPath`, `ripgrep` and `socatPath`;
  - the weakening keys, `enableWeaker*` and `allowAllUnixSockets` among them.

  `excludedCommands` and `allowWrite` are honoured from project settings. Both the
  project byte comparison and the user-settings allowlist are therefore needed.

  **Corrected in §14:** a live probe on 2.1.282 ran a project `apiKeyHelper` outside the
  sandbox, so this reading of the binary's lists was wrong for that key at least. What
  the list gates is unknown. Treat every key in it as honoured from project settings; the
  byte comparison is the barrier.
- Settings `env` cannot set `CLAUDE_CODE_MANAGED_SETTINGS_PATH`: it is on the CLI's
  ignored-env list.
- `allowManagedMcpServersOnly` only restricts which *allowlist* applies, and an absent
  `allowedMcpServers` is no allowlist. An explicit empty array admits no servers.

**Departures and additions**, for the reviewer:

| # | Change from the text above | Why |
|---|---|---|
| D-1 | §4.3 checks run **before** the lockdown, not after | Same as N3: a refusal touches neither the network nor the credentials. No agent process exists at either point. |
| D-2 | Managed file adds `"allowedMcpServers": []` and `sandbox.network.strictAllowlist: true` | See the MCP and network points above. |
| D-3 | Managed deny adds `Edit(//workspace/.claude/**)`, `Edit(//home/vscode/.claude/**)`, `Edit(//workspace/.mcp.json)` | The CLI reloads settings mid-session, and lists merge, so an in-session write to project settings could widen `excludedCommands` for the rest of that session. §4.3 only protects the next session. Whether Edit denies also become bubblewrap write denies for Bash is to be observed (L10 below), not assumed. |
| D-4 | `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` is also unset | The CLI's own message says `=0` "loses subprocess isolation". |
| D-5 | Canonical project settings live in `container/claude-project-settings.json`; `overlay/.claude/` is removed | The image build context contains only `container/`, and one file now serves both assembly and the image. |
| D-6 | One wrapper script, installed as `claude` with a `copilot` symlink; it dispatches on its name | One file to review. |
| D-7 | Prepare no longer mounts the Claude config volume (docs) and deletes a stale `/workspace/.agent-cli` | With A it has no use for the login, and it runs repository build scripts with the network open. |
| D-9 | The canonical project settings are **not** shrunk to bypass-only. They keep the old deny rules and the `enabled`, `/tmp` and `api.anthropic.com` sandbox entries, without the old `failIfUnavailable: false` | A workspace assembled from this scaffold but run on the old image (step 2 skipped) would otherwise run Claude with no deny rules and no sandbox, because the old image has no managed policy. On a Phase 3 image these entries are inert: managed scalars win, and the managed-only locks ignore project rules and domains. |
| D-8 | `run-copilot`: `GITHUB_CIDRS=$(...) \|\| true` | Pre-existing bug found by `verify-startup.sh`. Under `set -e`/`pipefail`, a failed `api.github.com/meta` fetch exited the launcher with curl's status, so the documented static-CIDR fallback could never run. |

**Added observation.** L10: in a live session, write to `/workspace/.claude/settings.json`
with the Edit tool and with a sandboxed Bash command. Both must be refused. Record which
layer refused each.

**Not covered by the implementation** (residual, documented):
- Instruction files persist too: the workspace `CLAUDE.md`/`AGENTS.md`, `~/.claude/CLAUDE.md`,
  skills and agents. They can steer the next session but grant nothing the enforced
  policy does not.
- Copilot's `~/.copilot` (for example `mcp-config.json`) is not validated (§4.5).
- Launcher arguments are operator-trusted. A `--settings` or `--mcp-config` passed by the
  operator is not checked.

## 10. Live observations on a test image (2026-09-24)

Image `localhost/pera-sandbox-p3test` (`4ba0c45…`) is the current image (`fda0c678…`)
plus the Phase 3 files, installed root-owned exactly as the Dockerfile installs them,
with the same `PATH`. It is **not the rebuild**: the CLIs are still the baked Claude 2.1.280
and Copilot 1.0.83. Every container ran against a fresh synthetic workspace. Only the
model-reaching probes mounted the real `pera-claude-config` volume, and nothing tampered
was written to it. Transcripts are private host evidence outside the repository.

| # | Observation | Result |
|---|---|---|
| L1 | `claude doctor` in a guarded state | "Managed settings (remote): none configured for this organization", no issues. It does not list file sources or rejected keys, and `/status` was not run. The file's effect is shown behaviourally below, including "claude.ai MCP server blocked by enterprise policy" at startup. **Met behaviourally; the source listing is not observed.** |
| L2 | Guarded `run-agent` session: a Bash write to `/home/vscode`, the same with `dangerouslyDisableSandbox: true`, and a write to `/tmp` | Refused (read-only file system); refused (still sandboxed); allowed. **Pass.** |
| L3 | Real CLI started by path, capabilities held after lockdown, so bubblewrap cannot start | The CLI **started**. Its Bash call failed inside bubblewrap ("Unexpected capabilities but not setuid"), and it reported that bypassing the sandbox is turned off. **No unsandboxed execution. The spec's "refuses to start" did not happen**: `failIfUnavailable` tests availability, not whether bwrap works under held capabilities. |
| L4 | Project `excludedCommands: ["touch"]` on a direct start past `run-agent` | `touch` still ran sandboxed. With `allowUnsandboxedCommands: false`, excluded commands are not run outside the sandbox on 2.1.280. `run-agent` refuses the file regardless. |
| L4c | Project `allowWrite: ["/home/vscode"]` on a direct start | **The write succeeded.** A project list merges past the managed policy and widens sandboxed writes. This is the gap the N5 check closes for the next session. L10 shows the direct-path writes are refused within a session; a hard-link alias was an untested route until the single-link check (§12, pass 2 N1). |
| L5 | A permissive managed file (`sandbox.enabled: false`) at `CLAUDE_CODE_MANAGED_SETTINGS_PATH`, direct start | Still sandboxed, so no loosening was observed for that key (`sandbox.enabled` is on the CLI's restrictive-wins list). Other keys were not tried. The launcher and wrapper remove the variable (`verify-startup.sh`). |
| L6 | Permissive `remote-settings.json` | `run-agent` refuses (`verify-startup.sh`); not repeated live. |
| L7 | DNS closed, inside the sandbox | `api.anthropic.com` resolves from the pinned `/etc/hosts`; `example.com` does not resolve; HTTPS to it is refused by the sandbox proxy ("host is not on the allow list"); the model round trip works. **Pass.** |
| L8 | Wrappers: bare shell; after a real lockdown with capabilities held; guarded (L2) | Exit 78 for `claude` and `copilot`; exit 78 naming the capability set; runs. `--version` prints in all three. Both names resolve to the wrappers in a non-interactive shell; interactive and login shells did not until the §12 M1 fix. **Pass.** |
| L10 | Within the session: Bash, then the Write tool, on `/workspace/.claude/settings.json` | Read-only file system; "denied by your permission settings". The host copy was unchanged. **Pass.** |
| — | Bash reads of the config volume | Inside the sandbox, `/home/vscode/.claude/settings.json` does not exist: the managed `Read` deny also hides the path from sandboxed Bash. |

**Added later the same day:**
- **Guarded Copilot start-up**, observed. On the test image, `run-copilot` with the PAT secret:
  - locked egress to the Copilot endpoints and passed all three self-tests;
  - purged credentials;
  - printed the version banner through the wrapper, with `--no-auto-update` and capabilities
    dropped;
  - started a guarded session, and GPT-6 Astra answered.

  The pass-2 review (§12) then ran as a full guarded Copilot session.
- **L12:** a guarded Claude session through the relocated link (§12, M1) ran a Bash call, and
  nothing recreated `~/.local/bin/claude`.

**Still to observe:**
- All of L1–L10 and L12 on the rebuilt image.
- A **supervised real build and unit-test run** (Maven WAR, Karma ChromeHeadless) under
  the mandatory sandbox, before E2/E3 count as deployed (§12, pass 1 M2).

L9 is the suite ladder recorded in `VERIFY-ASSERTIONS.md`.

## 11. Independent review and fixes (2026-09-24)

A context-isolated reviewer read the diff against this spec, ran the static checks and
`verify-startup.sh`, and probed the 2.1.280 and Copilot 1.0.83 binaries in disposable
`--network=none` containers without a login.

| Finding | Disposition |
|---|---|
| **H1** (high). Copilot's npm loader runs a *newer* package from its cache in preference to the baked one, and `~/.copilot/pkg` lives on the persistent, agent-writable config volume. A planted package also ran for `copilot --version`, which `run-copilot` calls for its banner **before** the capability drop. N5(a) was therefore not closed for Copilot. | **Fixed.** The wrapper adds `--no-auto-update` to every Copilot call, including `--version`/`--help` (the reviewer observed the baked version run with it). It sets `COPILOT_AUTO_UPDATE=false` and unsets `COPILOT_HOME`, `COPILOT_CACHE_HOME`, `COPILOT_PKG_CACHE_HOME` and `COPILOT_CLI_VERSION`. The wrapper, and `run-copilot` before lockdown, refuse if `~/.copilot/pkg` exists (the real volume has none). Both launchers now run their version banner with capabilities dropped. |
| **H2** (high). Claude reads `localSettings` at the canonical git root. A `/workspace/.git` naming `prj/.git` as its gitdir moves that to `prj/.claude/settings.local.json`, which is unchecked. A live probe showed sandboxed Bash **can** write that file, and it persisted to the host. The Bash write to `/workspace/.git` did not persist, but the Write tool is not denied there. | **Fixed.** `run-agent` refuses any `/workspace/.git` (file, directory or symlink), and both launchers unset `GIT_DIR`, `GIT_WORK_TREE` and `GIT_COMMON_DIR`. The Git root then stays unset and the local settings path stays `/workspace/.claude/`, which is denied in-session. The files the redirect would read are then never loaded, so I did not add refusals for `*/.claude/settings.local.json` or an `Edit(//workspace/**/.claude/**)` deny (the host `prj` has an untracked `.claude/`). |
| **M1** (medium). The server-settings cache has companions (`remote-settings.json.signature*.json`, `remote-settings-consent.json`, `remote-settings-helper-consent`) plus `policy-limits.json`, none of which are checked. | **Accepted, documented.** The companions only qualify a `remote-settings.json`, which must be `[]`/`{}`. `policy-limits.json` can only relax organisation limits such as remote control, never the managed file's rules, and the organisation policy is re-fetched at startup. |
| **M2** (medium). The environment denylist is incomplete: `CLAUDE_CODE_USE_COWORK_PLUGINS`, `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST`, `CLAUDE_CODE_BRIDGE_CHILD_MACHINE_SETTINGS`, `CLAUDE_PROJECT_DIR` and others. | **Partly fixed.** Those four, and the git variables, are unset too. It is still a denylist of operator-supplied variables, not an allowlist; an `env -i` rebuild was judged too likely to break legitimate `-e` use for an operator-mistake guard. |
| **L1**. `.claude.json` was not required to be a regular file (a FIFO hung `jq`). | **Fixed.** |
| **L2**. The checks assume no other container writes the same workspace or volume while `run-agent` starts. | **Documented.** Run one session per workspace and volume (QUICKSTART). |
| **L3**. S10 did not assert `bwrapPath`, `strictAllowlist`, `allowManagedReadPathsOnly`, `strictKnownMarketplaces` or the `.mcp.json` deny. S25/S26 are structural greps. | **Fixed for S10.** S25/S26 remain source-structure checks, with behaviour in `verify-startup.sh`, as `VERIFY-ASSERTIONS.md` says. |

Also observed while checking H2: the sandbox's protective entries for dot-files such as
`.mcp.json`, `.bashrc` and `.gitconfig` exist only inside bubblewrap. None appeared on the
host, so the `Edit(//workspace/.mcp.json)` deny on a nonexistent path is safe for the next
startup check.

**Residual, still not covered:** Copilot's `installed-plugins/` and other `~/.copilot`
state (§4.5); instruction files; operator-supplied launcher arguments.

## 12. Pre-merge two-pass review (2026-09-24)

The owner asked for a fresh review of the whole branch before merging, followed by a
second pass from another vendor's model. It follows OPERATOR's two-pass contract.

- **Pinned:** candidate `2c6d839`, baseline `main` `bd39e12`, in a disposable clone with
  no remotes.
- **Pass 1:** a fresh Claude (Opus) subagent. It was given §§1–8 at `2deb7e5`, the
  decisions and `AGENTS.md`. Withheld: §9 onward, the Phase 3 records, commit messages and
  review 0. It disclosed seeing five commit subjects, code comments that cite review IDs,
  and one incidental grep hit.
- **Pass 2:** GitHub Copilot with GPT-6 Astra, a different vendor and model and a new
  reviewer. It ran inside the sandbox through the guarded `run-copilot` on the test image,
  with the Copilot-Requests-only PAT, egress locked to Copilot, and every input mounted
  read-only. It was given all narrative, review 0, pass 1's packet and pass 1's findings.
- **Records:** the reports are preserved unedited outside the repository. The lead's
  dispositions are recorded here.

**Pass 1 findings and dispositions:**

| Finding | Disposition |
|---|---|
| **M1.** The stock `~/.bashrc` puts `~/.local/bin` before the wrapper in interactive and login shells, so `claude` there ran the real CLI unguarded (E5). The PATH test used a non-interactive shell. | **Fixed; I reproduced it first.** The Dockerfile moves the installer's link to a root-owned `/usr/local/lib/pera-sandbox/real/claude` and removes `~/.local/bin/claude`. `baked-layout` now checks `bash -ic` and `bash -lc` for both CLIs, that nothing is left in `~/.local/bin`, and the link's owner and target. On the rebuilt test image all three shell modes resolve the wrapper. A guarded session through the moved link ran a Bash call (L12), and nothing recreated `~/.local/bin/claude` afterwards. `claude doctor` now warns that the native installation is not on `PATH`, which is expected (QUICKSTART). |
| **M2.** No real build (Maven WAR, Karma ChromeHeadless, npm) has run under the mandatory sandbox with no unsandboxed retry. | **Accepted as a deployment gate.** Added to "still to observe": a supervised build and unit-test run in the first real session on the rebuilt image, before E2/E3 count as deployed. It is not run here, because it would write to a registered task workspace. |
| **L1.** `COPILOT_CLI_DIST_DIR` makes Copilot's loader run `index.js` from another directory. | **Fixed:** it is unset in the wrapper and `run-copilot`, and it is in the fixture's redirect list. |
| **L2.** Server-managed settings, if the organisation ever configured them, would take precedence over the file policy entirely. | **Documented as a condition** in SECURITY-REVIEW: any organisation-level server-managed settings must carry this policy, or they displace it. The startup check cannot see a runtime fetch. |
| **L3.** A session killed mid-command can leave an empty placeholder `.mcp.json`, and the next start refuses. | **Documented** in QUICKSTART "Startup refusals": confirm the file is empty, then remove it. Refuse-rather-than-repair stays. |
| **L4.** Docs overclaimed: the capabilities-held result was presented as observed but was never retained, and "S10 asserts both files exactly" was false for the managed file. | **Fixed:** FAQ and `devcontainer.json` say the result was seen once and not retained. S10 now also compares the whole managed file, and a widened `allowedDomains` fails it. |
| Instruction files persist unchecked. | Already recorded as a residual. |

**Pass 2 (GPT-6 Astra).** Its report was recovered verbatim from the session's
`task_complete` event, because `-s` printed nothing. **Limitation:** Copilot's path
verification denied every read under `/evidence`, since `run-copilot` deliberately does
not pass `--allow-all-paths`. Pass 2 therefore could not audit the raw live transcripts,
and says so. Any rerun should put the evidence under the trusted `/workspace`.

| Pass 2 item | Disposition |
|---|---|
| Corrected the severity of pass 1's M2, L1, L2 and L3: an outstanding verification obligation, a conditional hygiene risk, runtime composition unresolved, not reproduced | **Accepted.** SECURITY-REVIEW's server-managed condition now says the composition is unverified rather than "replaces the file entirely". |
| **N1** (medium). A hard link to the canonical `/workspace/.claude/settings.json` passes the regular-file, symlink and byte checks. A later session can then rewrite that inode through the ordinary writable name, and the pathname denies and the sandbox bind do not cover it. Found by reading. | **Fixed:** every validated file must also have exactly one link (`stat -c %h`). The real volume files and workspace settings all have one link. New scenarios `agent-project-hardlink` and `agent-user-hardlink`. Whether sandboxed Bash can create such a link in-session (a cross-mount `link()` should fail with `EXDEV`) is unverified; the startup check refuses one at the next start either way. |
| **N2** (medium). The QUICKSTART recovery `cp` follows a symlinked `.claude` parent on the host and could overwrite the operator's own `~/.claude/settings.json`. | **Fixed:** the recovery block removes a symlinked `.claude` (the link, not the target), refuses anything that is not a plain directory, and breaks any hard link before copying. |
| **Extraction.** Decision 4 was the lead's proposal: §5 offered no recommendation, and the owner's "go with your recommendations" preceded it. | **Open for the owner.** It needs explicit confirmation or change. **Decided 2026-09-25 (§13):** option C, a split between the real volume and a throwaway sign-in. |
| **Extraction.** L1 required seeing the selected source, skipped sources and rejected keys; §10 claims "met behaviourally". | **Accepted as unmet.** Moved to the rebuilt-image gate: interactive `/status`. |
| **Extraction.** L3 required "CLI refuses to start". The observed "starts, and Bash fails" is not equivalent, because the in-process tools (Read, Edit, Write, WebFetch) still work, and in an unguarded container the firewall is also open. | **Accepted as unmet. Owner decision needed.** Either accept the residual, now that the E5 wrappers catch every PATH route including interactive shells (§12 M1) and only a by-path or IDE-extension start remains; or add a managed `WebFetch` deny as extra hardening, since it has no use in a locked-down session. Not changed unilaterally. **Decided 2026-09-25 (§13):** managed denies for `WebFetch` and `WebSearch`. |
| **Extraction.** L4 required recording direct-start behaviour for all six seeded keys; §10 covers `excludedCommands` and `allowWrite` only. | **Accepted as incomplete.** The other four (`bwrapPath`, a hook, `statusLine`, `apiKeyHelper`) are ignored from project settings by the binary's own lists (§9) and are refused by `run-agent`. Their live characterization joins the rebuilt-image gate. **Corrected in §14:** `apiKeyHelper` is honoured. |
| **Extraction.** Two input rules relax the literal §4.3 table: an absent project `settings.json` is accepted, and an empty or null `mcpServers` in `.claude.json` is accepted. | **Recorded as departures.** **D-10:** an absent project file is harmless under the managed policy, and the legacy and test fixtures rely on it. **D-11:** the real volume's `.claude.json` holds exactly one `mcpServers` entry, and it is empty (counted read-only). Refusing empty entries would refuse the real volume, and an empty map configures nothing. |
| Narrative overclaims: L8 shell scope; L10 "cannot plant"; the README "outrank everything"; QUICKSTART "`--version` always works"; the overlay "refuses if these change"; the VERIFY-ASSERTIONS directory-wide invisibility claim; probe accounting | **Fixed in the text**, each narrowed to what was observed. The probe accounting: the L4–L6 refusal probes need no login; the L4/L4c/L5 direct-start characterisations did mount the real volume, as decision 4 allows. |
| The review-0 dispositions: H2's nested-settings refusal and recursive deny not adopted; M2's `CLAUDE_CODE_SAFE_MODE` not unset | **Stand as recorded.** `CLAUDE_CODE_SAFE_MODE` is left alone deliberately: its effect is undetermined, and unsetting an operator's restrictive flag could weaken intent. |

**Gate before E2/E3/E5/N5 count as deployed:**
- the rebuild;
- on the rebuilt image, L1 (including `/status`), L2–L10, L12 and the remaining L4 keys,
  each with the login §13 assigns it;
- a supervised real build and unit-test run.

Security/IT sign-off (C5) remains required for unattended use.

## 13. Owner decisions after the review (2026-09-25)

**L3: deny the web tools.** The owner chose managed denies for both `WebFetch` and
`WebSearch`, over accepting the residual or denying `WebFetch` alone.

- **Why both.** Every guarded session on the test image was offered both tools (all seven
  retained transcripts). `WebFetch` runs from the container, so the firewall already makes
  it useless in a guarded session; the deny closes it for an unguarded start, where the
  network is usually open. `WebSearch` is understood to run on the provider's side, where
  the container firewall would not reach it, so a query could carry workspace content out
  of a **guarded** session too. That understanding is unverified: no search was run in a
  locked session, and whether search is enabled for the organisation is unknown.
- **Change:** the two bare tool names join the managed `permissions.deny`. S10 checks
  both, and its whole-file comparison changes with them. The project file is unchanged:
  D-9 repeats only the old deny rules.
- **Observed, without a login:** on the test image with this file mounted over the baked
  policy, a direct `-p` start under `--network=none` offered 19 tools instead of 21. The two
  web tools were the only ones missing. This is not a rebuilt-image observation.
- **L3's pass condition** is rewritten, since no setting makes the CLI refuse to start and
  no wrapper can intercept a start by path: *an unguarded start runs nothing unsandboxed
  and offers no web tools.* To observe on the rebuilt image. The file tools still work in
  such a start, and that stays a documented residual.

**Decision 4: split the logins (option C).** The owner confirmed the lead's proposal in
this refined form:

| Check | Login |
|---|---|
| L1 (`/status`), L2, L7, L10, L12, and the supervised build and unit-test run | The real `pera-claude-config` volume, in disposable containers. These run the reviewed policy unchanged, as a real session would. L1 only means something with the organisation's own account, since server-managed settings come from it. |
| The remaining L4 direct-start probes: `bwrapPath`, a hook, `statusLine`, `apiKeyHelper` | A **throwaway volume** (for example `pera-claude-config-probe`), created empty and signed in once by the owner with their own account. It is a new sign-in, not a copy of the real volume, and it is removed after the gate. Three of the keys run commands; if a CLI release ever honoured one, it would run outside the sandbox beside a token, so none of these probes runs beside the real volume. |
| L3 (no web tools offered), L4 refusals, L5, L6, L8 | No login. Synthetic files, as before. |

Around each real-volume check, the lead records the checked volume files before and after:
a hash of `settings.json` and `remote-settings.json`, and the `mcpServers` content of
`.claude.json`, which otherwise changes in every session. Any difference stops the gate.

The throwaway token still belongs to the owner's account; whether one sign-in can be revoked
on its own is unverified. It is exposed only to the lead's own probe commands.

## 14. Deployment gate on the rebuilt image (2026-09-25)

**The rebuild.** From the scaffold's `main` at `4e950e5`, by the QUICKSTART update procedure.
Before overwriting, every differing build-context file was matched to an earlier committed
scaffold version. The owner restored `.secrets/npmrc`; the lead did not handle it. The build
took 73 seconds and every Phase 3 layer was rebuilt.

- Image `cf5cd3379a7f` is `localhost/pera-sandbox`. `893d19…` and `fda0c678…` are kept.
- **Claude Code 2.1.282** (the installer takes the latest release; §§9–13 analysed 2.1.280).
  **Copilot 1.0.83** came from the build cache.
- The registered tasks EEP-24 and JWA-2906 pin `893d19…` and have no open rounds.
  `sandbox-task.sh` already refused new rounds for them once the tag moved to `fda0c678…`.
- **2.1.280 against 2.1.282, static:**
  - The three key lists read in §9 are byte-identical.
  - The CLI's ignored-environment list grew, and still holds `CLAUDE_CODE_MANAGED_SETTINGS_PATH`.
  - Two new environment names matched the search: `CLAUDE_CODE_CCR_EARLY_REMOTE_CONNECT`
    and `CLAUDE_CODE_REMOTE_TOOLS_SPECULATIVE_CLASSIFIER`. Neither was investigated.

**Suites on the rebuilt image:** `verify-startup.sh --baked` 45/45, from source 44 passed and
1 skipped; `verify-firewall.sh` 66/0; `verify-scaffold.sh` 24 passed, 2 skipped.

**Observations.** Disposable containers, synthetic workspaces, logins as decision 4 assigns.

| # | Result |
|---|---|
| L1 | **Pass.** The owner ran `/status` in a guarded session on the real volume: setting sources "User settings, Shared project settings, Enterprise managed settings (file)"; "Permission rules: Managed settings only (allowManagedPermissionRulesOnly)"; organisation Colorado PERA on a Team account. No skipped source and no rejected key was listed; the only diagnostics were the expected install-path warnings. `claude doctor` showed the organisation policy loaded and a remote-settings fetch still in progress. |
| L2 | **Pass.** A write to `/home/vscode` was refused as read-only, also with `dangerouslyDisableSandbox`; `/tmp` was writable. |
| L3 | **Pass, as rewritten in §13.** The real CLI by path with capabilities held, both without a lockdown and after one: its Bash call failed inside bubblewrap, no marker appeared, and 19 tools were offered with no web tool. This needed a model round trip, so it used the throwaway volume, not the "no login" row of §13. |
| L4 | Direct starts past `run-agent`, throwaway volume. Markers under `/home/vscode` could come only from code run outside the sandbox. `bwrapPath` pointing at a marking wrapper: no marker. A project `PreToolUse` hook: no marker. `statusLine`: no marker, **but the control through `--settings` left none either** while the UI rendered, so nothing is shown about project scope; it did not run from any scope under this policy. **`apiKeyHelper`: ran** (finding G1 below). `run-agent` refuses all four (`verify-startup.sh`). |
| L5, L6, L8 | Covered by the baked startup suite on this image; not repeated live. |
| L7 | **Pass.** `api.anthropic.com` resolved from the pinned `/etc/hosts`; `example.com` did not resolve; HTTPS to it was refused by the sandbox proxy ("host is not on the allow list"); the model answered. |
| L9 | The suites above. |
| L10 | **Pass.** Bash: read-only file system. Write tool: "denied by your permission settings". The host copy was unchanged. |
| L12 | **Pass.** A guarded session through the relocated link ran Bash, and `~/.local/bin/claude` was absent afterwards. |
| Web tools | **Pass.** The guarded session offered 19 tools and neither web tool; the model confirmed it had neither. |

**Real-volume comparison.** `settings.json` was unchanged across the checks. The first
snapshot ran without `--userns=keep-id` and could not read `remote-settings.json` or
`.claude.json`, so for those two there is no before-and-after pair. Read correctly
afterwards, both were within policy: `remote-settings.json` was `{}`, where §2 recorded
`[]`, and `.claude.json` held its one empty `mcpServers` entry (D-11). The CLI rewrites
`remote-settings.json` on its own, so the gate now compares its content, not its hash.

**Finding G1** (🟡 medium, recorded, no code change). On 2.1.282, a project-scope
`apiKeyHelper` **runs**, outside the sandbox, when the CLI is started directly with the
workspace trusted (`-p` trusts it). The throwaway volume held no `apiKeyHelper`, so the
project file was the source. The binary gates a project helper only on workspace trust.
The §9 claim was wrong for this key, and the other command-running keys are treated as
honoured too.

- The guarded path stays closed. `run-agent` refuses any project file that is not the
  canonical one, before lockdown. In-session writes to it are refused (L10). The
  single-link check covers a hard-link alias, and `/workspace/.git` is refused (H2).
- What G1 removes is the CLI's own refusal of these keys at project scope. Two layers
  remain. In a session, writes to the file are refused twice over, by the managed `Edit`
  deny and by the sandbox's read-only bind (L10). At the next start, the byte comparison
  detects a changed file.
- **Owner decision 2026-09-27: no change now (option A).** Two alternatives were weighed.
  - **B:** the wrapper also runs the startup checks. It would stop only a deliberate manual
    start that types `claude` after a hand-made lockdown and capability drop. It would add
    no depth to guarded sessions, since it repeats the same check seconds later. It would
    need a rebuild, which would move the image ID pinned by the next registration.
  - **C:** a read-only bind of `.claude/` in the launch command. That would be a real
    second write barrier, at the cost of every launch command.

  **B is to be reconsidered at the next rebuild.** C is to be reconsidered if a probe ever
  finds an in-session write route to the project file.

**Still to do before E2/E3/E5/N5 count as deployed:** the supervised real build and
unit-test run (Maven WAR, Karma ChromeHeadless) in the ticket lead's first session on this
image (§12, M2). After that the throwaway volume `pera-claude-config-probe` is removed.
Unattended use still needs C5.

## 15. Build rehearsal, finding G2 and the second rebuild (2026-09-27)

**Rehearsal.** The owner approved a rehearsal of the supervised build while the ticket lead's
first session was pending. It ran in a disposable copy of `~/pera-sandbox` without `.secrets`,
in one guarded `run-agent` session on the throwaway login, on `cf5cd3379a7f`. The offline
memberWWW WAR build passed (4 min 27 s, fresh WAR). **Karma could not start ChromeHeadless,
so no test ran.**

**Finding G2** (🟠 deployment blocker for Claude sessions, fixed). Full Chromium cannot start
inside Claude's Bash sandbox. Two causes stack:

1. Its crash store lives under the config home, and `$HOME` is read-only in the sandbox, so
   the crash handler starts without a database ("`--database is required`"). Reproduced
   without the model, in a fresh container in `run-agent`'s capability state with a
   read-only root. Pointing `XDG_CONFIG_HOME` at `/tmp` clears it.
2. Its single-instance lock needs a Unix-domain socket, and the sandbox's seccomp filter
   forbids creating one: two filters active, `AF_UNIX` listen `EPERM`, `socketpair` allowed.
   With cause 1 cleared, Chrome aborts in `process_singleton_posix.cc` with "socket()
   failed: Operation not permitted". A policy copy with `allowAllUnixSockets` removed the
   filter, but cause 1 still stopped Chrome first, which is why the two were separated only
   in that order. No Chromium switch disables the lock, and full Chromium 153 fails the same.

The JWA-2906 round that passed this suite ran on Copilot CLI 1.0.83, which has no inner
sandbox (VERIFY-ASSERTIONS, JWA-2906 field evidence). No Claude Code session has yet run a
Karma suite in a live ticket round.

**Update 2026-09-28:** EEP-24-A11Y R1 did. The agency suite reached `TOTAL: 120 SUCCESS` inside
Claude's sandbox on `6fa46c4bb3c3`, on the headless shell (VERIFY-ASSERTIONS).

**Owner decision (option A).** Install EPEL's `chromium-headless` and point `CHROME_BIN` at
its headless shell, which has no single-instance lock. The sandbox policy is unchanged. In
the real sandbox, the PSC v2 suite ran `TOTAL: 270 SUCCESS` both with and without an `XDG`
redirect, so no wrapper script is needed. Rejected:
- **Allowing Unix sockets** (`allowAllUnixSockets`) is all-or-nothing on Linux. Sandboxed
  code could then connect to any Unix socket in the container, including the CLI's own
  session socket under `/tmp`, which runs outside the sandbox. That is a plausible escape
  route; it was not tested.
- **No change** would leave Karma to Copilot sessions or the host, and take the test loop
  away from Claude sessions.

**Change** (`fix/g2-headless-chrome`, `3696ef1`):
- The Dockerfile installs `chromium chromium-headless` in a step after the Copilot install,
  and checks both are on one release.
- `CHROME_BIN` is `/usr/lib64/chromium-browser/headless_shell`. `/usr/local/bin/chrome` stays
  full Chromium.
- New checks:
  - **S27:** a mutation pointing `CHROME_BIN` back at full Chromium fails it.
  - **`verify-startup.sh` scenario `chrome-headless`:** the baked `CHROME_BIN`, matching
    package releases, and a start with a read-only home. Its bwrap has no seccomp filter,
    so it cannot show cause 2; Karma in the real sandbox is a live check.
- The overlay tells agents not to point `CHROME_BIN` at full Chromium.

**Second rebuild.** From the branch's build context by the QUICKSTART procedure. It took
about 3 minutes and rebuilt every layer from the new Chromium step down; Copilot's layer
stayed cached.

- Image `6fa46c4bb3c3` is `localhost/pera-sandbox`: **Claude Code 2.1.283**, Copilot
  1.0.83, Chromium and its headless shell 153.0.8010.52.
- `cf5cd3379a7f`, `fda0c678…` and `893d19…` are kept. No registration pins `cf5cd3379a7f`.

**Re-gate on `6fa46c4bb3c3`**, the §14 scripts unchanged except for the image:

| Check | Result |
|---|---|
| `verify-startup.sh --baked` | 46 of 46, `chrome-headless` included |
| `verify-firewall.sh` | 66 passed |
| `verify-scaffold.sh` | 25 passed, 2 skipped |
| 2.1.282 against 2.1.283, static | The §9 key lists are identical. The ignored-environment list grew past the earlier search window and still holds `CLAUDE_CODE_MANAGED_SETTINGS_PATH` (found by offset). New names `CLAUDE_CODE_REMOTE_TOOLS_CALLER_SESSIONS_MAX`, `…_FORWARD` and `…_PIN_STORED_LOGIN` were not investigated. |
| L1 `claude doctor` | Organisation policy loaded; the same two install-path warnings. **`/status` was not repeated on 2.1.283.** |
| L2, L7, L10, L12, web tools | Pass, as in §14 |
| Real-volume comparison | All three checked files unchanged, now read with the corrected snapshot |
| L3 | Pass, as in §14 |
| L4 | Hook and `bwrapPath` not honoured; `statusLine` not shown either way; `apiKeyHelper` still honoured (G1) |
| Full rehearsal with the image's own `CHROME_BIN` | Maven WAR **BUILD SUCCESS** (4 min 44 s, fresh WAR); Karma **`TOTAL: 270 SUCCESS`** in Chrome Headless 153 |

**Still to do before E2/E3/E5/N5 count as deployed:** the supervised real build and unit-test
run in the ticket lead's first session on `6fa46c4bb3c3` (§12, M2). The rehearsal covered its
technical content on a copy of the same workspace. Whether it can stand in for that session
is the owner's call. Then the throwaway volume and probe workspaces are removed. Unattended use
still needs C5.

**Owner decision 2026-09-27:** the rehearsal is accepted as the supervised-build check.
E2/E3, E5 and N5 are deployed in `6fa46c4bb3c3`. The ticket lead's first real session is
confirmation, not a gate.

**Cleanup, 2026-09-27.** The throwaway volume, probe workspaces, rehearsal copy, test images
and `cf5cd3379a7f` were removed. `fda0c678…` was removed by mistake with them; see
SECURITY-REVIEW's Phase 3 deployment record. The C5 sign-off is deferred by the owner.
