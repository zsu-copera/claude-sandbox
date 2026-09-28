# Verification assertions

This is the assertion specification. The S-series is implemented in `verify-scaffold.sh`;
focused E1 firewall regressions are provided separately in `verify-firewall.sh`. The full
`verify-sandbox.sh` P/A/G/X lifecycle runner and its startup integration are not implemented.
The firewall's positive and negative smoke probes remain startup gates, not a substitute
for the runtime assertions below.

## Static and planned lifecycle checks

The assertions split by what they can observe, and that split is not cosmetic — several
assertions are impossible in the wrong context.

| Script | Mode | Where it runs | Cost |
|---|---|---|---|
| `verify-scaffold.sh` | (none) | Windows host, Git Bash or WSL, against this directory | seconds, no container |
| `verify-firewall.sh` | default / `--callers-only` / `--sudo-only` | WSL/Podman, disposable containers with candidate source | targeted modes are quicker; full suite takes minutes |
| `verify-rounds.sh` | default | WSL/Podman, disposable repositories and operator-command fixtures | no prepare or real task workspace |
| `verify-tasks.sh` | default / integration mode | Disposable task registry, send/status and audit-collection fixtures | no real task registration or export |
| `verify-sandbox.sh` | `--post-prepare` | End of `prepare.sh`, network still open | seconds |
| `verify-sandbox.sh` | `--pre-agent` | In `run-agent`/`run-copilot` after lockdown, **still holding capabilities** | seconds |
| `verify-sandbox.sh` | `--as-agent` | Invoked *through* the `setpriv` wrapper, i.e. with the agent's own privileges | seconds |

**The `--pre-agent` / `--as-agent` split is the part an implementer will get wrong.** After
`setpriv --inh-caps=-all --ambient-caps=-all` the process cannot read iptables at all, so
firewall-rule assertions must run *before* the drop; and the whole point of the capability and
bubblewrap assertions is to observe the state the agent actually gets, so those must run *after*
it. In `run-agent.sh` that means one call before the `setpriv` line and one as
`setpriv --inh-caps=-all --ambient-caps=-all verify-sandbox.sh --as-agent`.

`verify-scaffold.sh` is the one to run after every edit, and the one that makes this scaffold
delegable to a cheaper agent: it needs no container, so an agent can iterate against it.

## Output contract

- One line per assertion: `PASS`/`FAIL`/`WARN`/`SKIP`, the assertion id, and a short label.
- `FAIL` prints what was expected and what was found. No assertion may print a credential.
- Exit non-zero if any `FAIL`. `WARN` and `SKIP` do not affect exit status.
- `SKIP` is legitimate and must say why (a profile that was not warmed, `prj` not present,
  `shellcheck` not installed). A silent skip is a failed assertion.
- `--pre-agent` failing must abort the session, in the same spirit as the existing firewall
  self-test. `verify-scaffold.sh` failing should just report.

---

## S — Scaffold, static (`verify-scaffold.sh`)

