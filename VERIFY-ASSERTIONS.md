# Verification assertions

The scaffold currently promises around two dozen invariants in prose and checks two of them
(`init-firewall.sh`'s positive and negative smoke probes). This file is the assertion list that
closes that gap. It is a **specification, not an implementation** — the judgment is in choosing
and phrasing the assertions; turning them into bash is mechanical and delegable.

## Two scripts, four modes

The assertions split by what they can observe, and that split is not cosmetic — several
assertions are impossible in the wrong context.

| Script | Mode | Where it runs | Cost |
|---|---|---|---|
| `verify-scaffold.sh` | (none) | Windows host, Git Bash or WSL, against this directory | seconds, no container |
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
| S1 | Zero CR bytes in every `*.sh`, `Dockerfile`, `dockerignore`, `*.json`, and `overlay/CLAUDE.md` | count `0x0d` bytes; **do not** use `grep -c $'\r'`, which false-positives in Git Bash — use `od -An -tx1 -v` or `awk '/\r$/'` | FAIL |
| S2 | Every `*.sh` parses | `bash -n` | FAIL |
| S3 | No `shellcheck` errors (warnings allowed) | `shellcheck -S error`, `SKIP` if absent | WARN |
| S4 | Every path the Dockerfile `COPY`s from `container/` exists | parse `COPY container/...` lines | FAIL |
| S5 | The Dockerfile's `sed`/`chmod` file lists match its `COPY` list | compare the two sets | FAIL |
| S6 | Every file `new-sandbox.sh` copies from the scaffold exists (`overlay/CLAUDE.md`, `overlay/.claude`, `.devcontainer`, `container`, `dockerignore`) | existence check | FAIL |
| S7 | No personal path or name anywhere | grep for `/home/su`, `Users/su`, `zsu@`, and any hardcoded human name used as a default value | FAIL |
| S8 | `overlay/.claude/settings.json` and `container/copilot-settings.json` are valid JSON | `jq empty` | FAIL |
| S9 | `.devcontainer/devcontainer.json` is valid **JSONC** | it contains `//` comments, so plain `jq` fails — strip comments first or use a JSONC parser. A naive `jq empty` here is a false failure | FAIL |
| S10 | `overlay/.claude/settings.json` still declares `defaultMode: bypassPermissions`, a non-empty `deny` list, and `sandbox.enabled: true` | `jq` | FAIL |
| S11 | `init-firewall.sh`'s `open` branch still guards against reopening a locked-down container | grep the branch for the marker-chain check and, once implemented, the `/run/claude-lockdown-domains` check | FAIL |
| S12 | `lockdown` still commits its domain list and reuses it on later calls | grep for the `COMMITTED` file logic | FAIL |
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
| S24 | The Copilot policy-hook chain is intact: both files shipped, `COPY`d into `/etc/github-copilot/policy.d/`, `chown root:root`, policy file not group/world-writable, registration naming the installed guard path, registered on `preToolUse`, `git-push` rule present, `node --check` clean | this hook — not the `--deny-tool` flags — is what denies `git -C . push`; every link fails silently and open, so each is asserted rather than trusted | FAIL |

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
| X1 | `sudo /usr/local/bin/init-firewall.sh open` exits 3 | **If it exits 0 the network is now open** — the check must immediately re-lock and report FAIL loudly. Run only in a throwaway container | FAIL |
| X2 | `sudo init-firewall.sh lockdown evil.example.com` does not change the allowlist | run it, then confirm `evil.example.com` is still refused and the committed file is unchanged | FAIL |
| X3 | No egress window during a lockdown refresh | the current `lockdown` flushes to `ACCEPT` policies before rebuilding, so a probe looped across a refresh should catch reachability it must not have. Expect this to FAIL until E1 is fixed — it is the regression test for that fix | FAIL |

---

## Deliberately not asserted

- **DNS egress being open.** Accepted by design; A12 asserts it works rather than that it is
  closed.
- **That the agent cannot read its own auth token.** It can, via Bash; the settings deny rule
  covers the Read tool only. Asserting otherwise would encode a false claim.
- **Anything requiring the dev AS400/Oracle.** Unreachable by design.
- **Integration tests.** Same reason.

## Notes for whoever implements this

- **The S-series is implemented** in `verify-scaffold.sh` (2026-09-09). The P/A/G/X series are
  not. Current result on a clean tree: 19 pass, 1 fail (S7, the I1/I2/I3 regression test), 1
  warn (S11, tracking E1a), 2 skip (no shellcheck, no VERSION).
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
- Nothing in this list needs network access except A3–A7 and P8.
- Keep each assertion independent — no shared state, no ordering dependency — so a failure
  localizes. `set -e` is wrong for this script; collect results and exit at the end.
- Assertions S11–S18 and A8–A11 exist to stop an isolation invariant regressing silently. When
  one of them fails, the right response is almost never to relax the assertion.
