# Phase 3 spec: Claude inner sandbox (E2/E3), guarded startup (E5), next-session integrity (N5)

**Status:** draft for owner review, 2026-09-23. Nothing described here is implemented.
This is firewall-adjacent and settings-precedence work: under `AGENTS.md` it is not
delegable without this review, and the implementation diff needs a second review.

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
