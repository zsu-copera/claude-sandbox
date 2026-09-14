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
| S6 | Every file `new-sandbox.sh` copies from the scaffold exists (`overlay/CLAUDE.md`, `overlay/.claude`, `.devcontainer`, `container`, `dockerignore`) | existence check | FAIL |
| S7 | No personal path or name anywhere | grep for `/home/su`, `Users/su`, `zsu@`, and any hardcoded human name used as a default value | FAIL |
| S8 | `overlay/.claude/settings.json` and `container/copilot-settings.json` are valid JSON | `jq empty` | FAIL |
| S9 | `.devcontainer/devcontainer.json` is valid **JSONC** | it contains `//` comments, so plain `jq` fails — strip comments first or use a JSONC parser. A naive `jq empty` here is a false failure | FAIL |
| S10 | `overlay/.claude/settings.json` still declares `defaultMode: bypassPermissions`, a non-empty `deny` list, and `sandbox.enabled: true` | `jq` | FAIL |
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
| P14 | Agent CLIs were staged | `.agent-cli/claude-local.tgz` and/or `.agent-cli/copilot/bin/copilot`; non-fatal by design, so WARN | WARN |
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

## Deliberately not asserted

- **DNS egress being open.** Accepted by design; A12 asserts it works rather than that it is
  closed.
- **That the agent cannot read its own auth token.** It can, via Bash; the settings deny rule
  covers the Read tool only. Asserting otherwise would encode a false claim.
- **Anything requiring the dev AS400/Oracle.** Unreachable by design.
- **Integration tests.** Same reason.

## Notes for whoever implements this

- **The S-series is implemented** in `verify-scaffold.sh` (2026-09-09). With the E1 source
  assertions updated: 21 pass, 1 unresolved failure (S7, I1/I2/I3), 0 warnings, 2 skips
  (no shellcheck, no VERSION). Focused firewall coverage does not complete the lifecycle
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
