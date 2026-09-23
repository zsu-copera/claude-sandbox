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

Next, complete and record the [existing-sandbox update procedure](QUICKSTART.md#update-the-firewall-without-resetting-the-workspace):
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
| `main` / distribution copy | `main` still `91e7b1f`; Documentation copy not promoted |

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