| id | Assertion | Method | On fail |
|---|---|---|---|
| S1 | Zero CR bytes in tracked/unignored shell, JavaScript, JSON, Markdown, PowerShell and build-definition text | count `0x0d` bytes; **do not** use `grep -c $'\r'`, which false-positives in Git Bash — use `od -An -tx1 -v` or `awk '/\r$/'` | FAIL |
| S2 | Every `*.sh` parses | `bash -n` | FAIL |
| S3 | No `shellcheck` errors (warnings allowed) | `shellcheck -S error`, `SKIP` if absent | WARN |
| S4 | Every path the Dockerfile `COPY`s from `container/` exists | parse `COPY container/...` lines | FAIL |
| S5 | The Dockerfile's `sed`/`chmod` file lists match its `COPY` list | compare the two sets | FAIL |
| S6 | Every file `new-sandbox.sh` copies from the scaffold exists (`overlay/CLAUDE.md`, `container/claude-project-settings.json`, `.devcontainer`, `container`, `dockerignore`) | existence check | FAIL |
| S7 | No personal path or name anywhere | grep for `/home/su`, `Users/su`, `zsu@`, and any hardcoded human name used as a default value | FAIL |
| S8 | `container/claude-managed-settings.json`, `container/claude-project-settings.json`, `container/copilot-settings.json` and `container/copilot-policy.json` are valid JSON | `jq empty` | FAIL |
| S9 | `.devcontainer/devcontainer.json` is valid **JSONC** | it contains `//` comments, so plain `jq` fails — strip comments first or use a JSONC parser. A naive `jq empty` here is a false failure | FAIL |
| S10 | The managed policy (`container/claude-managed-settings.json`) requires the sandbox (`enabled`, `failIfUnavailable`, `allowUnsandboxedCommands: false`, no `excludedCommands`, weaker modes off), keeps `allowWrite` exactly `["/tmp"]`, sets `allowManagedDomainsOnly`, the three `allowManaged*Only` locks and an empty `allowedMcpServers`, carries the push, secrets, settings-store and web-tool deny rules, and does not set `disableBypassPermissionsMode`; the project settings are exactly the canonical file (bypass mode, the four deny rules, `sandbox.enabled`, `/tmp` and `api.anthropic.com`, and nothing else). Moved from the overlay file in Phase 3 (approved 2026-09-24) | `jq`, or node on the Windows host | FAIL |
| S11 | Source retains serialized durable/kernel guards and staged refresh, without a permissive flush outside `open` | inspect lock ordering, state checks, ipset swap and chain-jump replacement; runtime proof belongs to `verify-firewall.sh` | FAIL |
| S12 | Source stages a private domain record, atomically publishes it and reuses the committed list | inspect umask, pending-file publication and pinned-domain reuse; not proof of effective ownership or crash behavior | FAIL |
| S13 | Both entrypoints drop capabilities before exec'ing the agent | grep for `setpriv --inh-caps=-all --ambient-caps=-all` in `run-agent.sh` and `run-copilot.sh` | FAIL |
| S14 | Every `sudo` call site uses the absolute `/usr/local/bin/init-firewall.sh` | grep `sudo` in all scripts; `Defaults secure_path` excludes `/usr/local/bin`, so a bare name breaks | FAIL |
| S15 | The Dockerfile's sudoers line is scoped to `init-firewall.sh`, not `ALL` | grep the sudoers `echo`; a `NOPASSWD: ALL` makes the agent effectively root | FAIL |
| S16 | Both entrypoints purge `.secrets`, `~/.npmrc` and `~/.m2/settings.xml`, and do so **after** the lockdown call | check order of the lockdown and `rm` lines | FAIL |
| S17 | `prepare.sh` still strips `_remote.repositories` after warming | grep, and check it appears after the `mvn` invocation | FAIL |
| S18 | `run-copilot.sh` still passes `--disable-builtin-mcps`, the `--deny-tool` set and the `--deny-url` set, and does **not** pass `--allow-all-paths` or `--allow-all-urls` | grep the exec line | FAIL |
| S19 | `prepare.sh`'s `NPM_FOR` map covers every `<nodeVersion>` pinned in the `prj` poms | requires `../prj`; `SKIP` if absent | WARN |
| S20 | A `VERSION` file exists and the value the entrypoint banner prints matches it | once D3 is done; `SKIP` until then | WARN |
| S21 | No staged credential material is present in the scaffold directory | assert `.secrets/` absent and no file matching `settings.xml`/`npmrc` | FAIL |
| S22 | Every `container/*` file appears in `README.md`'s Files table | cheap guard against doc drift | WARN |
| S23 | `container/certs/` is absent or empty | it is generated per machine and must never be committed or shipped | WARN |
| S24 | Policy-hook packaging and registration fragments remain in source, with optional JavaScript syntax checking | grep COPY/ownership/mode/registration/rule fragments and run `node --check` if available; does not prove effective image permissions, CLI loading, failure behavior or complete command coverage (N2) | FAIL |
| S25 | The Dockerfile installs the managed policy and canonical project settings root-owned (policy `0644`, empty `managed-settings.d/`), installs `agent-cli-guard.sh` as the `claude` wrapper with a `copilot` link, root-owned, and its final `PATH` starts with the wrapper directory; `run-agent` and `new-sandbox.sh` use the canonical file; the wrapper targets the baked CLIs, checks the root-owned lockdown file and all four capability sets | grep; source structure only, the runtime layout is `verify-startup.sh --baked` | FAIL |
| S26 | `run-agent.sh` and the wrapper unset the five managed-policy redirects; `run-agent` keeps the reviewed user-settings allowlist verbatim, checks project settings (canonical or legacy hash), `settings.local.json`, `.mcp.json`, `remote-settings.json` and `mcpServers`, before its lockdown call; neither launcher references a workspace-staged CLI | grep and line order; behavior is `verify-startup.sh` | FAIL |
| S27 | The Dockerfile installs `chromium-headless` beside `chromium` and sets `CHROME_BIN` once, to the headless shell (finding G2: full Chromium cannot start inside Claude's Bash sandbox) | grep; the `verify-startup.sh` scenario `chrome-headless` checks the baked `CHROME_BIN`, matching package releases and a start with a read-only home; Karma under the real sandbox is a live check | FAIL |

## P — Post-prepare, network open (`verify-sandbox.sh --post-prepare`)

| id | Assertion | Method | On fail |
|---|---|---|---|
| P1 | `/workspace/prj` and `/workspace/Documentation` exist and are git repos | `git -C … rev-parse` | FAIL |
| P2 | **Neither repo has any remote** | `git -C … remote` prints nothing | FAIL |
| P3 | Both repos have `user.name` and `user.email` set | `git -C … config --get` | FAIL |
| P4 | The configured email is a real account, not a placeholder | must not be `agent@sandbox.local`; once I1 is fixed, must not be a hardcoded default either | FAIL |
| P5 | `core.autocrlf` is `input` in both repos | `git -C … config --get` | FAIL |
| P6 | `/workspace/.m2/repository` exists and is non-trivially sized | `du`; a warmed agency cache is roughly 400 MB | FAIL |
| P7 | **Zero `_remote.repositories` files remain** in the cache | `find … -name _remote.repositories \| wc -l` equals 0 | FAIL |
| P8 | The cache actually resolves offline **without** a `settings.xml` | `mvn -o -q help:evaluate -Dexpression=maven.version -DforceStdout` with no `-s` — this is the real proof of P7, and the failure it guards against was the original blocking defect | FAIL |
| P9 | `/usr/bin/node` reports the pinned version | compare against the Dockerfile's `NODE_OFFICIAL` | FAIL |
| P10 | `/usr/bin/node` is the official binary, not dnf's | the honest cheap check is `rpm -Va nodejs`, which reports the path as modified since install — that proves *replaced*, not *replaced with the right thing*. For a real check, have the Dockerfile record the installed binary's sha256 and compare here. Note `rpm -qf /usr/bin/node` does **not** discriminate: rpm tracks paths, so the package still claims the path | WARN |
| P11 | `CHROME_BIN` is set and the binary runs | `"$CHROME_BIN" --version` | FAIL |
| P12 | Each warmed module has both `node/` and `node_modules/` | derive the module list from the warmed profile; `SKIP` modules outside it and say which | FAIL |
| P13 | A node dist tarball exists in `.node-cache/` for every pinned version | existence check per version | FAIL |
| P14 | *(retired in Phase 3)* No agent CLI is staged: `.agent-cli/` is absent after prepare, because the launchers run only the baked CLIs (N5, decision A) | `! -e .agent-cli` | FAIL |
| P15 | `prj/.github/copilot-instructions.md` and `prj/.agents/skills/agency-jsp-to-angular` are present | these are git-ignored upstream and arrive only via the overlay; their silent absence produces a degraded sandbox | WARN |

## A — After lockdown, still privileged (`verify-sandbox.sh --pre-agent`)

| id | Assertion | Method | On fail |
|---|---|---|---|
| A1 | `/workspace/.secrets` is gone | existence check | FAIL |
| A2 | `~/.npmrc` and `~/.m2/settings.xml` are gone | existence check | FAIL |
| A3 | The provider endpoint is reachable | `curl -m 8` against the first non-CIDR allowlist domain | FAIL |
| A4 | `example.com` is refused | as the current self-test does | FAIL |
| A5 | **Nexus is refused** — `nexus-repo.isd.copera.org` | the current self-test never probes a host that matters; this one does | FAIL |
| A6 | **Bitbucket is refused** — `bitbucket.org` | the push target for `prj` | FAIL |
| A7 | `github.com` is refused | **Claude sessions only.** In a Copilot session GitHub's ranges are deliberately reachable, so this must be mode-aware or it is a false failure | FAIL / SKIP |
| A8 | Default policies are `DROP` on INPUT, OUTPUT and FORWARD | `iptables -S`; only possible before the capability drop | FAIL |
| A9 | The `CLAUDE_LOCKDOWN` marker chain exists | `iptables -n -L CLAUDE_LOCKDOWN` | FAIL |
| A10 | `/run/claude-lockdown-domains` exists, is non-empty, root-owned, mode 600 | `stat` | FAIL |
| A11 | `sudo -l` lists only `init-firewall.sh` | assert `ALL` does not appear | FAIL |
| A12 | DNS resolves | `dig +short api.anthropic.com`. This asserts a **needed** capability — DNS egress is intentionally open and this is not a leak check | FAIL |

## G — As the agent sees it (`verify-sandbox.sh --as-agent`)

Run through the same wrapper the agent gets:
`setpriv --inh-caps=-all --ambient-caps=-all verify-sandbox.sh --as-agent`

| id | Assertion | Method | On fail |
|---|---|---|---|
| G1 | Effective capabilities are empty | `CapEff` in `/proc/self/status` is all zeros | FAIL |
| G2 | **bubblewrap actually works** | `bwrap --ro-bind / / --dev /dev --tmpfs /tmp true` exits 0. This is the layer that currently fails open (`failIfUnavailable: false`), and it was broken for weeks without anyone noticing | FAIL |
| G3 | The agent cannot read the committed allowlist | reading `/run/claude-lockdown-domains` fails | FAIL |
| G4 | The agent cannot read the firewall | `iptables -S` fails | FAIL |
| G5 | The agent cannot read staged credentials | `.secrets`, `~/.npmrc`, `~/.m2/settings.xml` all unreadable or absent | FAIL |

## X — Adversarial, opt-in (`verify-sandbox.sh --adversarial`)

Not part of a normal session. These probe the guards by trying to defeat them, and one of them
opens the network if it succeeds.

| id | Assertion | Method | On fail |
|---|---|---|---|
| X1 | `sudo /usr/local/bin/init-firewall.sh open` exits 3 | **If it exits 0 the network is now open** — report FAIL and destroy the disposable test container. Never run against an existing agent session | FAIL |
| X2 | `sudo /usr/local/bin/init-firewall.sh lockdown evil.example.com` does not change the pinned domains | run it, then confirm the controlled forbidden destination is refused and the committed file is unchanged | FAIL |
| X3 | No egress window during a lockdown refresh | combine controlled traffic probes with deterministic pauses, concurrent calls, injected failures and kernel-state assertions on both backends; polling alone can miss a short gap | FAIL |

## Focused E1 regressions (`verify-firewall.sh`)

Run from this working copy inside WSL:

```bash
bash verify-scaffold.sh
bash verify-firewall.sh --image localhost/pera-sandbox
```

The static runner still exits nonzero for the unrelated S7 findings. Record that failure;
do not describe it as a clean gate or suppress new failures.

The firewall runner uses disposable containers and only mounts the candidate firewall
script and narrow test fixtures, not the workspace, auth volumes or host credentials.
Caller scenarios stream the current launcher source on stdin into network-disabled
containers, use a synthetic workspace and helper/CLI shims, and exercise startup failure
ordering and visible refresh errors. Run those alone with `--callers-only`; they do not
replace real agent login or provider-connectivity checks.

The separate `--sudo-only` scenario uses actual scoped elevation after switching to the
agent identity and clearing its capabilities. That disposable, network-disabled container
retains SETUID/SETGID/DAC_OVERRIDE (existing production defaults needed by sudo/PAM) and
does not enable no-new-privileges, which would prevent the elevation being exercised.
It mounts only the candidate firewall source; account/PAM data is not changed. If the
image's PAM prevents the helper from running, the result is an explicit skip, not a
successful reopen-refusal assertion.

Controlled destinations and command shims let it exercise DNS changes, failures and
interruptions without attempting external transmission. This supplies focused coverage
for A8-A10 and X1-X3, not the full P/A/G/X specification or a no-exfiltration guarantee.
Missing real-backend coverage must be reported explicitly, not counted as a pass.

The default runner includes all 59 E1 scenarios: 54 firewall cases, 4 shim-based
caller cases and 1 real scoped-sudo case. The recorded completion evidence was
58 cases in a combined run plus the separately run scoped-sudo case, not a claim
that the final 59-case runner was executed as one invocation. See
[the E1 record](SECURITY-REVIEW.md#e1-remediation-on-a-separate-branch) for outcomes
and outstanding deployment work.

The E1 contract is:

- A root-owned lock serializes `open`, first lockdown and refresh. Durable or kernel
  evidence of initialization blocks reopening, even when another state component is absent.
- DNS/candidate construction precedes initial installation. Failure here is retryable;
  once installation intent is recorded, incomplete initialization requires a fresh container.
- First installation pins the domain list and backend. Refresh never migrates backends.
- Refresh leaves built-in policies, base rules and marker intact. It activates a staged
  ipset or per-IP chain atomically; the live kernel target survives interrupted bookkeeping.
- Pre-activation failures retain the previous rules. Post-activation cleanup/probe failures
  retain the new rules and report failure. No error path intentionally reopens the network.
- Both launchers report refresh failures; initial lockdown failure still prevents purge
  and agent startup. REJECT remains the normal blocked-connection path.

Image packaging and deployment are separate from these source-mounted regressions.
The existing image is not updated by editing scripts on the host.

### Copilot credential guard (N3), 2026-09-23

Five further shim-based caller cases cover the `run-copilot` credential guard:
`n3-login`, `n3-no-token`, `n3-oauth-env`, `n3-stored-oauth` and `n3-unparseable`.
Each must exit 78 with the refusal message, and must do so before any `curl`, firewall
call, credential purge or CLI start. No synthetic token value may appear in the output.
The existing Copilot success scenarios now supply a synthetic PAT, keep a PAT-only
`config.json` and export `GH_TOKEN`/`GITHUB_TOKEN`. The fake CLI must receive the PAT and
neither of the other variables. All values are synthetic; no real credential is read.

Recorded 2026-09-23: `--callers-only` returned **9 passed, 0 failed** (2 Claude, 7 Copilot).
The same fixtures run against the previous launcher failed both `n3-stored-oauth`
(exit 77, not 78) and `refresh-warning` (`GH_TOKEN` reached the CLI), so they detect the
missing guard. The default runner therefore has 64 scenarios.

These are source-mounted checks with a fake CLI. They do not show that the real CLI
authenticates with a PAT, that a PAT's permissions are narrow, or that the image contains
the new launcher; the baked copy changes only after an image rebuild. The live PAT check
is recorded in [SECURITY-REVIEW N3](SECURITY-REVIEW.md#n3-copilot-sign-in-token-capability-2026-09-23).
It covered headless Copilot 1.0.83 with the source-mounted launcher: the PAT was refused
push, fetch, private-repository reads and gist creation, and the real auth volume
was refused until its stored OAuth token was removed.

### Agent DNS closed (E6), 2026-09-23

The 54 firewall scenarios now also assert the E6 contract:

- The first two OUTPUT rules REJECT non-root udp/tcp port 53.
- Root DNS is accepted only to the configured IPv4 resolver; an IPv6 nameserver entry is ignored.
- No unrestricted port-53 ACCEPT remains.
- `/etc/hosts` stays root-owned 0644 with one pinned block, keeps podman's entries and
  never pins an ignored supplied name.

The pinned addresses follow the rules. Refreshes, including repeated alternation, write
the new addresses and remove superseded ones. Pre-activation failures keep the previous
names. Post-activation cleanup and smoke failures publish the new names. Interrupted
refreshes are checked after their retry. The fixture containers lack CAP_SETUID, so the
helper's non-root DNS probe is asserted to report itself skipped, never passed.

Recorded 2026-09-23: the full default runner returned **64 passed, 0 failed, 0 skips**
(54 firewall scenarios on both backends, 9 caller scenarios, 1 scoped-sudo scenario) in one
invocation.

N4 then added IPv6 default-deny. `locked()` now asserts that `ip6tables` has DROP policies
and exactly four rules: loopback in and out, and two REJECTs. The new `state-ipv6` scenario
reopens the IPv6 OUTPUT policy after lockdown and requires that `open` and refresh both
refuse, with the IPv4 rules unchanged. Recorded the same day: the full default runner
returned **66 passed, 0 failed, 0 skips** (56 firewall, 9 caller, 1 scoped-sudo).

Live check, same day, real image with the firewall and Copilot launcher mounted from
source, throwaway workspace:
- **Headless Copilot 1.0.83** (PAT) and **Claude Code 2.1.269** each answered their prompt.
- In both, the helper's production probe reported `non-root DNS refused`. Repeated after
  N4 with the final script: both CLIs still answered, and a real lockdown installed the
  expected IPv6 rules. The containers on this host have link-local IPv6 on `eth0`.
- As the agent user:
  - the allowlisted names resolved from `/etc/hosts`;
  - `github.com` was unresolvable, failing in 6 ms;
  - `dig` to the configured resolver and to `1.1.1.1` got no answer;
  - writing `/etc/hosts` was refused.

The allowlist additions came from a discovery run that logged only query names:
`api.business.githubcopilot.com`, the observed licence endpoint, and
`api.individual.githubcopilot.com`. Claude needed no additions. Not covered: interactive
sessions, tool calls inside Claude's bubblewrap sandbox, prepare-staged CLIs, Maven/npm
builds under the change, hosts with routed IPv6, and the image rebuild.

---

## Review-round imports (`verify-rounds.sh`)

Run `bash verify-rounds.sh` in WSL against the trusted scaffold for the Node fixture
suite. Add `--integration` to exercise the actual operator wrapper too; that mode
must start from an ordinary WSL Linux-filesystem directory outside the scaffold and
retained sandbox:

```bash
cd "$HOME"
bash /mnt/c/work/pera/claude-sandbox/verify-rounds.sh --integration
```

The wrapper integration creates and removes only its uniquely named fixture directory
under that working directory. It uses the existing image and disposable repositories,
not the assembled task workspace. No prepare, authenticated agent session or image
rebuild is needed. `--test-name-pattern recovery` selects only the Node recovery cases.

The required contract covers committed-only document export, exact packet checksums,
append-only import commits, clean/stale/in-progress repository refusals, unsafe paths,
source/target mount separation, active-container refusal and identical-packet replay.
Two-round cases must preserve prior agent commits, unrelated files and cache sentinels.
Hooks, filters and other repository-provided executables must not run during intake.

Interruption cases must include preparation before locks, staging, snapshot publication,
ref updates, index publication and interrupted recovery itself. A preparation journal
must exist before persistent Git locks. Individual refs and the index have separate
publication points; recovery must handle their partial outcomes rather than claiming
one crash-atomic transaction spans the filesystem and both refs. Only matching
journal-owned artifacts may be removed or completed; changed work must be preserved.

These synthetic fixtures establish import behavior, not that a new task's dependencies
are already cached or that its application tests pass. The real task trial, E1 image
deployment and model/reviewer orchestration remain separate steps.

Implementation: `292bed3` on `feat/sandbox-round-imports`; no retained task workspace
was changed and no image was rebuilt for this feature.

Recorded 2026-09-11: the initial 56 Node tests and actual WSL wrapper integration passed.
Three additional packet-boundary cases and nine fixture-cleanup cases were then covered
by a passing targeted run; wrapper integration was repeated after the cleanup guard changed.
At that point the suite contained 68 tests, not a claim that all 68 ran in one invocation.
Integration covers two rounds, preserved originals/caches, preview/replay/refusal paths and
the active-container guard. Cleanup retains fixture data if any surviving container still
mounts it or mount absence cannot be established.

Process-kill and interrupted-recovery cases are covered, not power loss or storage
corruption. The static baseline remains 21 passed, the unresolved S7 failure, 0 warnings
and 2 skips; no real task repository was used.

2026-09-13 follow-up: a real smoke preview exposed unchanged hydrated LFS assets being
treated as dirty when repository filters were disabled. The clean-state check now
verifies canonical staged LFS v1 pointers against regular-file mode, byte size and
streamed SHA-256 without invoking filters or downloading data. Targeted fixtures cover
unchanged payloads, changed hashes/sizes, staged changes, deletion, symlinks, mode
changes, non-LFS attributes, unsupported pointers and content-free dirty-path diagnostics.
Real smoke packets were previewed read-only after this fix; they were not applied.

### Retained-workspace smoke outcome

The user subsequently completed the two-round smoke trial on 2026-09-13:

| Repository | R1 import | R2 import |
|---|---|---|
| `prj` | `d4139f30070be96b14cb4c9056fd069043a388ff` | `c1f7b73da002bf9a3d4f19256372836d759894b3` |
| `Documentation` | `a221b8469538e1684e34a0b69b3a8feb3853b599` | `cd972c5857d878083cbb22467ad8f9be97bf4144` |

R2 was a direct child of R1 in each repository, added only its snapshot files and
left the R1 trees unchanged. Both R2 previews recognized the existing imports and
neither repository had a pending recovery journal. The saved post-R2 fingerprints
and a fresh read-only comparison matched all four pre-import cache samples.
This was a brief-import/cache-preservation trial, not an application build or
model/reviewer orchestration test.

## Outside-agent task operations (`verify-tasks.sh`)

The task-controller contract builds on the existing round assertions rather than
replacing their safety gates. Its fixture coverage must include:

- Strict registration, explicit ancestor audit bases, private state outside the
  workspace, stable branch/image identity and noncolliding round IDs.
- Committed selected inputs only, unchanged-brief no-ops, immutable plan IDs and
  packet/configuration/HEAD checks before an explicitly approved apply.
- Visible partial two-repo progress, matching recovery/retry, and no duplicate
  commits or implicit resets when one side already succeeded.
- Current retained-delivery integrity for no-op sends and completed-plan replay,
  including unchanged repositories in a mixed send. Historical receipts alone must
  not conceal deleted, changed or self-consistently forged input snapshots.
- Completed replay after legitimate later committed work, while refusing dirty,
  running, foreign-recovery, branch-switched or rewritten execution history.
- Structured clean/dirty/busy/running/recovery status without executing repository
  hooks/filters or treating stale recorded state as a live observation.
- Read-only collection with both full and focused diff bases, bundle reconstruction,
  checksummed package publication and baseline advancement only after complete export.
- Explicit handling of missing/unsupported LFS artifacts and visibility of edits to
  input snapshots, rather than successful-looking incomplete audit packages.
  Include temporary/reverted LFS changes in bundled history, not just endpoint diffs.
- Busy inspection of real conflicted rebases/detached HEAD without treating it as
  clean state, inventing an attached branch or claiming an unvalidated audit base.

`tests/tasks/repository.test.js` exercises the low-level `inspect`/`collect` additions
using disposable repositories. Existing round modes retain their own tests. No task
controller result establishes correctness of an application's code, validates a
profile's complete dependency cache or authorizes unattended model execution.

Run the combined suite from an ordinary WSL directory outside the scaffold and
retained workspaces:

```bash
cd "$HOME"
bash /mnt/c/work/pera/claude-sandbox/verify-tasks.sh --integration
```

The integration mode creates only uniquely named fixture directories/containers.
It exercises registration, chat-plan/apply separation, selected-source refs,
unchanged-input no-ops, paired and single-repo sends, audit collection, dirty/running
guards and an intentionally interrupted host wrapper. The orphan controller must
retain exclusive ownership of task state until its labelled container stops.
Missing engine/mount certainty retains fixture data rather than deleting it.

Recorded 2026-09-14: 44 Node cases passed, followed by the actual WSL task-wrapper
scenario and orphan-controller lock scenario. Code-source hashes stayed stable
through the run. These were disposable fixtures; no live task was registered,
sent, collected or launched, and no image was rebuilt.

Follow-up review tightened no-op/current-validity handling. Low-level inventory now
reconstructs each committed round packet and verifies its generated tree and working
snapshot, reporting `intact` separately from Git dirt. Controller checks bind those
observations to private approved plans and checkpoints. Malformed committed input
metadata remains visible and collectable for audit; it is not silently approved for
another handoff. Additional targeted cases cover these distinctions and task-scoped
prior entrypoints.

The follow-up retained/recovery/inspection selector passed 30 cases, and the collection
selector passed its four relevant cases. The real WSL wrapper scenario was rerun with
later-work replay and committed-input tampering: valid replay succeeded, while unchanged
sends and completed-plan replay refused the altered input without changing it.
The configured Node suite now has 63 cases; the recorded coverage combines the initial
full run and targeted additions rather than claiming a single 63-case invocation.

Implementation commits: `9786e80` (repository inspection/collection) and `0fb50c7`
(task controller and retained-delivery safeguards), on `feat/sandbox-task-operator`.
No real workspace was registered, sent or collected during this implementation.

### First live task: EEP-24, 2026-09-15

This is subsequent live-use evidence, not a replacement for the implementation
history above. The outside operator supplied
`Sandbox-Operator-Findings-2026-09-15.md` outside the scaffold. Its observations
were reconciled with the retained private task record, plans and two collection
packages, plus the host repositories' `refs/sandbox/EEP-24-round4` and
`refs/sandbox/EEP-24-round5`. No private packet/package contents are copied into
this repository.

The task attached an existing user-assembled workspace with `agencyWWW` reported
warmed. Registration recorded `prj` at `72d6b2801ffea0541938c263115d33169fafd0c9`
and `Documentation` at `71dcf749b3f0307eb1ea8f87aae6fa4597e8935d`, on their
EEP-24 task branches. The pinned image was
`sha256:893d19013d16066cacf386c442fd9d906f70792da74a046027f996ca7fed00d6`.
Image identity alone does not establish deployed E1 script parity or pin the
staged agent CLI version.

| Application pass | Operator handoff | Source commit | Documentation import | Collected prj / Documentation heads |
|---|---|---|---|---|
| Round 4 | R1 | `d8119d0082557ec3d898f5515a17738eab1c7837` | `5fefbfa86a4b49af244f57c6b5647be177bbd81d` | `2a68f8c9d5a5cd600179982ca311ce34e6900885` / `54c50a5a14b5a951f44f9a7e0f67096f8672f7b9` |
| Round 5 | R2 | `8b56a781e75bc4b949234a156863dbed2e061b61` | `257401591c762b3a3c19b9d756051422bf9c90d3` | `1d6fc6b14d15d6d35e7c410305039d72c6314a14` / `e05cf81aed338a1b4f5b1bee264a4b5f45fa4230` |

Both send plans completed, with **Documentation-only imports and prj preserved**:

- R1 plan: `b9d855359d22c192146dd23b511691dd7cdada462da5071d7e331530f76851c5`.
- R2 plan: `fec2d83c7b4a21c45db3cf2fe139085fa830c0546f87f0cc37218517b6303b6f`.

R1 supplied the missing visual harness; the round-4 brief already existed in the
clone. R2 supplied the round-5 brief, host-amended implementation log, a Markdown
document carrying the scroll probe and its textual summary. The shared README
was not selected. Application round numbers and controller handoff numbers are
different namespaces.

| Collection | ID | Root manifest SHA-256 |
|---|---|---|
| 1 | `da678b6ce1524ddf3a219ee548c97581a3e5c4f51ab78aca0d82df7a7c9ebb4e` | `331419860b7afa6ea1f628cefef4aaa5bfd5643fd853b579b78f6dccdfdb16a9` |
| 2 | `78a74bcfa54184681d032b37f0dc4bef10bcfa2a726d71aed1ef1e83a8282c17` | `ab7d54abb0ac86042515dd42e3904e0d5e74d6eb74c5563bc9afc67ede3bed32` |

The maintainer's read-only follow-up recomputed both root-manifest hashes and
matched every listed patch/bundle SHA-256 against the retained artifacts.
Collection 2's Documentation full diff is 395,270 bytes and its focused work diff
59,065 bytes: their bases straddle the R2 import. This demonstrates why the focused
diff is useful without replacing the full history.
Evidence remains in
`${XDG_STATE_HOME:-$HOME/.local/state}/pera-sandbox-tasks/EEP-24/collections/`
and the retained host provenance refs. This follow-up did not run a new task,
import, collection or application build.

The operator reported that registration refused while an agent container held the
workspace, and low-level inspection returned `running` with
`observedWorktree:false`. It also reported both approval/apply sequences and intact
input inventories. Retained receipts support the completed import/collection
identities; they are not a transcript independently establishing every interaction
or who approved it.

Host audit commits `4196ec710` and `e6964fe16` record acceptance of application
rounds 4 and 5. The latter records local-deployment confirmation of the background
scroll fix, while leaving scrollbar appearance and post-close motion observations
open. The intermediate harvest `90888350a` deliberately excluded the stale-base
README; the later audit reconciled it. These application records are not scaffold
containment assertions.

The report additionally records an unmodified-tree `verify-tasks.sh` run of
63/63 Node cases in 157 seconds on 2026-09-15. This is attributed operator evidence,
not a claim that the maintainer reran that suite during documentation closeout.
It supplements the dated 44-case run and later targeted additions above.

**Not exercised by this live trial:** interrupted import/recovery, foreign locks,
busy rebase/detached states, partial two-repository sends, same-plan retry,
unchanged-input no-op, completed-plan replay, LFS handling, reduced-access
behavior, multiple tasks/workspaces/images, or registration of already-in-progress
work. Existing fixture coverage for some of these remains distinct from live use.
Both application passes used Claude via `run-agent`; a Copilot container was
started and exited without implementing work. The trial does not establish
Copilot execution behavior, mandatory reviewer/model orchestration, comprehensive
cache identity, or stronger unattended-isolation guarantees.

**Operational gaps remain:** required-context discovery, source/canonical document
drift and write-back ownership are not enforced by the controller. The current
runbook adds explicit operator decisions and reviewed harvest guidance; it does
not implement automatic synchronization, attachments or integration.

### Declared-context foundation (phase 1), 2026-09-16

`tools/tasks/context.js` implements the pure handoff contract, not a new operator
command. Its repository identifiers are supplied by the caller; there are no
PERA repository names or ticket paths in the contract logic. The current controller
still uses its existing `prj`/`Documentation` registration and adapter. Generalizing
the workspace runner, build profiles and repository registration is separate work.

The module validates a closed handoff schema, carries declared documents forward,
records explicit retirement/role/reason changes, classifies drift against separate
source/target observations, and assesses per-handoff write-back decisions.
It reuses the round importer's existing document-path validator and limits through
additive exports; packet rendering and import behavior are unchanged.
Content comparisons use mode, size and SHA-256 rather than commit identity or
Git-format-specific blob IDs. Missing, unsupported and unobserved states remain
distinct; none supplies an invented clean baseline.

Targeted coverage in `tests/tasks/context.test.js` includes caller-supplied
single-repository, three-repository and legacy two-repository layouts, omission
of a previously declared README, retirement, metadata-only declaration changes,
first observations, legitimate sandbox-only changes, unchanged divergence,
SHA-1/SHA-256 provenance, and decisions that cannot waive unavailable context.
These are pure-data cases, not new live workspace or handoff evidence.

Recorded 2026-09-16: the existing task runner's `context|closed config` selector
passed all 27 context cases plus the existing closed-config compatibility case.
The runner also reports an unmatched repository-test file as a passing file entry;
that is not another exercised case. This was not a full controller/integration run.

**At phase-1 completion, not wired yet:** `--handoff`, document observation by the runtime helpers,
version-2 task metadata/plans, context-aware status/collection, and generated
handoff path maps. This phase creates no registration, updates no private task
state, and changes no live sandbox or application repository. Decision results
are proposed handoff instructions, not automatic canonical-file edits.

### Read-only document observations (phase 2), 2026-09-16

`sandbox-round.sh inspect` now accepts optional repeated `--path` arguments.
The trusted source helper accepts optional document paths alongside its named
source ref, and the task broker can forward that bounded list. No normal task
command selects these paths yet. Calls without document paths preserve the
previous source/inspection JSON shape.

Both helpers reuse `observeDocuments` in `tools/rounds/rounds.js`. The reader takes
a Git-byte callback, pinned commit and literal path list, with no repository-name
assumptions. It returns only path/observation pairs compatible with the phase-1
contract. It checks object size and Git blob identity before classifying text,
and preserves line endings/BOM bytes in the content hash. Missing tree entries
are distinct from Git/I/O failures. Executables, symlinks, directories, oversized
documents, invalid UTF-8/NUL content and LFS pointers are not represented as usable
document contents; they return explicit unsupported observations.

Source reads use the named committed branch, not the current checkout or working
edits, and refuse source-ref movement during an observation. Target document reads
require clean stopped state and recheck HEAD, the copied/real index, worktree
cleanliness, operation markers and recovery state before returning. Running,
dirty, busy and recovery-required cases produce unobserved entries, without
fresh document commit/hash claims. Neither helper applies document edits, runs
filters/text conversion, or imports external ancestry.

Recorded 2026-09-16: the existing task runner selector
`observations|source helper retains|repository inspect|LFS` passed 53 named cases,
including all 30 new observation/source cases, existing observation-contract
cases, retained-input inspection and LFS collection regressions. Its TAP total
of 54 also includes an unmatched controller-test file entry, not another case.
Test-only preload coverage changes the worktree, index, HEAD, a Git lock or private
pending state during a read; each observation is refused and the injected data is
left in place rather than rolled back.

The actual WSL wrapper's focused scenario also passed:

```bash
cd "$HOME"
bash /mnt/c/work/pera/claude-sandbox/tests/tasks/wrapper-integration.sh \
  --image localhost/pera-sandbox --observations-only
```

This uses disposable repositories and private fixture state, verifies unchanged
legacy output and source/workspace bytes, and exercises read-only source/target
mounts plus missing, dirty and running outcomes. Cleanup retains the existing
all-container mount guard. No live EEP-24 registration, import, collection, agent
run, image rebuild or prepare was performed; the full task-controller integration
scenario was not rerun for this phase.

**At phase-2 completion, still pending:** the `--handoff` interface, version-2 metadata and approval plans,
automatic context comparison in task status/send, context-aware collection
identity and generated handoff maps. Low-level observations do not establish
handoff completeness or authorize canonical write-back by themselves.

### Context-aware controller wiring (phase 3), 2026-09-16

`sandbox-task.sh send TASK --handoff FILE` now captures a private, owned input
outside the workspace, source repositories, scaffold and controller-state tree.
Capture is bounded to 1 MiB and uses files rather than a large command-line JSON
argument. The controller independently checks fatal UTF-8 decoding, a single JSON
value and equality with the captured request before interpreting the handoff.
Malformed JSON diagnostics do not echo the body; I/O failures remain explicit.

A successfully prepared context plan upgrades private task metadata to version 2,
without changing the closed version-1 registration config. Legacy tasks keep their
previous behavior until explicit opt-in. Existing pending/partial legacy sends
must be resolved first; opted-in tasks cannot bypass declarations with a bare send
or `--brief`. The applied context is recorded as `lastContext: {revision, planId}`.
Validation binds that pointer to the latest fully applied revision chain, not merely
to an arbitrary historical plan with a valid digest.

Context plans capture the effective declared set, both sides' observations,
per-handoff handling, source packets and actual snapshot path mappings.
Previously declared documents survive omission; exact replay of the last handoff's
completed retirements remains idempotent, while unrelated unknown retirements fail.
Missing decisions return a diagnostic without an applicable plan ID or baseline
change. Source advancement after approval does not replace the pinned input.
Reconciliation/initialization decisions remain guidance, never automatic edits.

Metadata-only plans have `round: null` and advance context only, preserving Git
heads, last import round, execution heads and collection heads. Version-2 collection
identity includes `binding.context: {revision, planId}` and the corresponding approved
provenance. Thus an unchanged Git candidate can still need a new audit package.
Committed canonical drift remains collectable without consulting current source
contents. Historical plan replay never rewinds the active context.

`status.context` reports current per-document drift independently of workspace
health and retained-input integrity. Plan/apply/collection context is explicitly
labelled `captured-approval`, not a fresh source observation. The path map's
write-back owner honors host deferral even when a document remains declared shared.
These distinctions are documented in `OPERATOR.md`.

Recorded evidence on the combined source:

- The task-specific Node runner passed **156/156 named cases** in one invocation,
  including the existing legacy behavior and the context-aware controller cases.
- The actual `wrapper-integration.sh --image localhost/pera-sandbox --context-only`
  scenario passed against disposable repositories and private fixture state. It
  covered private file/path/permission/link/size guards, malformed UTF-8/NUL and
  multi-value inputs, v2 opt-in, unchanged replay, captured-file mutation after
  preparation, carried-forward README drift, decisions, imports and collection.
- Its metadata-only case includes earlier committed work, so accidentally advancing
  the execution/work base would be observable. It confirmed a new collection at
  identical Git HEADs, retained work-base coverage, collectable canonical write-back
  and non-rewinding historical replay.
- Static assertions retain the known baseline: 21 passed, S7 unresolved, 2 skips.

No live task was opted in, and no real application workspace, source branch, image,
agent settings or warmed cache was changed. Broader phase-4 wrapper/orphan-lock
integration and a separately authorized real-task rollout remain distinct from
this phase's evidence. The feature neither generalizes the current two-repository
adapter/build profiles nor provides automatic merging, agent launching or stronger
unattended containment.

### Review follow-up: superseded-plan reselection, 2026-09-16

The independent Phase 1-3 review identified an A-to-B-to-A preparation defect.
The legacy path persisted a superseded plan as active and could no longer apply
it; the new context path rejected the inconsistent registry before saving.
The legacy assignment pattern predates the declared-context feature.

Reproduction was added before changing implementation. All three disposable cases
failed as predicted: legacy apply reported `Plan was superseded or is not the active
approval`; normal and metadata-only context preparation reported `Context active
plan registry is inconsistent`.

Both preparation paths now use the same guarded activation helper. It requires
eligible pending/superseded progress without receipts, revalidates an existing
plan's immutable bytes/packets and round, and only then supersedes the current
pending choice and activates the selected one. Completed, applying and partial
progress, receipt-bearing entries and damaged approvals are refused without changing
either registry entry. Plan IDs/contents remain unchanged; no import occurs until
an explicitly approved apply.

The focused post-fix run passed 20 named cases: the three reselection cases,
activation/receipt protection, damaged-plan refusal, and related current replay,
metadata-only, partial-apply and journal/lost-receipt recovery cases. TAP reports
23 entries because three unmatched files are also counted; those are not extra
exercised cases. The earlier 156-case run remains historical evidence, not a claim
that the full suite was rerun after this fix.

No live task record was inspected or repaired. At that point, broader Phase 4
wrapper/orphan-lock integration remained pending. The other review observations (source-unavailable
diagnostics, snapshot-recency preference and validation-cache scaling) were not
changed as part of this fix.

### Phase 4 closeout and next pilot, 2026-09-16

The combined `verify-tasks.sh --integration` run completed successfully after the
superseded-plan fix. Its source-hash guard covered the same helper/test bytes
throughout the run. This is a single combined run, distinct from the earlier
targeted and phase-specific evidence:

| Component | Result |
|---|---|
| Task Node cases | 161/161 passed; approximately 450 seconds for this portion. |
| Legacy CLI wrapper | Passed registration, paired/single-repository sends, no-op/replay, collection, dirty/running and retained-input guards. |
| Context-aware CLI wrapper | Passed private intake, v2 opt-in, carried declarations, decisions, metadata-only collection, canonical write-back and non-rewinding replay. |
| Orphan-controller lock | Passed intentional host-wrapper interruption: another operation was refused until the labelled orphan controller stopped, then status succeeded. |

Both real CLI workflows now also exercise prepare A, prepare B, prepare A again:
the original plan ID returns to pending, the replacement remains superseded,
planning leaves the workspace unchanged and the selected plan can be applied.
The legacy tamper scenario compares the entire saved plan registry rather than a
fixed plan count. The runner announces each major component so its progress is
visible during the lengthy sequential container scenarios.

The combined run and its owned-fixture cleanup completed with exit zero. No live
task state, application/source repository, warmed workspace, agent configuration,
image build or prepare was changed. This closes the planned operator-feature
regression phase; it is not application acceptance, complete P/A/G/X containment
coverage, or proof that the broader sandbox security backlog is resolved.

EEP-24 is finished for the time being. The user designated **JWA-2905 Legislative
work** as the next supervised live pilot. It was not registered, imported or
launched by this closeout. Pilot setup must separately establish its actual
source refs/briefs, retained-workspace branches, explicit audit baselines and
required warmed profiles. Do not reuse EEP-24's registration or infer that its
agency preparation satisfies the new task. Any workspace change or dependency
top-up remains an explicit decision; no reset or re-warm is implied.

The non-blocking review observations about source-unavailable diagnostics,
snapshot-recency preference and validation-cache scaling remain follow-ups.
The combined run was not a latency benchmark identifying their runtime cost.

### Pre-pilot agent operating contract, 2026-09-16

Subsequent ticket-lead feedback prompted a documentation-only refinement in
`OPERATOR.md`, linked from the startup guides and scaffold agent guidance:
one ticket lead writes the shared host checkouts, the operator helper prepares
and collects, and a fresh reviewer returns findings outside those checkouts.
The reviewer preserves a first technical assessment before a second pass with
the brief/rationale; essential requirements and mandatory instructions are not
withheld merely because they reside in documentation.

Only the designated human can approve the exact plan. The default delegated
workflow keeps apply with the human-facing lead rather than relaying an agent's
approval claim through the operator. The lead also commits the sanitized ledger
of actual approval references, receipts and outcomes. Separate sessions and this
charter do not add OS permissions or human-authentication enforcement.

Before the autonomous pilot, capture and retrieval of execution evidence must
be demonstrated for the chosen CLI/setup with a separately approved harmless
probe. The lead retains selected private session artifacts and records human
review and evidence gaps. This is a procedural gate: transcript capture/export,
reset prevention and role enforcement were not implemented in the controller or
launchers. A ledger is not a transcript; persistent CLI-config volumes are not
proof of complete or tamper-proof run evidence.

No pilot, logging probe, session export or transcript review was performed by
this documentation change. JWA-2905 still requires task-specific preflight,
human operation approvals and the evidence demonstration before its first run.
The successful Phase 4 fixture evidence above is unchanged.

### G1 verification guidance and G6 host recording, 2026-09-17

The approved follow-up adds exit-status propagation, current-build artifact
assertions and actual executed-test counts to `overlay/CLAUDE.md`. This changes
the source payload only; no assembled workspace instruction files were refreshed.
Application behavior and compliance with that guidance were not tested.

`sandbox-record.sh` adds optional **host-side terminal recording** around an
explicitly supplied launch command. It does not change either image-installed
launcher, the firewall, policy hook, task controller or CLI version/model settings.
It keeps invocation arguments, terminal output/timing and launch/recorder outcomes
in fresh private directories, publishing hashes only after finalization succeeds.
It does not copy auth volumes or export CLI sessions. A returned launch, including
exit zero, is not evidence that an agent completed its brief or passed tests.

Recorded against WSL `centos-9`, util-linux `script` **2.37.4**:
`bash verify-recording.sh` passed **16 disposable local-PTY checks** covering
argument preservation (quotes, spaces, shell metacharacters, empty and multiline
arguments), terminal stdout/stderr, private permissions and hashes; launch exits
42 and 125; hidden-input non-capture; live output flushing; an owned recorder's
SIGTERM and partial retention; terminal Ctrl-C and resize propagation; non-TTY,
unsafe-permission, symlink and workspace-overlap refusals; a recorder that exits
zero without running its command; hash-publication failure; and repeated-label
non-overwrite behavior; and default storage under a disposable XDG state directory.

The Ctrl-C regression exposed Bash's ignored INT/QUIT dispositions on asynchronous
commands. The recorder resets them with GNU `env --default-signal` before starting
`script`, while retaining explicit stdin and signal forwarding to its own recorder.
These are host PTY checks, not evidence about Copilot's UI or session-event schema.
The verifier uses existing Python 3 standard-library PTY support, without an
additional package, container, credentials, network access or agent session.

Static scaffold assertions remain **21 passed, 1 known failure S7, 2 skips**.
The S7 finding and absent shellcheck/VERSION are unchanged. No existing private
evidence store was accessed; no ticket checkout was modified or used as a probe fixture.
No image was rebuilt, workspace prepared, agent launched or JWA-2905 work dispatched.

**Pending at this checkpoint:** the ticket lead must demonstrate this recorder with the actual
intended interactive CLI, executable and guarded launch, correlate retained CLI
events, and obtain human review. Normal exit/interruption, redraw/input behavior,
and the output that the CLI actually emits cannot be established by local fixture
success. Headless/subagent capture and complete authenticated activity logging
remain outside this change. See `OPERATOR.md` for the capture and deployment contract.

### First live context-aware ticket: JWA-2906, reported 2026-09-22

This is **attributed field evidence**, not a new execution of the application or
controller suite by the scaffold-maintenance session. Sources are the ticket lead's
`Sandbox-Operator-Findings-2026-09-22.md` and the JWA-2905 Documentation records:
`02-planning/sandbox-pilot-log.md` and
`03-tasks/JWA-2906-verified-time-workflow/audits/round-01-{review-packet,consolidated-findings,erratum}.md`.
The raw field report is kept outside the scaffold, like the 2026-09-15 report, at
`C:\work\pera\Sandbox-Operator-Findings-2026-09-22.md`, unchanged (SHA-256
`eeeb6d64a3f508ee88b38234bf4460c024e088280e492240ea9ee1e545a3bae3`). Its G1
attribution is withdrawn below; it is not required to run scaffold checks. The assessment read those records and current scaffold source,
but did not rehash the private collection/session artifacts or rerun application
acceptance. Historical entries above remain point-in-time records.

The ledger records the G1 instruction refresh and a three-run actual interactive
Copilot recorder demonstration before the ticket run, with human review accepted.
Those later activities were performed by the ticket/operator workflow, not by the
source-only G1/G6 implementation recorded above.

| Identity | Recorded value |
|---|---|
| Task / round / contract | `JWA-2906`, R1, private record v2, context revision 1 |
| Approved plan | `f1ec158544e9493c701c61bed9571fb3afbc4dcc507c9153c96fa35496f9f4d5` |
| Source Documentation | `ec4e2eb42be4c1261151b4e6f3f6aae71bd2cf25` |
| Image | `sha256:893d19013d16066cacf386c442fd9d906f70792da74a046027f996ca7fed00d6` |
| Runtime | Copilot CLI 1.0.83, interactive guarded launch with host recording; retained warmed workspace |
| Session | `a370a142-b366-4b3f-aa0b-d57bb00fe9c8` |
| Candidate prj | `48815eba7f6c3d64e9b5620949093b9556d57faf` |
| Candidate Documentation | `f99834d180d14e097a456ec836db023b225f5795` |
| Collection | `2e8687c718ee3df6afa1e207b89eb9619ceaaae2bfeb8a7761edc3c950e77518` |
| Root manifest SHA-256 | `af884a64c080933a1361e4efbb10e02ea6b18db23568abde801db308c7854abf` |

Reported outcomes:

- Only Documentation imported R1; prj stayed at its code baseline during send.
  Both selected document snapshots matched approved hashes. The agent used the
  snapshot paths and respected the README's section boundaries. Section ownership
  was prose guidance, not controller or filesystem enforcement.
- Both candidate trees were clean; all nine collection artifacts and both bundles
  were verified by the lead. Code-only host integration is recorded as `32818a0a2`,
  with a subsequent host suite run and deployment reported. Collection itself
  explicitly reported `applicationTestsRun: false`.
- The event record reports 158 started/completed tool calls and routine session
  shutdown. The suite result was `TOTAL: 270 SUCCESS`, `EXIT=0`, up from 250.
  These counts and exit evidence do not establish all acceptance criteria.
- An interrupted preparation was retried without reported repository mutation.
  Retained staging remained. This was not interrupted import/recovery coverage;
  deterministic plan identity is already covered separately by fixture regressions.
- A host restart after the agent's clean exit left terminal output, timing and
  launch metadata but no recorder outcome or final checksum manifest. The lead
  preserved and identified an incomplete capture, hashing surviving output later.
  Those later hashes pin the recovered bytes, not capture-time completeness.
- Execution evidence upheld omitted failed restoration outcomes and corrected the
  lead's own false discrepancy: nine test executions occurred in eight tool calls
  because one call contained a two-iteration loop. The erratum preserves the
  reporting criterion's failure and the unresolved intermediate-commit question.
  The two-pass review used the same reviewer resumed for pass 2, not two independent
  opinions.

The linked audit also found that criteria extraction omitted or weakened governing
requirements, and reviewer startup context exposed campaign narrative. The operating
contract now requires source-bound, requirement-preserving criteria; inspection of
reviewer startup context; and traceable runtime evidence in pass 1. Reporting-only
errata, section-ownership limits, explicit-plan approval wording and references to
excluded harvest material are clarified. These are procedural improvements, not
new runtime enforcement.

Follow-up findings use **2026-09-22 field-report G1-G10**, distinct from the earlier
probe-gap numbering. The reported read-only Git chain was denied citing
`shell(git remote)`. A local evaluation on 2026-09-22 of that exact command as input
to the current `guard-shell-command.js` returned `{}` (no veto); the command itself
was not executed. This does not reproduce the CLI permission matcher or establish
its cause. The launcher deny flags and policy are unchanged pending a bounded
pinned-version reproduction. Escaped-quote denials remain intended policy behavior.

No shell timeout was reported in this Angular run. That corrects the earlier
prediction that every invocation would exceed 60 seconds; it does not qualify all
Angular runs or Maven, nor address EEP-24's separate slow controller-preview
observation. A canonical brief remaining stale is consistent with append-only
snapshot delivery; the path map is guidance, not read isolation. Hiding or renaming
canonical files, automatic pruning and crash-time hash guarantees are not implemented.

Live coverage still excludes paired repository imports/partial retries, interrupted
import recovery, a second context-aware round, Maven under the guard, LFS,
reduced-access cases, concurrent tasks, another workspace/image, headless/subagent
evidence and Claude Code under this context-aware contract. Existing disposable
regressions cover some of these separately; do not label them live-ticket evidence.
The CLI version was held by the operating procedure, not a new enforced version pin.

### Bounded maintenance follow-up, 2026-09-22

`OPERATOR.md` now distinguishes an independently identified recovery receipt for
an incomplete recording from original recorder finalization. It also defines
inspection/approval conditions for exact `.operation-*` and `stage-send-*`
disposal, excluding live owners, overlapping mounts, pending recovery, published
artifacts, collection staging and lock files. Both procedures require preserving
relevant evidence and rechecking current state; they add no automatic recovery or
garbage-collection command. No real recording was finalized, staging removed or
private artifact copied while writing these procedures. They have not been exercised
against the reported leftovers.

The initial CLI-denial reproduction is scoped to a new disposable repository and
an interactive recorded session on the unchanged guarded 1.0.83 launcher: compare
the exact reported read-only chain with its component commands and a read-only
remote-listing control. No push/remote mutation or guard weakening is needed for
that initial probe. Read-only preflight confirmed the reported image ID is still
available and the config volume exists, without inspecting its contents.
At this documentation checkpoint, no authenticated probe had been launched;
mode-specific execution, evidence custody and exact fixture cleanup still required
a separate approval. The subsequent approved probe is recorded below.

Documentation checks: `verify-scaffold.sh` retains the baseline result of
21 passed, S7 failed, 2 skips. Besides the longstanding defaults, S7 also reports
literal historical paths in the newly supplied, unchanged untracked field report.
Those report lines predate this closeout; neither the report nor the assertion was
altered to hide them. No runtime regression suite or application build was needed
for these documentation-only changes.

### Git-denial probe: not reproduced, 2026-09-22

Following separate human approval, a fresh synthetic Git repository was mounted at
`/workspace/Documentation` in a disposable container. It contained one synthetic
commit, no remotes and no application/ticket data. The retained ticket workspace
was not mounted. The human ran the interactive launch and confirmed exit; the
maintenance session prepared the fixture and retained/analyzed the resulting
evidence. No additional variants or second authenticated run were attempted.

| Identity | Observed value |
|---|---|
| Probe | `GIT-DENIAL-20260922` |
| Image | `sha256:893d19013d16066cacf386c442fd9d906f70792da74a046027f996ca7fed00d6` |
| CLI | Image-baked Copilot 1.0.83; confirmed offline and in `session.start` |
| Launch | Unchanged `run-copilot` and policy, all deny flags retained, host recorder, interactive `--interactive` prompt |
| Model on all five tools | `claude-sonnet-5` after automatic resolution from the seeded default |
| Session | `a946fb1d-29cf-4431-8c16-4056e181a94c` |
| Recording | `GIT-DENIAL-20260922-20260922T173508Z-2Zpnna` |
| Synthetic fixture HEAD | `84a19b3aa8b467be8bc83ee76410c39d4e085c61` |
| Events SHA-256 | `b71f102fa79b528022021e8e1cd46aca6b11fa2912cebca5b653bfe4a8467f0c` |
| Private evidence manifest SHA-256 | `3b0bd2686a426adf38c11cbb58c6a9c73c51b1b256d051665f61548a70a4b089` |

The captured user prompt matched the prepared prompt. All five `bash` calls were
submitted exactly as specified, in order, with five paired completions, five hook
invocations and no extra tool calls. Each case began with
`cd /workspace/Documentation &&`; the commands after that common prefix were:

| Case | Command | Observed outcome |
|---|---|---|
| A | `git branch --show-current && git --no-pager log --oneline -3 && git status --short` | Executed, explicit completion trailer exit 0 |
| B | `git branch --show-current` | Executed, explicit completion trailer exit 0 |
| C | `git --no-pager log --oneline -3` | Executed, explicit completion trailer exit 0 |
| D | `git status --short` | Executed, explicit completion trailer exit 0 |
| E | `git remote -v` | Denied, `error.code: denied`; no command exit status |

E's verbatim reason was:

```text
Permission to run this tool was denied due to the following rules: `shell(git remote)`
```

This positive control shows the deny rule was active; the exact chain reported
as a false positive in JWA-2906 was allowed.
No guard or permission override was applied after a denial.

Session association used before/after config-volume listings: exactly one new
session directory and process log. The session ended with `shutdownType: routine`.
The recorder returned command/recorder/wrapper status 0, with no interruption, and
all six artifact checksums verified. Explicit completion trailers established the
four command exits; neither tool `success: true` nor absent failure metrics was
treated as proof of an exit code.

Private artifacts remain under the probe-specific
`pera-sandbox-probes/git-denial-20260922-DuaW0m` state directory: selected session
events/metadata/process log, the fixed prompt and launch preparation, correlated
per-case results, recorder output/timing and a 28-artifact manifest. They are
readable by the normal host user with private permissions. Only selected artifacts
were copied, not the auth/config volume. Existing auth state was used for the normal
provider connection and gained the new session's state.

Before cleanup, an offline, read-only container confirmed the fixture HEAD was
unchanged and its worktree clean. Its synthetic content also matched the retained
seed; no container mounted it. Only the disposable Git metadata and fixture file
were removed, followed by their empty parent directories. The private recording
and evidence were retained; no ticket checkout, prior evidence or running unrelated
container was modified.

**Conclusion: the reported false positive was not reproduced, not fixed or
disproved.** This was a new session and synthetic repository, not the original
task/history. The observed model was `claude-sonnet-5`, whereas the ticket report
records `claude-opus-5`; the prompt was automatically submitted in interactive
mode rather than manually pasted. Those differences are recorded, not asserted
as causes. The original incident remains unresolved. Inspect its exact request
and permission-event provenance before deciding whether a further approved
reproduction is needed; this result does not justify weakening the deny flags.
Human confirmation of the interactive run's completion is not recorded as a
separate human acceptance of this analysis or a complete sandbox security review.

### Original-record inspection: correcting field-report G1, 2026-09-22

The subsequent read-only inspection resolves the attribution that the probe alone
could not. The original retained evidence is
`~/.pera-evidence/JWA-2906-R1/session/events.jsonl`, session
`a370a142-b366-4b3f-aa0b-d57bb00fe9c8`, CLI 1.0.83. All **15 entries** in its
retained checksum manifest verified. The manifest SHA-256 is
`e8ae6256f50c3b59298591009e174dd4e0166bd76431a1f67ccdb143fe4f2c51`;
the event record SHA-256 is
`cac0cadcd5f4b1fcecf338152ad40e06acbb83452c3bca2f7a20e9fe77c7516a`.
These checks establish consistency with the retained manifest, not independent
authenticity of an agent-writable record.

All 158 tool starts and 158 completions had unique, matching `data.toolCallId`
values. Joining on those values gives the following two calls, submitted together
at approximately 05:30:12Z on 2026-09-18:

| Call | Tool-call ID | Actual request and result |
|---|---|---|
| prj inspection | `toolu_01U9kCgy7s7vYdyQSKGMoFvR` | The command inspected `/workspace/prj` and ended with `git remote -v`. Denied with `error.code: denied`, citing `shell(git remote)`; no command exit status. |
| Documentation inspection | `toolu_01GGiJfUi8zRZpDAHBAo8KFL` | Branch/log/status inspection ending with `git status --short \| head`. Allowed, with an explicit completion trailer reporting exit 0 for the composed command. |

The actual Documentation command was:

```bash
cd /workspace/Documentation && git branch --show-current && git --no-pager log --oneline -3 && git status --short | head
```

The field report's version without the trailing `| head` occurs **zero times**
as an exact submitted command in the original record. Its single matching prefix
is the successful call above. Only the prj call has a `shell(git remote)` denial;
the other two denials in the session are the documented escaped-quote hook vetoes.

The denied completion event is `9df66850-1af1-422d-bed1-2fa173c05c10`.
The successful Documentation completion is `8f6a6520-e607-4bd9-9279-3c57ae5f6e75`,
whose **`parentId` points to that denied completion**, not to its own start.
The two starts and their shared hook batch interleave with the completions.
This demonstrates why event-history links or proximity cannot identify which
request a result belongs to. The record establishes the report's misattribution,
not the specific extraction method that produced it.

**Disposition: withdraw the 2026-09-22 field-report G1 false-positive allegation.**
The recorded prj denial matches the configured rule; the Documentation inspection
was not denied. This is a reporting correction, not a permission-matcher fix.
The earlier synthetic probe remains valid as recorded, but its model/session
differences need not be investigated to explain this misattribution. No further
authenticated probe, deny-rule change or image rebuild is warranted for this
incident. This does not establish that every possible permission match is correct.

`OPERATOR.md` now makes the session-scoped tool-call-ID join explicit and requires
unmatched/ambiguous records to remain unresolved. The raw field report and original
evidence are preserved unchanged. The ticket lead remains responsible for appending
the corresponding erratum to its own ledger/audit records; this maintenance
inspection did not edit the Documentation checkout or rewrite either prior account.

### Approved G4/G6 housekeeping, 2026-09-22

The human approved an exact-path archive, not deletion, of the two reported
preparation leftovers: `.operation-b0081fbf-e0fa-47f7-8bf7-d75132166483`
(19 files, 9,934 bytes) and JWA-2906's
`stage-send-84a079bf-a58f-4351-ad9b-80ff556ed353` (one 61,185-byte packet).
Captured requests tie them to the interrupted export/preview, and the staged
packet is byte-identical to the published approved packet:
`554d3f26a0c7afd571e17fc485f0fdb9d99048cd4b0418c6e6794dbe36d684c4`.

The controller reported ready/clean candidate repositories, intact input snapshots,
no active plan and no pending import. The archive revalidated exact inventories,
published-state references, mount absence and recovery state while holding the
existing task/workspace locks. Relevant inspected processes held no candidate
references. Descriptor metadata for unrelated SSH/PAM services was inaccessible;
this limitation was disclosed in the approval and receipt, not treated as an
exhaustive system-wide open-file check.

Both directories were renamed with their bytes/modes preserved into private
`pera-sandbox-maintenance/JWA-2906-20260922` host state, outside controller state.
Its 22 retained files include the inventory and receipt; the manifest SHA-256 is
`f591cb82efd636a96e272be346558d0df171b125149b2795b33a87c8493e9051`,
and the receipt SHA-256 is
`00dfb91d344d2085722bc4d740e567336bc46d9b4ccdcad26b25802c2b4ef883`.
Published task/plan/collection/recovery file hashes remained unchanged. A subsequent
controller status again reported clean candidate heads and no pending operation.
Context remained changed after legitimate host/sandbox work; that was not reset
or silently reconciled as part of housekeeping.

The original incomplete recording's output/timing hashes and metadata matched
the existing retained evidence. It was left unchanged, with no replacement outcome,
manifest or duplicate recording copy. The same maintenance receipt records this
recheck; original capture completeness is not claimed.

### Checked launch-handoff generation (G3), 2026-09-22

The additive `sandbox-task.sh launch-handoff TASK` command returns JSON containing
copy-ready `text`, applied plan/context identity, observed repository heads and
provenance-backed input mappings. It uses the existing isolated controller and
observation helpers. No private state version, packet rendering, import semantics,
image-installed script, permission rule or canonical document was changed.

The separately approved freshness gate requires a fully applied v2 context,
no active send, clean/stopped repositories, intact retained inputs and selected
context unchanged since approval. It rechecks source observations and then target
state before returning. Approved divergence can be unchanged; its explicit handling
is preserved. Changed context is a refusal even if ordinary task status is ready.
The generator is neither launch approval nor read isolation and does not run an
agent. Legacy tasks retain their manual route.

Recorded checks against the existing offline image:

| Check | Result |
|---|---|
| Targeted Node run | **13 named cases passed**: 10 new launch-handoff cases and 3 existing context/status/pinned-approval cases. TAP reports 16 because three unmatched test files appear as placeholder passes. |
| Focused real CLI wrapper | `tests/tasks/wrapper-integration.sh --image localhost/pera-sandbox --launch-handoff-only` passed help/argument handling, refusal without applied v2 context, generated text/current heads, source/workspace/registry non-mutation, and refusal after selected-context drift. |
| Scaffold assertions | 21 passed, S7 failed, 2 skips; same baseline findings, including historical paths in the unchanged untracked field report. |

The new controller cases cover quoted literal paths; selected briefs and ownership;
all divergence decisions; reused snapshots after metadata-only approval, including
legacy-delivery reuse; pending/partial sends; changed source/canonical content;
dirty/running/busy/recovery/branch-switched state; retained-input corruption;
image drift and source errors; source changes during generation; and target changes
during both the initial and final source-observation passes. Repeated generation
is deterministic for unchanged observed state and does not save a registry entry,
plan or collection.

The existing context wrapper scenario also includes successful generation and
post-write-back refusal for future combined runs. This closeout ran the focused
scenario, not the full legacy/context/orphan-lock integration sequence again.
All new runtime checks used disposable repositories and network-disabled containers
without authentication volumes; fixture cleanup completed successfully. No image
rebuild, dependency prepare or new live ticket run was performed.

Actual next-ticket use and adoption of the revised two-pass review process remain
with the ticket lead. The completed JWA-2906 workspace was not reapproved merely
to make it eligible for this command: its legitimately changed context remains
unchanged by this feature's development.

### Personal defaults and overlay cleanup (I1–I4, C1–C3, D4), 2026-09-23

Static assertions: **22 passed, 0 failed, 0 warnings, 2 skipped**. S7 passes for the
first time; S3/S20 skip as before. Runtime evidence, all on the host or in disposable
state, never against the warmed task workspace:

| Check | Result |
|---|---|
| `new-sandbox.sh` preflight in `centos-9`, real environment, existing `~/pera-sandbox`, no `--force` | `%USERPROFILE%` resolved through interop, identity found, both credential files present; stopped at "already exists" with nothing written |
| Preflight failure cases, throwaway source repos, existing target | no interop → names `WIN_M2`/`WIN_NPMRC`; no identity, and name-only → identity error; `<` in identity → refused; missing `settings.xml` → refused. Overrides and repo-local identity pass preflight |
| Full `new-sandbox.sh` run, fake source repos and credential files, throwaway `SANDBOX_ROOT` | exit 0; both clones carry the supplied per-repo identity, no remotes, secrets mode 600; temp tree removed |
| New `prepare.sh`, source-mounted read-only, disposable `--network=none --cap-drop=all` containers, fake workspace | no identity → error **before** "Opening firewall"; `-e SANDBOX_GIT_*` → applied to both repos; existing per-repo identity → kept; `core.autocrlf=input` set |
| Overlay's Vitest command on host `prj` (`uat-member`): `ng test --project working-after-retirement --watch=false` | Vitest 4.1.5, 2 files, **84 passed** |

Not established: the baked image still carries the old `prepare.sh` and Copilot seed
until the next rebuild. An image built from the old `prepare.sh` still falls back to
the removed default, and would overwrite the identity `new-sandbox.sh` wrote, so a
workspace assembled now should be prepared only on a rebuilt image. The Copilot ID
`claude-opus-5.5` follows the dotted form found in the CLI bundle and has not been
confirmed with `/model` in a live session. Overlay text reaches new sandboxes only.

### Reset safety and required assets (V2, D5), 2026-09-23

New `verify-assembly.sh` (run in WSL; needs the existing image): **33 passed, 0 failed**
after the review fixes (22 in the first version),
in a throwaway tree under `$HOME` with fake source repos, credential files and task state.
It never references the real workspace. Cases: fresh assembly writes the marker. A reset of
a clean, harvested sandbox proceeds. Refused, with the workspace kept: an unharvested HEAD,
an unharvested side branch, a stash, a dirty worktree, a registered workspace, and podman
unavailable. `--discard-unharvested` proceeds. Containment refuses `$HOME`, outside
`$HOME`, inside or containing the source, and a symlink. A foreign directory is refused even
with `--discard-unharvested` and kept. The legacy layout is accepted. Missing assets are
refused, or warned about with `--allow-missing-assets`. Argument misuse is refused. Added after review: packed
branch and packed stash, an older stash entry, a malformed `packed-refs` line, a linked
worktree, an unexpected top-level file, nested and unreadable registrations, a trailing-slash
symlink, a symlinked asset, and asset placement with a tracked `.agents` file in the clone.
A running container mounting the workspace is refused even with `--discard-unharvested`.
Every refusal is asserted to keep the workspace, and no run may leave a tombstone.

Mutation check: the same 33 cases against the pre-fix `64dc722` script give **16 failures**.
They include T18, where the old script deleted a workspace mounted by a running container.
Several others fail partly because the old nested asset copy made every later check report
`dirty`, so the old silent loss of a packed stash is shown by the reviewer's replica rather
than by T10. A pending round recovery (`recovery-required`) is refused by code path but not
exercised: that needs a genuine interrupted import.

Read-only checks on the real host: `sandbox-round.sh inspect` reports the real `prj` and
`Documentation` as `clean`, so the git-ignored overlay does not make a real reset look
dirty. The harvested lookup for the real HEAD took about 2 s over the WSL mount and found
it only under `refs/sandbox/JWA-2906-R1`. `--force` was **not** run against the real
workspace. Static assertions: 22 passed, 0 failed, 2 skipped.

### Inner sandbox and guarded startup (E2/E3, E5, N5), 2026-09-24

New `verify-startup.sh` (run in WSL; needs the existing image; `--network=none`, no
credential, no workspace): **42 passed, 0 failed, 1 skipped** after the review fixes
(37 before them). `baked-layout` needs `--baked`; on the throwaway test image
`localhost/pera-sandbox-p3test` the `--baked` run gave 38 of 38 before the review fixes. Each scenario runs in its own container. The fixture
installs the source policy, wrapper and launchers, replaces both real CLIs with a recorder
and the firewall with a fake sudo, and runs the launcher or wrapper as `vscode` with every
capability cleared.

- **`run-agent` starts, with arguments preserved,** on the legacy project settings, the
  canonical copy and no project settings. In each case the five redirect variables are
  absent in the CLI, its capability sets are zero, lockdown ran first and the credentials
  were purged.
- **`run-agent` refuses with exit 78, before any firewall call and with credentials
  intact,** for 22 tampered inputs:
  - project settings adding `excludedCommands`, `allowWrite: ["/"]`, `bwrapPath`, a hook,
    `statusLine` or `apiKeyHelper`;
  - project settings with one trailing newline added;
  - a symlinked settings file, or a symlinked `.claude` directory;
  - `settings.local.json`, or `.mcp.json`;
  - user settings with `hooks`, `statusLine`, `apiKeyHelper`, `env` or `sandbox`;
  - user settings that do not parse, or that are an array;
  - a permissive `remote-settings.json`;
  - `.claude.json` with MCP servers at the top level or under a project, or that does not
    parse.
- **The wrappers refuse with exit 78**:
  - with no lockdown record;
  - when the record is owned by `vscode`, is a symlink or is a directory;
  - while running as root with capabilities;
  - when called as `claude --version -p …`;
  - under an unknown name.
- **The wrappers pass through or run:**
  - `--version` and `-h` pass through;
  - a guarded `claude` and a guarded `copilot` exec the baked paths, with the variables
    removed.
- **`run-copilot`, run end to end through the wrapper,** takes the static-CIDR fallback.
  Before D-8 it exited 6 there.

Added after the independent review (spec §11):
- `run-agent` refuses a `/workspace/.git` file or directory, and a FIFO `.claude.json`,
  without hanging.
- Copilot always receives `--no-auto-update` and `COPILOT_AUTO_UPDATE=false`, including for
  the banner's `--version`.
- A `~/.copilot/pkg` cache is refused by the wrapper, even for `--version`, and by
  `run-copilot` before any firewall call.

Mutation check: broken copies of the scaffold in a WSL temp directory, each run through
the suite and the static checks.

| Mutation | Caught by |
|---|---|
| Wrapper without the environment unset | 4 startup scenarios, S26 |
| Wrapper without the capability check | `wrapper-caps-held` |
| Wrapper without the lock-owner check | `wrapper-lock-not-root` |
| `run-agent` without the user allowlist | 5 scenarios |
| `run-agent` without the project comparison | 7 scenarios, S26 |
| `run-agent` without the MCP check | 2 scenarios |
| `run-agent` checks moved after the lockdown | 22 scenarios, S26 |
| Managed file with `allowUnsandboxedCommands: true` | S10 |
| Managed file with a widened `allowWrite` | S10 |
| Wrapper directory placed after `~/.local/bin` on `PATH` | S25 |
| `run-agent` without the `/workspace/.git` refusal | 2 scenarios |
| `run-agent` without the regular-file check on `.claude.json` | the FIFO scenario |
| Wrapper without `--no-auto-update` | 3 scenarios |
| Wrapper without the package-cache refusal | `copilot-pkg-wrapper` |
| `run-copilot` without the package-cache refusal | `copilot-pkg-launcher` |

The static checks also passed on the jq path in WSL.

Not shown by any of this: what the Claude CLI does with the managed file. That is the
spec's live L1–L10 (§10). Static assertions: 24 passed, 0 failed, 2 skipped.

The full ladder before the review fixes, in WSL, all exit 0:

| Suite | Result |
|---|---|
| `verify-scaffold` | 24 passed, 2 skipped |
| `verify-startup` | 37 passed |
| `verify-firewall` | 66 passed |
| `verify-rounds` | 78 passed |
| `verify-tasks` | exit 0 |
| `verify-assembly` | 33 passed |
| `verify-recording` | 16 passed |

After the review fixes, three suites were rerun, because the fixes touch only the
launchers, the wrapper and their tests:
- `verify-scaffold`: 24 passed.
- `verify-startup`: 42 passed; 43 of 43 with `--baked` on the rebuilt test image `7eb17d68…`.
- `verify-firewall`: 66 passed.

The real Copilot 1.0.83 on that image printed its version through the wrapper with
`--no-auto-update`, and refused (exit 78) once a `~/.copilot/pkg` directory existed.

After the pre-merge pass-1 review (spec §12), the image no longer leaves a `claude` in
`~/.local/bin`. `baked-layout` now asserts that `bash -ic` and `bash -lc` resolve both CLIs to
the wrappers, that `~/.local/bin/claude` is absent, and that the real-CLI link is root-owned
and executable. That condition was observed false on the pre-fix image. Results:
- `verify-startup`: 42 passed from source; 43 of 43 with `--baked` on the rebuilt test image
  `4f6bbdc7…`.
- S10 now also compares the whole managed file: a widened `allowedDomains` fails it, and the
  mutation was reverted.
- `verify-startup.sh` now force-removes a scenario container that a timeout left running.
  One had been left by the FIFO mutation run, and was removed.

After the pre-merge pass-2 review, every validated file must be singly linked. There are new
`agent-project-hardlink` and `agent-user-hardlink` scenarios, and QUICKSTART has a symlink-safe recovery block.
Results:
- `verify-startup`: 44 passed from source; 45 of 45 with `--baked` on the rebuilt test image
  `945ea49c…`.
- Mutation M17 (no single-link rule): both hard-link scenarios fail.
- `verify-scaffold`: 24 passed.

Finding G2 (spec §15) added S27 and the `chrome-headless` startup scenario. Results on the
deployed image `6fa46c4bb3c3` (2026-09-27):
- `verify-scaffold`: 25 passed, 2 skipped.
- `verify-startup`: 46 of 46 with `--baked`. From source, `chrome-headless` skips on an image
  without the headless shell.
- `verify-firewall`: 66 passed.
- Mutations: pointing `CHROME_BIN` back at full Chromium fails S27. Removing an `XDG` redirect
  changes nothing, because the headless shell does not need one.

### Claude Code evidence-capture probe, 2026-09-27

Owner-approved, non-ticket probe for OPERATOR's execution-evidence gate (backlog S-1).
- **Setup:** one guarded `run-agent` session on image `6fa46c4bb3c3` (Claude Code 2.1.283,
  model `claude-opus-5-5[1m]`), a throwaway workspace and the real login volume.
- **What it did:** a plain command, a failing command (exit 2), a write the sandbox refused
  (exit 1), a file-tool write and one sub-agent command. Session
  `6c2af0f6-f631-45f9-8c2a-327f2ce7ad87`, 17 s, 6 turns.
- **Both records captured all six tool calls with their results and error flags.**
  - The stream-json transcript carried the sub-agent's call inline (3 tagged events).
  - The session record kept it in a separate `subagents/` file.
  - Neither has a structured exit-status field.
- **Background builds:** the earlier rehearsal's transcript shows their output went to
  `/tmp/claude-1000/` in the container. Only the polled tails were recorded.
- **Retention and integrity:**
  - Evidence was retained privately outside the workspace: 9 files, and the manifest
    verified.
  - The login volume's checked files were unchanged.
  - The documented export command reproduced the probe's export byte for byte.
- **Not exercised:** interactive sessions, compaction, concurrent sub-agents. The recipe is
  in OPERATOR, under "Claude Code session evidence".

## Deliberately not asserted

- **DNS egress being open.** Accepted by design; A12 asserts it works rather than that it is
  closed.
- **That the agent cannot read its own auth token.** Before Phase 3 it could, via Bash; the
  settings deny rule covered the Read tool only. On the Phase 3 test image, sandboxed Bash
  could not open `/home/vscode/.claude/settings.json`, which the probe reported as absent (spec §10). That is one
  file in one probe, not proof that the whole directory or the token is unreadable. It was observed once and is not
  asserted by any check; Copilot sessions have no such sandbox.
- **Anything requiring the dev AS400/Oracle.** Unreachable by design.
- **Integration tests.** Same reason.

## Notes for whoever implements this

- **The S-series is implemented** in `verify-scaffold.sh` (2026-09-09). Since I1/I2 were
  fixed (2026-09-23), with S25/S26 from Phase 3 (2026-09-24) and S27 from G2 (2026-09-27): 25 pass, 0 failures, 0 warnings, 2 skips (no shellcheck, no VERSION). Focused firewall coverage does not complete the lifecycle
  P/A/G/X runner.
- S1 is the assertion most likely to be written wrongly. Two tools lie here: `grep -c $'\r'`
  can match every line in Git Bash, and `file(1)` omits its CRLF note in some builds. Count
  bytes — `tr -d '\015' < f | cmp -s - f` is the cheap form.
- **Any assertion that greps source for a forbidden construct must exclude the files that
  document the prohibition — including the verifier itself.** This bit twice while implementing
  the S-series: S15 failed on the Dockerfile comment explaining why `NOPASSWD:ALL` is wrong, and
  S14 failed on `verify-scaffold.sh`'s own success message containing the words "sudo call
  site". Strip comment lines, and exclude `AGENTS.md`, this file, and the verifier.
- Enumerate files with `git ls-files --cached --others --exclude-standard`. Plain `git ls-files`
  omits a newly written file, which is exactly when a CRLF or syntax error would slip past.
- Runtime is dominated by process creation, not work. Compute file lists once, prefer one grep
  across many files to one grep per file, and never recurse a sibling repo — asking
  `git -C ../prj ls-files '*pom.xml'` for S19 rather than walking `../prj` cut the total runtime
  by a third on its own.
- A3–A7 and P8 need their documented endpoints; focused E1 traffic stays on isolated test
  networking without an external route.
- Keep each assertion independent — no shared state, no ordering dependency — so a failure
  localizes. `set -e` is wrong for this script; collect results and exit at the end.
- Assertions S11–S18 and A8–A11 exist to stop an isolation invariant regressing silently. When
  one of them fails, the right response is almost never to relax the assertion.
