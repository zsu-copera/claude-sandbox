# Sandbox audit reconciliation

Reviewed 2026-09-09. This is a point-in-time verification of the existing audit,
not an implementation of its recommendations or approval for unattended use.

**Bookkeeping update, 2026-09-10:** the original findings and counts below retain
their review-time meaning. E1 has since been implemented and committed on a separate
branch; packaging and deployment remain outstanding. See the
[E1 remediation record](#e1-remediation-on-a-separate-branch) for the current status.

**Bookkeeping update, 2026-09-23:** the current tagged image contains the E1 firewall
and launchers. See [E1 deployment observation](#e1-deployment-observation-2026-09-23).
The other findings are unchanged.

## Open items, as of 2026-09-23

This is the current work list; start here in a new session. Each item links to its evidence.
The register and the dated sections below keep their historical meaning. **Deployed:** E1,
N3, E6 and N4 in image `fda0c678…` (see [the deployment record](#deployment-of-n3-e6-and-n4-2026-09-23)).
The policy governing what is required is in [Containment decisions](#containment-decisions-2026-09-23).

**Blocking unattended runs** (these need a written spec and owner review; the firewall and
settings-precedence work is not delegable without review):

| Item | What is needed |
|---|---|
| E2/E3, E5, N5 | **Implemented in source, not deployed** ([Phase 3](#phase-3-inner-sandbox-and-guarded-startup-2026-09-24), spec approved 2026-09-24). Root-owned managed policy, startup checks of the next session's inputs, baked CLIs only, guarded wrappers. Reviewed three times: review 0, then a pre-merge two-pass review (spec §11–§12). Every high and medium finding is fixed or recorded as a gate. Live observations on a throwaway test image are recorded (spec §10). Remaining: one coordinated rebuild with the ticket lead; then L1–L10 and L12 again on the rebuilt image, plus a supervised real build and unit-test run under the mandatory sandbox. Not deployed until then. **Condition:** if the organisation ever configures server-managed Claude settings, the CLI selects a single source first-wins and may rank them above the managed file. How the locks would combine is unverified, so any such settings must carry this policy. |
| C5, sign-off | Security/IT sign-off before other developers run unattended. Record it here. |

**Blocking a second developer** (mechanical unless noted):

| Item | What is needed |
|---|---|
| Onboarding | Each developer: repository invitation, build from `main`, own fine-grained PAT (QUICKSTART step 4-alt). |

**Safety and correctness:**

| Item | What is needed |
|---|---|
| Next rebuild | Must carry Phase 1's `prepare.sh` and Copilot seed, and Phase 3. Until then, prepare a newly assembled workspace only on a rebuilt image: the old `prepare.sh` restores the removed identity default. Phase 3's project settings deliberately repeat the old deny rules and sandbox lists (spec §9, D-9), so a workspace assembled after Phase 3 is no weaker than before on the old image, but it gets none of the Phase 3 protections there. |

**Verification gaps on the current image** (first real session after the rebuild):
- Interactive Copilot and Claude sessions under E6.
- Maven/npm offline builds with DNS closed.
- Claude tool calls inside its inner sandbox.
- Copilot `/model` on a new volume shows the seeded `claude-opus-5.5` (C3; the dotted ID is inferred from the CLI bundle).

The E6 discovery ran on baked Copilot 1.0.83, while the workspace-staged CLI is 1.0.86. Earlier
records said 1.0.83 for the staged CLI, and the discrepancy is unexplained. After Phase 3
only the baked CLIs run, and the rebuild installs whatever versions are current at build
time, so record both versions after the rebuild. If a CLI stops working, run a new
names-only discovery; do not reopen DNS.

**Closed 2026-09-23 in [Phase 1](#phase-1-cleanup-2026-09-23):** I1, I2, I3, I4, C1, C2, C3, D4.
**Closed 2026-09-23 in [Phase 2](#phase-2-reset-safety-and-required-assets-2026-09-23):** V2, D5.

**Longer term:** D2/D3 (immutable inputs, versioned releases), V1/N2 (runtime P/A/G/X checks,
CI; a static-check CI job is deferred by owner decision), and V3/V4 (partly addressed by the recorder and `sandbox-task.sh collect`; reassess).

**Owner actions outside this repository:**
- Delete the retired `Documentation` branch `claude-sandbox`; a bundle is retained privately.
- Protect or move the scaffold repository before wider distribution.
- Keep the untagged previous image `893d19…`: EEP-24 and JWA-2906 records pin it.

**Accepted, not work items:** N1, where the hook is defense-in-depth only and should not be
chased with more patterns, and data encoded in HTTPS to the allowlisted model providers.

## Scope and baseline

Original report: [PERA Agent Sandbox Audit](https://claude.ai/code/artifact/3e434978-46fb-42c0-8292-028e9efc982b),
dated September 8 and revised locally through September 9 at 10:30 AM.
Its 27 findings cover distribution, single-user assumptions, enforcement,
verification, and documentation.

| Component | Reviewed state |
|---|---|
| Working scaffold | Commit `77fed5c`, clean before this report |
| Rebuilt image | `localhost/pera-sandbox`, image ID `9538a73e9e894e2a9d325fc09db8bfa609737b4222cf598a362857391d75588e` |
| Image-baked agents | Copilot `1.0.69`; Claude Code `2.1.267` |
| Earlier live Copilot smoke run | Workspace-staged `1.0.83`, not the image-baked version |
| Shared distribution copy | Local `Documentation` branch `claude-sandbox`, commit `b4fabe5bc` |
| Application checkouts | Host `prj` at `84e768451`; assembled `prj` at `fc399a9af` |

The shared distribution copy has seven differing existing files and lacks seven
files now present here. The cached `Documentation` `main` has no files under
`Sandbox-Workspace`. No remote fetch, branch checkout, promotion, rebuild, or
configuration change was performed during this review.

## Result

Of the original 27 findings:

| Status | Count | Meaning |
|---|---:|---|
| Confirmed | 17 | The core condition remains; qualifications below limit the claim |
| Partially resolved | 3 | Changes addressed part, but not all, of the condition |
| Partially supported | 4 | A real issue exists, but the audit overstates or misdescribes it |
| Resolved | 2 | The original condition is no longer present in this working copy |
| Needs owner evidence | 1 | Source inspection cannot establish the organizational requirement |

Two additional findings concern the newly added Copilot hook and S24. They are
recorded separately as N1 and N2 rather than added to the original audit's count.

**The most important correction to earlier work: the root-owned Copilot hook
does not establish a complete no-push or no-exfiltration boundary.** The earlier
successful `git -C ... push` denial proved that particular spelling was blocked.
It did not prove that equivalent commands, scripts, or subprocess network access
were contained. Existing prose claiming coverage "in any spelling" or that the
hook is the control that "actually holds" is too strong.

## Security findings

Severity describes conditional impact, not a demonstrated external breach.
File and line references identify the reviewed commit, not future revisions.

| # | Severity | File | Lines | Vulnerability | Confidence |
|---|----------|------|-------|---------------|------------|
| 1 | 🟠 HIGH | `container\init-firewall.sh` | 39-55, 138-162 | E1: refresh opens OUTPUT and removes the marker used by the reopen guard | 9/10 |
| 2 | 🟡 MEDIUM | `overlay\.claude\settings.json`; `container\run-agent.sh` | 3-8; 54-55 | E2: mandatory Claude policy remains owner-writable under permission bypass | 9/10 |
| 3 | 🟡 MEDIUM | `overlay\.claude\settings.json` | 11-13 | E3: native sandbox can fall back to unsandboxed execution | 9/10 |
| 4 | 🟡 MEDIUM | `overlay\.claude\settings.json` | 5-8 | E4: textual deny coverage remains incomplete | 9/10 |
| 5 | 🟡 MEDIUM | `new-sandbox.sh`; `.devcontainer\devcontainer.json` | 100-101; 32 | E5: explicit shell/devcontainer startup can omit lockdown | 9/10 |
| 6 | 🟡 MEDIUM | `container\init-firewall.sh` | 149-150 | E6: outbound TCP/UDP port 53 is unrestricted by destination | 10/10 |
| 7 | 🟡 MEDIUM | `container\guard-shell-command.js` | 44-46, 75-89 | N1: equivalent commands and script indirection evade the new hook's matching | 10/10 |

### Evidence and limits

**E1 - firewall state transitions.** `flush_rules` sets OUTPUT to ACCEPT,
flushes rules, and removes user-defined chains. Lockdown later restores the
marker and restrictions. `open` checks only the marker, not the durable
committed-domains file, and changes are not serialized. The temporary permissive
interval follows from the source sequence. A persistent reopening depends on
interleaving with the remaining lockdown work; that race was not reproduced.
The image firewall script matches the reviewed source.

**E2/E3 - Claude's inner sandbox.** The assembled settings file and its parent
directories are owned by UID 1000 and owner-writable. The image has no
`/etc/claude-code/managed-settings.json`. Ownership alone would not establish a
bypass of protected-path handling, but current Claude documentation says bypass
mode skips those write prompts. Actual settings editing/reload was not exercised.

`failIfUnavailable` is false. The shipped Claude schema and current documentation
describe a warning followed by unsandboxed execution: the audit's word
"silently" is incorrect. Also, omitted `allowUnsandboxedCommands` defaults to
true. Changing only `failIfUnavailable` would not prohibit unsandboxed retries.
These issues weaken the inner restrictions; they do not themselves remove the
outer container or its firewall.

**E4 - correct two audit examples.** Current Claude documentation says compound
commands are checked by subcommand and Read denies propagate into an active
native sandbox's filesystem restrictions. Therefore `cd prj && git push` and
reading a denied file using `cat` are not established blanket Claude bypasses.
Unsandboxed execution, mutable settings, and script indirection are separate
issues and must not be conflated.

**E5 - startup mode matters.** Image metadata shows command `/bin/bash` and no
entrypoint. The explicit shell and devcontainer workflows do not automatically
apply lockdown. A noninteractive bare run may exit immediately; the concern is
starting agent work from an uninitialized interactive/devcontainer shell.
Changing `CMD` alone would not secure explicit overrides or every IDE path.

**E6 - conditional accepted risk.** Rules accept TCP/UDP destination port 53
without restricting destination addresses. No transmission was attempted.
Whether this remains acceptable under the documented trusted-workload,
accident-focused threat model is an owner decision. Restricting traffic to one
recursive resolver alone would not eliminate data encoded in DNS names.

**N1 - safe guard probes.** Synthetic tool payloads sent to the image-installed
guard received `{}` (no veto) for:

```text
/usr/bin/git push
command git push
action=push; git "$action"
bash ./publish.sh
/usr/bin/git remote add origin https://github.com/example/example.git
```

The command strings were not executed. These results establish gaps in the
hook itself, not successful authenticated pushes through every other layer.
A real external write additionally needs a reachable destination and usable
authentication; no OAuth token, credential scope, or authenticated write was
inspected. Nevertheless, no configured remote is not a complete prohibition:
a workload can supply a destination explicitly.

The hook also does not constrain arbitrary HTTPS performed by subprocesses.
GitHub address ranges remain reachable in Copilot sessions; fetch-tool URL
denies are not a process-wide network filter. The guard's denial message saying
"egress excludes the forge" is inaccurate for those sessions.

Escaped quotations have legitimate uses. Their blanket prohibition is a chosen
legibility rule, not reliable identification of malicious commands. Root
ownership protects the hook from ordinary edits, not from incomplete matching.

**N2 - S24 is a source-shape assertion, not enforcement proof.**
`verify-scaffold.sh:406-452` checks COPY/ownership/mode fragments, registration
strings, and optional JavaScript syntax. It does not establish semantic matcher
or executable validity, actual CLI loading, behavioral decisions, installed
permissions, or failure-mode behavior. S24 passed alongside the N1 gaps.
This is a verification limitation, not an independent demonstrated exploit.

For the current image, separate inspection did establish matching hashes for
the firewall, both entrypoints, guard and policy. Policy ownership/mode is
`root:root 0644`; guard ownership/mode is `root:root 0755`; their containing
directories are `root:root 0755`. Installation integrity is not containment.
Copilot command-hook timeouts warn and fail open, including policy hooks;
non-timeout command-hook errors deny. Claims that every failure is silent and
fail-open are incorrect.

## Original 27-finding register

| ID | Status | Current conclusion and evidence |
|---|---|---|
| D1 | Partially resolved | Git history now exists, but this repo has no remote and canonical distribution is unsettled. Other backup systems were not inspected. |
| D2 | Confirmed | Mutable image/package/CLI inputs and per-developer secret-backed builds remain: `.devcontainer\Dockerfile:5,18-28,63-75`; `container\prepare.sh:84-109`. No tracked publishing pipeline. |
| D3 | Confirmed | No scaffold VERSION, release changelog or immutable release workflow. Git IDs exist, so "nothing is versioned" is too broad. Staged CLIs can differ from the image. |
| D4 | Confirmed | `New-Sandbox.ps1:18-20,82-95` retains the Windows destination and lacks equivalent LF normalization/CA staging. README still says "kept for parity." Windows ACLs, not literally chmod, would govern Windows secrets. |
| D5 | Confirmed | Ignored `.github` and `.agents/skills` assets remain optional warnings: `new-sandbox.sh:24-25,55-61`; `container\prepare.sh:48-49`. Fresh clones do not supply them. |
| D6 | Confirmed | Cached `Documentation` main contains no scaffold; its distribution branch is behind this working copy. Local main/branch divergence is 11/9; local branch/cached origin is 0/0. Live remote state and unconditional merge safety were not established. |
| D7 | Resolved | `.gitattributes` is tracked and all 23 reviewed tracked files have index/worktree LF. Shared-copy attributes differ and must not be accidentally replaced during promotion. |
| I1 | Confirmed | `container\prepare.sh:71-75` still defaults commit authorship to one named human. The older shared copy lacks that identity block. |
| I2 | Confirmed | `new-sandbox.sh:13-14,22-23` still defaults credential sources to one Windows profile. Resolve the Windows profile; Linux `$USER` is not a reliable fallback. |
| I3 | Confirmed | Personal harvest paths remain in `README.md:204,211,224`, `QUICKSTART.md:142-149`, and `FAQ.md:157`. |
| I4 | Partially supported | Fixed names collide in several prepare/agent examples, but Copilot Quickstart commands omit names. A shared named volume does not itself cause a container-name collision. |
| I5 | Needs owner evidence | Licensing prerequisites, plaintext storage and server-side revocation are already documented (`README.md:165-172`). Wider licensing, retention and credential governance need organizational evidence. |
| E1 | Confirmed | Refresh/reopen source defect remains; persistent race outcome not reproduced. See security section. |
| E2 | Confirmed | Claude mandatory settings remain writable; the new Copilot policy does not fix this Claude-specific issue. |
| E3 | Confirmed | Unsandboxed fallback remains permitted, but the "silent" description is wrong. Startup failure and unsandboxed retries need coordinated handling. |
| E4 | Partially resolved | New Copilot hook catches certain spellings, not arbitrary operations. Original compound-command/Read-deny examples require correction. |
| E5 | Confirmed | Explicit shell/devcontainer paths can omit guarded startup. Risk depends on starting agent work outside the wrappers. |
| E6 | Confirmed | Unrestricted port-53 rules remain. Accepted-risk status belongs to the owner, not this review. |
| V1 | Partially resolved | Static S-series exists; runtime P/A/G/X verification, startup integration and CI gating do not. S24 does not replace them. |
| V2 | Confirmed | `new-sandbox.sh:27-31` and `New-Sandbox.ps1:45-48` delete without checking unharvested refs/dirty work or validating destination containment. No destructive reset was run. |
| V3 | Confirmed | Logs persist in auth volumes, while harvest exports commits only (`README.md:135-140`; `QUICKSTART.md:135-164`). No dedicated retention/export workflow. |
| V4 | Confirmed | `QUICKSTART.md:140-164` is still a manual branch/refspec/review sequence; no harvest helper. No wrong-diff incident was reproduced. |
| C1 | Partially supported | Both blanket runner descriptions are stale: member now has 51 Karma plus 2 `@angular/build:unit-test` targets; agency has 17 Karma. The host-installed unit-test schema defaults to Vitest. |
| C2 | Confirmed | `overlay\CLAUDE.md:73-75,91-100` duplicates dated runner counts and ticket-specific state already owned by project documentation. |
| C3 | Partially supported | Fixed first-run model seeding is real (`container\copilot-settings.json:2`), but preserving an existing user choice is intentional. No evidence makes the newest model mandatory or the older choice inherently defective. |
| C4 | Resolved | `.gitignore:15` ignores root `.claude/settings.local.json`; it is untracked and not the deployed overlay. |
| C5 | Partially supported | Threat-model material already exists in README and PowerShell comment-based help works. Consolidated risk sign-off/ownership and a safe shell-script help path remain missing. |

For C1, the two member unit-test targets are `disclosure-of-compensation` and
`working-after-retirement` (`prj\member\angular.json:5042,5350`). Both the host and
assembled application configurations contain the mixed target set. No application
test suites were run. The local overlay's "zero Vitest targets" statement is now
stale too; fixing only QUICKSTART would leave contradictory guidance.

## Original recommended sequence

This is the review-time ordering. E1's implementation and subsequent work are tracked
in the addendum below; the original list does not mean the branch fix is still unwritten.

1. **E1 with focused V1 regressions:** guard durable lockdown state, serialize
   transitions, and avoid a temporary ACCEPT interval. Cover both ipset and
   per-IP fallback behavior before considering the defect closed.
2. **Set the containment requirement (N1/E6/C5):** distinguish accidental-command
   prevention from deliberate or prompt-induced exfiltration. Stronger guarantees
   require network/credential enforcement outside agent-controlled subprocesses,
   not an expanding blacklist. Correct overstated claims immediately.
3. **E2/E3 together, then E5:** deploy managed Claude policy, require strict native
   sandbox behavior, and make protected startup the default across terminal and
   devcontainer paths. Observe effective settings rather than assume precedence.
4. **V1/N2 alongside those fixes:** separate static packaging checks, guard
   behavior, image installation, and real-CLI policy loading. Exercise both the
   baked and workspace-staged CLI paths and their failure behavior.
5. **Protect work and unblock another user (V2/I1/I2/D5):** validate reset targets,
   preserve or explicitly acknowledge unharvested and dirty work, remove personal
   defaults, and require assets essential to the selected task.
6. **Distribution (D1/D2/D3, then D6):** choose the canonical source and backup/
   promotion process; record image and staged-tool identities; publish reviewed
   releases. Pinning only the image does not pin tools refreshed by prepare.
7. **Usability/documentation:** fix C1 now; consolidate C2, personal paths,
   container naming, transcript handling, harvest and unsupported entrypoints.
   Treat C3 as a lower-priority preference/update-policy decision.

Do not interpret the audit's original "blocker" labels as equivalent to exploitable
security severity. A shared image pipeline is a rollout concern; the firewall
state transition is a containment defect. DNS acceptance and stronger isolation
requirements need a human decision before selecting a design.

## Verification record and remaining limits

- Existing static assertions returned **20 passed, 1 failed, 1 warning, 2 skipped**.
  S7 fails for personal defaults, S11 warns about E1, and S3/S20 are skipped.
  A known baseline failure is still an unresolved finding, not a successful gate.
- Security probes used disposable, unprivileged containers with `--network none`
  and no workspace or credential mounts. They inspected image metadata/files and
  evaluated synthetic hook inputs without executing their command strings.
- No authenticated push, DNS/data transmission, privileged firewall race,
  sandbox-dependency failure, settings override/reload, or destructive reset was
  performed. Claims requiring those observations remain qualified above.
- The earlier live policy smoke result used staged Copilot 1.0.83. The image's
  fallback is 1.0.69. Do not generalize evidence from one to the other.
- No existing code, policy, image, user settings, or distribution branch was
  changed to produce the reconciliation. This report is the only repository
  addition requested after the read-only review.

References used to qualify the original audit:

- [Claude permissions](https://code.claude.com/docs/en/permissions)
- [Claude sandboxing](https://code.claude.com/docs/en/sandboxing)
- [Copilot hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)

These documentation pages can change. Their statements support this dated review;
they do not replace exercising the exact CLI builds deployed in a future image.

## E1 remediation on a separate branch

Implementation branch: `fix/e1-firewall-transitions`. The original review above
remains a record of the reviewed image and source, not a claim about this branch.

| Item | Recorded status as of 2026-09-10 |
|---|---|
| Firewall implementation | Committed as `d714fb5` |
| Regression harness and initial documentation | Committed as `1ccbb5e` |
| Branch evidence | Both real firewall backends, launcher failure paths and scoped-sudo refusal exercised; details below |
| `main` | Remains at `91e7b1f`; E1 has not been merged |
| Tagged `localhost/pera-sandbox` image | Still `9538a73e9e894e2a9d325fc09db8bfa609737b4222cf598a362857391d75588e`, the pre-E1 image |
| Refreshed build context, rebuilt image and new agent session | Deployment not yet recorded; follow the QUICKSTART update procedure |
| Documentation distribution copy | Not promoted as part of E1 |

The candidate serializes firewall operations with a root-owned lock, guards
reopening with durable and kernel state, and keeps the static firewall in place
during refresh. Address updates use a staged ipset swap or one jump replacement
to a staged per-IP chain. The backend is fixed at initial lockdown.

Incomplete initial installation requires a fresh container. Before activation,
refresh errors retain the previous restrictions; after activation, cleanup or
probe errors retain the new restrictions. Both launchers now surface refresh
failures. Initial lockdown requires complete DNS resolution and a successful
positive probe when a hostname is present, rather than starting with unresolved
domains or a warning-only provider failure.

S11/S12 now describe their source-structure checks accurately; runtime evidence
is separate. The static baseline is 21 passed, 1 unresolved S7 failure, 0 warnings,
and 2 skips (shellcheck and VERSION). S7 is not waived or resolved by E1.

The source-mounted firewall suite returned **54 passed, 0 failed, 0 backend
skips** against the existing image's iptables 1.8.10 nft backend. Both real ipset
and per-IP implementations were exercised with controlled peers on an isolated
internal network. Coverage includes DNS-changing refreshes, forbidden connection
probes, deterministic concurrent calls, failures before/at/after activation,
TERM/KILL interruptions followed by retries, pinned state, incomplete
initialization and smoke-probe failures. The runner rejects a source change
during the suite. No provider credentials or application workspaces were mounted.

Four additional caller scenarios passed with the current launchers streamed into
network-disabled containers. Synthetic firewall failures prove that both
launchers abort before credential purge and agent startup on initial failure,
and surface refresh errors while a fake CLI continues. These caller scenarios
use helper/CLI shims; they do not establish real provider connectivity or
authentication.

A separate real scoped-sudo scenario also passed: after switching to the
non-root agent identity and clearing capabilities, `sudo` invoked the actual
firewall helper and `open` returned 3. Direct kernel access, protected-state
reads/writes and unrelated privileged commands were refused. This network-disabled
test retains SETUID, SETGID and DAC_OVERRIDE for the scoped elevation; they are
existing production-default capabilities, not new privileges for the deployed
agent. Without DAC_OVERRIDE, the artificially reduced test profile prevented PAM
from reading the image's mode-000 shadow file before the helper could run.
No account/PAM files were read or changed by the fixture.

The recorded runs are 58 passing firewall/caller scenarios together, followed
by 1 passing targeted real-sudo scenario, with no failures or skips. They do not
cover a rebuilt image, real provider sessions or the lock's full timeout duration.

**Deployment remains separate:** E1 development did not update the assembled
workspace, replace the tagged image, merge `main` or promote the distribution copy.
The image ID above was read again during the documentation update and remains unchanged.
E1 must not be marked resolved for that image merely because the branch has a fix.

Next, complete and record the [existing-sandbox update procedure](QUICKSTART.md#update-the-image-without-resetting-the-workspace):
the selected scaffold revision, refreshed build inputs, new image ID and a guarded
startup outcome. Recreating a container from the old image is not deployment. Keep
the original image evidence above rather than rewriting it as evidence for a rebuild.

The documentation update also corrects overstatements about universal no-push
enforcement, exclusive provider access and S24's coverage. This does not remediate
N1/E6, complete V1/N2 or change E2/E3/E5 policy. The next design decision remains
the containment requirement (N1/E6/C5), followed by the coordinated Claude-policy
and guarded-startup work.

## E1 deployment observation, 2026-09-23

The 2026-09-10 table above is preserved as written. It was not updated when the
image was later rebuilt; this section records what was observed afterwards.

| Item | Observed 2026-09-23 |
|---|---|
| Tagged `localhost/pera-sandbox` image | `893d19013d16066cacf386c442fd9d906f70792da74a046027f996ca7fed00d6`, created 2026-09-11 20:18 UTC |
| Baked scripts and policy | SHA-256 of all seven Dockerfile-installed files equals the scaffold source: `init-firewall.sh` and both launchers as of `d714fb5`, guard/policy as of `8168164`, `prepare.sh`/Copilot defaults as of `3158ce1` |
| Baked agent CLIs | Copilot 1.0.83; Claude Code 2.1.269 |
| Guarded startups on this image | EEP-24 (2026-09-15) and JWA-2906 (2026-09-18) started through the guarded Copilot launcher; see `VERIFY-ASSERTIONS.md` |
| `main` / distribution copy | `main` fast-forwarded on 2026-09-23 to include E1 and later work; Documentation copy not promoted |

The comparison ran in a disposable `--network none` container with no mounts. It
establishes byte parity with the E1 source, so this image is **not** the pre-E1 image
described above. `run-copilot` runs under `set -e`, so it stops before purging credentials
or starting the agent if the initial lockdown fails. With E1, that includes complete DNS
resolution and the positive probe. The two recorded agent sessions therefore imply that
the initial lockdown succeeded with the E1 script. That is an inference from launcher
behavior, not a separate observation of kernel rules in those sessions.

Not established: which scaffold revision and build inputs were used for the build,
who built it, or whether the Documentation-branch procedure was followed. The
source-mounted E1 firewall suite has not been rerun against this image, and real
provider refreshes, the lock's full timeout and Claude Code startup remain untested
on it. Treat E1 as **deployed in the current image by byte parity**, not as a fresh
runtime verification. N1, E2 to E6, V1/N2 and the distribution findings are unaffected.

## Distribution decision, 2026-09-23

The 2026-09-09 D1/D6 conclusions in the register are left as they were. Later status:

- **D1:** the scaffold now has a private GitHub remote holding `main` and all four feature
  branches. The owner chose it as both canonical source and distribution point (option A).
  The repository is owned by an individual account; moving it to organization ownership
  is a separate governance choice.
- **D6:** the `Documentation` branch `claude-sandbox` copy, never merged to that
  repository's `main`, is retired completely with no pointer. Its last commit
  `b4fabe5bc` predates E1. Its two historical reports were imported unchanged into
  `history/`. A verified private bundle of its 9 branch-only commits is retained
  outside the repository. Deleting the branch is the `Documentation` owner's step and is not yet
  done. Until then, anyone building from that branch gets the pre-E1 firewall.
- **D7:** reconciling the two `.gitattributes` files is no longer needed.
- D2/D3 (mutable inputs, no releases) are unchanged. Pushing `main` is not a reviewed
  release process.

## N3: Copilot sign-in token capability, 2026-09-23

| # | Severity | File | Lines | Vulnerability | Confidence |
|---|----------|------|-------|---------------|------------|
| N3 | 🟠 HIGH | `pera-copilot-config` volume `config.json`; `container\run-copilot.sh` | token store; CIDR allowlist | Agent-readable Copilot OAuth token carries `repo` and `gist` scopes, and GitHub is reachable | 9/10 |

A read-only check was made from a disposable container, with the auth volume mounted
read-only. It sent GET requests only and never printed the token. It found:

- One stored token, a classic OAuth token (`gho_`) issued to the Copilot CLI OAuth app.
  It is stored in plaintext in the volume's `config.json`, mode 600. Under the sessions'
  `--userns=keep-id` mapping the file belongs to the agent user, and the CLI reads it as that user.
- Scopes: `codespace, gist, read:org, read:user, repo`.
- `GET /repos/.../Documentation` returned `push: true` for the signed-in user.
- The Git receive-pack (push) handshake returned HTTP 200 for both the organization
  `Documentation` repository and the scaffold's own repository. No push was attempted.

This changes the no-push analysis. The README and entrypoint list "no Git credentials"
as a barrier. For Copilot sessions that barrier is absent: the agent's own sign-in token
can authenticate Git pushes and REST writes, including creating gists, to every repository
the user can write. The allowed GitHub CIDRs make those hosts reachable. The remaining
barriers are the deny flags, the policy hook, model behavior and human review. N1 shows
the hook can be evaded by equivalent spellings. The scaffold repository is now the distribution
point, so a session could in principle also alter the scaffold that future sandboxes are
built from.

Not established: whether the agent's shell tool, under Copilot's path verification,
can actually read `~/.copilot/config.json` in a live session; whether any past session
did so; and whether the organization's SSO or other policies restrict this token beyond
what these responses show. Claude sessions are not affected: their allowlist excludes GitHub
and their Anthropic credential has no repository access.

Candidate mitigation, unverified here: Copilot CLI documents support for a fine-grained
PAT with only the **Copilot Requests** account permission, supplied as
`COPILOT_GITHUB_TOKEN`. That would replace the stored OAuth token, and the OAuth
authorization would then be revoked. It needs a live check that Copilot works with the
PAT under the org license, and that push and gist creation fail with it.

**Remediation in source, 2026-09-23 (`d23af8e`):** `run-copilot` now refuses, with exit
78 and before any network use or credential purge, in four cases: a missing or non-PAT
`COPILOT_GITHUB_TOKEN`, the retired `--login` mode, a stored non-PAT or unparseable token
entry in `config.json`, or any GitHub token-like value in that file. It also unsets
`GH_TOKEN` and `GITHUB_TOKEN`. The documented launch supplies the PAT from a podman secret. Shim
regressions pass (see `VERIFY-ASSERTIONS.md`).

Status:

- **Not deployed.** The image's baked `run-copilot` is still the old launcher until
  a rebuild. The old launcher already passes a secret-supplied PAT through, because
  the environment variable takes precedence over the stored token. So the exposure
  can be removed before the rebuild by switching the credential and removing and
  revoking the stored token.

**Live verification, 2026-09-23.** The owner created a fine-grained PAT (Copilot
Requests only, public repositories, 90-day expiry) and stored it as podman secret
`pera-copilot-token`. With that PAT, from disposable containers:

| Check | Result |
|---|---|
| `GET /user` | 200. Fine-grained token, expiry header present, no OAuth scopes |
| `GET` of the organization `Documentation` repository and of the scaffold repository | 404 (no access) |
| `POST /gists` with an empty body | 403 `Resource not accessible by personal access token`; needs `gists=write`. Nothing created |
| Git upload-pack and receive-pack handshakes, both repositories | 403 |
| Headless Copilot 1.0.83 (`-p`), new launcher source-mounted, throwaway workspace and volume | Lockdown and self-probes passed; the model answered; exit 0. The volume stored no token |
| New launcher against the real auth volume before cleanup | Refused, exit 78 (1 non-PAT entry) |

The stored OAuth token and login fields were then removed from the real volume's
`config.json`, keeping its header comments and mode 600. The same headless check
against the real volume then passed, exit 0, and no token-like value remained in the
file. The removed token was not copied or backed up. These runs were headless;
interactive startup and a real task under the PAT are not yet exercised.

- **Deployed 2026-09-23** in image `fda0c678…`; see [the deployment record](#deployment-of-n3-e6-and-n4-2026-09-23).

**Revocation, 2026-09-23:** the owner reported revoking the Copilot CLI OAuth authorization
and then signing in again on the Windows host only. The new host token is outside the sandbox.
Revocation could not be independently confirmed because the removed token was deliberately
not retained. Afterwards the sandbox auth volume still held no token-like value, and
`pera-copilot-token` was the only podman secret. N3 is **remediated for this machine's
sandbox**, pending the image rebuild. Other developers must follow QUICKSTART step 4-alt,
including the FAQ migration if they ever used `/login` inside the sandbox.

## Containment decisions, 2026-09-23

These decisions answer the "containment requirement (N1/E6/C5)" step in the original recommended
sequence. They were made by the scaffold owner after N3 was remediated.

| Decision | Choice |
|---|---|
| Threat tier, supervised runs | Accident prevention plus a credential that cannot write: the current state, with N3 remediated. Accepted residuals: N1 (the hook can be evaded), E6 (DNS) and E2/E3 (Claude inner settings), because a human supervises and reviews every collection. |
| Threat tier, unattended runs | Not permitted until E6 is closed and E2/E3 are fixed. The goal is to stop a manipulated agent sending data to arbitrary destinations. |
| DNS (E6) | Close it: block agent DNS and have root keep a root-owned `/etc/hosts` for the pinned allowlist. This is a firewall change: it needs a written design, a discovery run of the hostnames each CLI actually uses, focused regressions and owner review before implementation. |
| Risk sign-off (C5) | The scaffold owner, for supervised use now. Security/IT sign-off is required before other developers run unattended. |
| Scaffold repository protection | Stays in the owner's private personal repository with no branch ruleset for now; rulesets are unavailable there. N3 means sandbox sessions cannot push to it. Revisit before wider distribution. |
| Image rebuild for N3 | Coordinate with the ticket lead; rebuild before the next task is registered, because registrations pin the image ID. |

N1 stays a defense-in-depth gap under this policy. Do not extend the hook's patterns
to try to reach the unattended tier. The requirement is met by credential and network
controls.

## E6 closure in source, 2026-09-23

Implemented in `dddc672` under the containment decision above. The owner approved the
design and then the implementation diff. After lockdown, non-root DNS is REJECTed before any ACCEPT, including
over loopback, so the agent cannot query any resolver. Root, meaning the firewall helper
and its refresh loop, may query only the IPv4 nameservers in `/etc/resolv.conf`, and only
for the pinned domain list. Allowlisted names reach the agent through a root-owned
`/etc/hosts` block, rewritten immediately after each activation. Startup and every refresh
also check that a non-root DNS query fails. The Copilot allowlist gained the licence
endpoints found by a names-only discovery run. Evidence is in `VERIFY-ASSERTIONS.md`: 64 of
64 regressions, plus live headless Copilot and Claude runs with the source-mounted scripts.

Status: **deployed 2026-09-23** in image `fda0c678…` (see below). E6's
residual is data encoded in HTTPS to the allowlisted provider endpoints. That is inherent
to using a hosted model. Unattended use additionally still requires E2/E3.

| # | Severity | File | Lines | Vulnerability | Confidence |
|---|----------|------|-------|---------------|------------|
| N4 | ⚪ LOW | `container\init-firewall.sh` | whole script | Firewall is IPv4-only: no `ip6tables` policy, so IPv6 egress would be unfiltered on a host that gives containers IPv6 | 8/10 |

N4 is conditional. The containers observed on this host have only link-local IPv6 on
`eth0` and no global IPv6 route. It matters for portability: on a host or network mode with
routed IPv6, both the HTTPS allowlist and E6 could be bypassed over IPv6.

**N4 remediation in source, 2026-09-23 (`b161401`, owner-approved):**
- Initial lockdown sets the IPv6 policies to DROP whenever `ip6tables` works, allowing only
  loopback, with REJECTs for fast failure.
- It refuses to lock down if a non-loopback IPv6 interface exists but cannot be filtered.
  Otherwise it records that IPv6 rules are absent.
- Refresh refuses if saved IPv6 state is missing or invalid, or if the IPv6 OUTPUT policy
  is no longer DROP.
- 66 of 66 regressions passed. A real lockdown on the current image installed the expected
  IPv6 rules.

Deployed with E6 and N3 on 2026-09-23 (see below).

## Deployment of N3, E6 and N4, 2026-09-23

The ticket lead rebuilt the image from the retained workspace's build context, following
QUICKSTART "Update the firewall without resetting the workspace". The scaffold session
then checked the result independently.

| Item | Result |
|---|---|
| Scaffold revision | `744118f` |
| New tagged image | `fda0c6788cbe37baa15a7ac31e1dcdac65f28da0c7dea382d20bee8c576b9bc8`, created 2026-09-23 18:44:38Z |
| Previous image | `893d19013d16066cacf386c442fd9d906f70792da74a046027f996ca7fed00d6`, now untagged but **retained**. The EEP-24 and JWA-2906 records, plans and collections pin it, so do not prune it. |
| Build-context changes | Only `init-firewall.sh` and `run-copilot.sh` were copied in; the other six inputs already matched. Root `CLAUDE.md`/`AGENTS.md` were unchanged, and the npm credential was staged only for the build. No reset, `--force` or re-prepare. |
| Baked files | All seven Dockerfile-installed files match `744118f`, root-owned; confirmed by both the lead and the scaffold session |
| Agent CLIs | Baked Copilot 1.0.83 and Claude Code 2.1.280. The workspace-staged Copilot that actually runs reports **1.0.86** (directory dated 2026-09-17). Earlier records say 1.0.83 for the staged CLI; the discrepancy is not explained. |
| First guarded start (lead, recorded) | Lockdown (ipset), provider reachable, non-allowlisted egress refused, `non-root DNS refused`, no N3 refusal; exit 0 and recording checksums verified |
| Direct check (scaffold session, disposable container, baked script) | Lockdown exit 0, `non-root DNS refused`, IPv6 state `installed` with DROP policies and loopback-only rules, and the first OUTPUT rule is the non-root DNS REJECT |

N3, E6 and N4 are **deployed** in the current image. Other developers get them by building
from `main`, and they also need the PAT secret. E1 remains deployed.

Not yet exercised on this image: interactive tool use in a real task, including Maven/npm
under closed DNS, and Claude tool calls inside its inner sandbox. The discovery run used the
baked Copilot 1.0.83, but the lead's first start with staged 1.0.86 succeeded.

A minor packaging note: `copilot-defaults/settings.json` is baked with mode 755,
inherited from the build-context file mode. It is root-owned and not writable by the agent.
The Dockerfile now sets it to 0644 explicitly; that takes effect at the next rebuild.

## Phase 1 cleanup, 2026-09-23

Branch `fix/open-items-phase1`. The owner approved the plan and these decisions:

| Decision | Choice |
|---|---|
| I1 identity source | Taken when the sandbox is assembled, from `SANDBOX_GIT_NAME`/`SANDBOX_GIT_EMAIL` or WSL git config. No default |
| D5 | Missing ignored assets fail by default, with an explicit override (Phase 2) |
| E5 devcontainer | Unsupported for agent work; wrappers refuse unguarded starts (Phase 3) |
| D4 | Delete `New-Sandbox.ps1` |
| C3 | First-run Copilot default: Opus 5.5, high effort, long-context tier |
| CI | Deferred |

| Finding | Outcome |
|---|---|
| I1 | `prepare.sh` has no identity default. It keeps the override, requires a per-repo identity and checks it before the firewall opens. `new-sandbox.sh` writes the identity into both clones |
| I2 | `new-sandbox.sh` resolves `%USERPROFILE%` through WSL interop, never `$USER`; `WIN_M2`/`WIN_NPMRC` still override |
| I3 | Already resolved by the earlier harvest rewrite: the cited lines contain no personal paths. A search of every tracked file outside `history/` found personal identifiers only in the I1/I2 lines |
| I4 | Docs: `podman rm` after prepare, and a per-workspace container-name suffix rule. No script generates agent container names |
| C1/C2 | The overlay reads each project's test builder instead of carrying counts, gives Karma and Vitest their own flags, drops the JWA-2905 block, and now says the agent has no DNS (it still claimed DNS was allowed after E6) |
| C3 | Seed changed; docs say "default, written once" rather than "pins" |
| D4 | Script removed; git history keeps it |
| E5 (part) | The assembly script's closing message points at the guarded launchers |

S7 now passes: the static baseline is 22 passed, 0 failed, 2 skipped. The test evidence and
its limits are in `VERIFY-ASSERTIONS.md` ("Personal defaults and overlay cleanup"). None of
this is deployed in the image yet.

## Phase 2: reset safety and required assets, 2026-09-23

Branch `fix/open-items-phase2`, from `main` after Phase 1.

| Finding | Outcome |
|---|---|
| V2 | Every run requires `SANDBOX_ROOT` to be strictly inside `$HOME`, with no symlink in the path, and apart from `SOURCE_ROOT`, both resolved source repos and the scaffold. `--force` deletes only a directory with the new `.pera-sandbox-workspace` marker or the legacy sandbox layout. It refuses when a task registration names or overlaps the workspace (or a record is unreadable), when `sandbox-round.sh inspect` reports a repo other than `clean` or cannot inspect it, when linked worktrees or unexpected top-level entries exist, or when HEAD, a local branch or any stash entry (loose or packed) is contained in no ref of the source repo. `--discard-unharvested` lists those and proceeds, except for a running container or a pending round recovery, which always refuse. Deletion moves the tree to a tombstone and then runs `rm -rf --one-file-system` |
| D5 | The four git-ignored assets (`.github/copilot-instructions.md`, `.github/a11y.instructions.md`, both `SKILL.md` files) are required, as regular files in the source and again in the sandbox after the copy, unless `--allow-missing-assets` is given. The copy now merges directory contents, so a tracked file under `.agents` can no longer nest the overlay at `.agents/.agents`. `prepare.sh` still only warns |

Design points:
- No host git runs against the old sandbox's repositories: their config is agent-written,
  and `core.fsmonitor`, filters or hooks would execute on the host. Working-tree state
  comes from `inspect` in its network-less, capability-free container. Branch tips are
  read from ref files as data. Only the trusted source repositories are queried with host git.
- "Harvested" means some ref of the source repository contains the commit, not merely
  that its object exists there. The real workspace's HEAD is contained only by
  `refs/sandbox/JWA-2906-R1` in the host `prj`, so a branches-only check would have
  flagged integrated work.
- **Effect on this host:** `~/pera-sandbox` is registered to EEP-24 and JWA-2906, so a
  plain `--force` there now refuses. A new task should use a new `SANDBOX_ROOT`.

**Independent review.** A context-isolated reviewer found one real fail-open: gc packs
`refs/stash`, which the first version did not read. It also found gaps: older stash entries,
linked worktrees, unreadable or nested registrations, symlinks via `link/`, unresolved source
repos, `under /`, non-atomic deletion, round-recovery state outliving a reset, and the asset
copy nesting. All of these were fixed in `cc95a0d`. Not fixed: the window between the checks
and the tombstone rename. It is narrow, and a container that is running at check time is
already refused.

Not covered: tags and other non-branch refs, reflog-only commits, and the contents of
unexpected top-level entries, which are reported but not inspected. Evidence:
`verify-assembly.sh`, 33 of 33; see `VERIFY-ASSERTIONS.md`.

## Phase 3: inner sandbox and guarded startup, 2026-09-24

Branch `feat/phase3-inner-sandbox-startup`. Spec: [design/phase3-inner-sandbox-and-startup.md](design/phase3-inner-sandbox-and-startup.md),
approved 2026-09-24 with the recommended option on every decision. Its §9 lists the
departures (D-1 to D-9). **Implemented in source, not deployed.**

| Finding | Outcome in source |
|---|---|
| E2/E3 | `container/claude-managed-settings.json` is baked root-owned to `/etc/claude-code/managed-settings.json`, with an empty root-owned `managed-settings.d/`. It requires the sandbox (`failIfUnavailable`, `allowUnsandboxedCommands: false`, `bwrapPath`, weaker modes off) and holds the deny rules. It locks lower-scope permission rules, hooks and MCP servers (`allowedMcpServers: []`) and keeps network domains managed-only. `allowWrite` stays `["/tmp"]`. S10 now asserts this file. |
| N5 | The launchers run only the image-baked CLIs; prepare no longer stages CLIs and deletes an old `.agent-cli/`. Before lockdown, `run-agent` refuses (exit 78) when: the project settings differ from the canonical file or the legacy hash; `settings.local.json` or `.mcp.json` exists; the user settings hold a key outside the reviewed allowlist; `remote-settings.json` is anything but `[]`/`{}`; or `.claude.json` configures MCP servers. It unsets the five managed-policy redirect variables. Managed `Edit` denies keep the file tools off both settings stores during a session. |
| E5 | Root-owned wrappers `/usr/local/lib/pera-sandbox/bin/{claude,copilot}`, first on `PATH`, refuse unless the root-owned lockdown record exists and all four capability sets are empty. Otherwise they exec the baked CLI; `--version`/`--help` alone pass through. The devcontainer is marked unsupported for agent work. |

**Also fixed:** `run-copilot`'s static-CIDR fallback was unreachable: under `set -e` and
`pipefail`, a failed `api.github.com/meta` fetch exited the launcher (D-8). The prepare
recipes no longer mount the Claude login volume (D-7).

**Rollout hazard avoided (D-9).** The canonical project settings keep the old deny rules
and sandbox lists. A workspace assembled from this scaffold but run on the old image is
therefore no weaker than before, although it gains none of Phase 3.

**Not covered:** instruction files (`CLAUDE.md`, skills, agents) persisting between sessions;
Copilot's `~/.copilot` configuration; and operator-supplied launcher arguments such as
`--settings`.

**Live, on a test image** (the current image plus the Phase 3 files, root-owned; spec §10):
- **L2, L7, L8, L10 pass.** Writes outside `/workspace` and `/tmp` are refused, including
  with `dangerouslyDisableSandbox`. DNS and egress are closed inside the sandbox. The
  wrappers refuse. The agent cannot write its project settings from Bash or the Write tool.
- **L3:** with capabilities held, the CLI still starts and every Bash call fails. Nothing
  runs unsandboxed, but there is no start-time refusal.
- **L4c:** a project `allowWrite` **does** merge past the managed policy and widen writes.
  That confirms N5's premise for lists. A project `excludedCommands` did not escape the
  sandbox (L4).

These observations are not deployment: they must be repeated on the rebuilt image.

**Independent review** ([spec §11](design/phase3-inner-sandbox-and-startup.md#11-independent-review-and-fixes-2026-09-24)).
A context-isolated reviewer found two high-severity gaps in N5, both fixed and covered by
new `verify-startup.sh` scenarios that fail when their fix is removed:

- **H1.** Copilot's loader would run a newer package from `~/.copilot/pkg` on its
  persistent volume, including for the `--version` banner, which ran before the capability
  drop. Every Copilot call now gets `--no-auto-update` with the cache redirects removed; a
  `pkg` directory refuses the start; and both banners run with capabilities dropped.
- **H2.** A `/workspace/.git` would make Claude read local settings from an unchecked
  `prj/.claude/settings.local.json`, and a live probe showed sandboxed Bash can write that
  file. `run-agent` now refuses a root `.git` and unsets the git redirect variables.

Also fixed: a FIFO `.claude.json`, more settings-redirect variables, and the remaining S10
keys. Accepted: the server-settings companion files and `policy-limits.json`, which can only
relax organisation limits, and the need to run one session per workspace at a time.
Still not covered: Copilot's `installed-plugins/` and the rest of `~/.copilot`.

**Pre-merge two-pass review** ([spec §12](design/phase3-inner-sandbox-and-startup.md#12-pre-merge-two-pass-review-2026-09-24)).
Pass 1 was a fresh Claude reviewer without the narrative. Pass 2 was GPT-6 Astra through
GitHub Copilot, run inside the sandbox with every input read-only; it could not read the
raw live transcripts because of Copilot path verification.

Fixed:
- **Interactive and login shells bypassed the `claude` wrapper.** The stock `~/.bashrc`
  prepends `~/.local/bin`. The image now leaves no `claude` there.
- **A hard-link alias passed the settings checks.** Every validated file must now be singly
  linked.
- **The documented host recovery followed a planted symlink.**
- **`COPILOT_CLI_DIST_DIR`** is now unset.
- **Doc overclaims** are corrected.

Left open for the owner:
- confirmation of decision 4, which was the lead's proposal;
- the unmet L3 pass condition: an unguarded start that bypasses PATH is not refused.

Added to the deployment gate:
- `/status` and the remaining L4 keys on the rebuilt image;
- a supervised real build and unit-test run.
