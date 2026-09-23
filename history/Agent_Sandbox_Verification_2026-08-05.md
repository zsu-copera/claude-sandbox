# Agent Sandbox — fixes and verification, 2026-08-05

Follow-up to [Agent_Sandbox_Findings_2026-07-28.md](Agent_Sandbox_Findings_2026-07-28.md).
That report found three defects from inside a sandbox session. This one records what was
fixed, the evidence for each, and three new problems the work surfaced.

Everything below was measured on `localhost/pera-sandbox` rebuilt from the current scaffold,
against a freshly assembled `~/pera-sandbox` (agencyWWW warmed, 409 MB Maven cache).

---

## 1. Warm Maven cache unusable offline — FIXED

The blocking defect. Artifacts were stamped `_remote.repositories` → `nexus=`, but the
`settings.xml` declaring that repository id is credentialed and `run-agent` deletes it by
design, so nothing at agent-run time knew the repo id and `mvn -o` failed on the first plugin.

**Fix:** `prepare.sh` strips the tracking files after warming:

```bash
find "$WS/.m2/repository" -name _remote.repositories -delete
```

**Why not the alternatives.** The original report suggested baking the warm-up `settings.xml`
into the image. Don't: it carries Nexus credentials, `run-agent.sh` deletes it on purpose, and
the report's own in-session fix at `~/.m2/settings.xml` would have been removed on any normal
boot — it only held because it was applied mid-session. The strip also belongs in `prepare.sh`
rather than the Dockerfile, because the cache lives on the bind-mounted workspace, not in the
image.

**Evidence**

| Check | Result |
|---|---|
| Mechanism, before/after on the same warm cache | `mvn clean -P agencyWWW -o` failed in 0.556 s → after stripping, full `mvn clean install -P agencyWWW -DskipTests -o` **BUILD SUCCESS** 02:56, produced a 102 MB `agency.war` |
| Runs during a real prepare | log shows `==> Making the warmed cache offline-resolvable` after `BUILD SUCCESS` |
| Tracking files after prepare | **0** |
| Offline resolution inside a live agent session | all modules resolved |

**Stable across builds.** `install` re-creates `_remote.repositories` for the 6 locally-built
`org/copera/*` artifacts only, and writes them with an *empty* repository id
(`agency-1.0.war>=` rather than `maven-clean-plugin-3.2.0.jar>nexus=`), which offline mode
accepts unconditionally. The failure does not creep back as the agent builds.

---

## 2. `bwrap` failed on every Bash call — FIXED

Root-caused, not worked around. bubblewrap refuses to start when it is not setuid, is running
as non-root, and holds capabilities. podman puts `--cap-add` into the **ambient** set so a
non-root container user keeps them — so the `NET_ADMIN`/`NET_RAW` the firewall needs was
exactly what bwrap rejected. The two isolation layers were mutually exclusive.

| Container started | `CapPrm`/`CapAmb` | `ipset` (firewall) | `bwrap` |
|---|---|---|---|
| `--cap-add=NET_ADMIN,NET_RAW` | `0x3000` (bits 12+13) | works | **fails** |
| no `--cap-add` | `0x0` | blocked | **OK** |

The report's first suggested remedy — grant bwrap the capabilities it expects — would have
made this strictly worse. Note also that `sandbox.failIfUnavailable: false` does not catch it:
bwrap is present and refusing, not missing.

**Fix:** drop capabilities after lockdown, before starting the agent, in `run-agent.sh` and
`run-copilot.sh`:

```bash
setpriv --inh-caps=-all --ambient-caps=-all claude --dangerously-skip-permissions "$@"
```

`setpriv` rather than `capsh --caps=""` for two reasons: permitted capabilities are recomputed
at `exec` from (inheritable ∪ ambient), so clearing those two is sufficient and is what bwrap
actually inspects; and `setpriv` execs a real argv, so `"$@"` passes through without
shell-string requoting. The 15-minute refresh loop is forked earlier and reaches root via
`sudo`, so it is unaffected.

**Verified:** `CapPrm` → 0, `bwrap` runs, `claude --version` still resolves through `setpriv`,
and a live headless session executed Bash tool calls with zero `bwrap` errors.

---

## 3. NEW — a working `bwrap` breaks the build, because Java ignores `$TMPDIR`

Fixing bwrap exposed this immediately: the first real agent session failed at
`Error assembling WAR: Problem creating war: Execution exception: Read-only file system`,
alongside `/tmp/jansi-2.4.1-*.lck (Read-only file system)`.

The sandbox makes only the working directory and a session temp directory writable, and points
`$TMPDIR` at the latter. **`java.io.tmpdir` does not honour `$TMPDIR`** — it defaults to `/tmp`
— so jansi's native-library extraction and plexus-archiver's WAR staging both write to a
read-only `/tmp`.

**Fix:** `overlay/.claude/settings.json` grants exactly that one path:

```json
"sandbox": {
  "enabled": true,
  "failIfUnavailable": false,
  "filesystem": { "allowWrite": ["/tmp"] },
  "network": { "allowedDomains": ["api.anthropic.com"] }
}
```

**Evidence** — same image, same warm cache, same command, only the setting differs:

| Config | Runs | Sandboxed build | Read-only errors | Unsandboxed retry |
|---|---|---|---|---|
| Defaults (no `allowWrite`) | 2 | **failed both** | 5–7 per run | yes, both — recovered via `dangerouslyDisableSandbox` |
| `allowWrite: ["/tmp"]` | 3 | **passed all** | 0 | none |

**Why this option.** Three alternatives also make the build pass, and all are worse:

| Alternative | Why not |
|---|---|
| `filesystem.disabled: true` | Discards all filesystem confinement, and is **not honored from project settings** — only user, managed, or `--settings`. Our config is project scope, so it would need extra plumbing to take effect at all |
| `excludedCommands: ["mvn *"]` | Unsandboxes the main workload; `ng`, `npm` and `grunt` would follow |
| `sandbox.enabled: false` | Gives up a layer that demonstrably works |
| Do nothing | `allowUnsandboxedCommands` defaults to `true`, so failures often self-heal — but each build burns a failed sandboxed attempt first, and the very first session reported failure without retrying at all |

`allowWrite` is an array key merged across every settings scope, so project scope works. The
security cost is small in context: the docs' warning about `allowWrite` concerns paths holding
executables on `$PATH` or shell configuration, and `/tmp` is an ephemeral per-container tmpfs.

---

## 4. NEW — the agent had unrestricted root

The image granted `vscode ALL=(ALL) NOPASSWD:ALL`, commented as "the firewall scripts need
passwordless sudo". Every `sudo` call site in the whole scaffold is `init-firewall.sh` — five
of them, across `prepare.sh`, `run-agent.sh` and `run-copilot.sh`. Nothing else needs it.

The consequence was measurable, and **dropping capabilities does not fix it**: `sudo` reaches
root, and root draws capabilities from the still-intact bounding set. With caps dropped,
`sudo ipset ...` still succeeded — the agent could flush its own firewall, and `sudo cat` past
the `Read` deny rules.

**Fix:** scope the grant, and close the two remaining paths inside the script, since sudoers
cannot constrain arguments here (callers legitimately pass their own domain sets):

```
vscode ALL=(ALL) NOPASSWD: /usr/local/bin/init-firewall.sh
```

* **`open` is refused** (exit 3) once the `CLAUDE_LOCKDOWN` marker chain exists — a marker the
  script already created at lockdown but never read. Per-container, so `prepare` (a separate
  container that never locks down) still opens normally.
* **The allowlist is sticky.** The first *successful* lockdown commits its domain list to
  `/run/claude-lockdown-domains`; later lockdowns ignore their arguments and reuse it. Without
  this, `sudo init-firewall.sh lockdown attacker.example.com` was an egress channel and the
  `open` guard was only half a door. Committed *after* the rules apply, so a lockdown that
  bailed out doesn't pin a bad list. The refresh loop and Copilot's `--login` mode are
  unaffected: each container's domain set is fixed before its first lockdown.

**Verified:** `sudo bash`, `sudo cat /etc/shadow`, `sudo iptables -F` and `sudo chown` all
denied; `init-firewall.sh` permitted with `open`, bare `lockdown`, and `lockdown <domains>`;
`visudo -c -q` passes during the image build; `open` refuses with exit 3 when locked; a
differing lockdown list is ignored with a `NOTE`; a failed first lockdown commits nothing; and
the agent (uid 1000) can neither read, delete, nor overwrite the committed list.

Narrowing sudo also broke `devcontainer.json`'s `postCreateCommand`, which ran
`sudo chown -R vscode:vscode` on the two config volumes and `&&`-chained the needed
`git config --global --add safe.directory '*'` behind it. The `chown` turned out to be
unnecessary: under `--userns=keep-id`, rootless podman creates volumes as the host user, which
maps to `vscode` inside, so they arrive owned and writable — confirmed for `.copilot`, which
does not even exist in the image. `postCreateCommand` is now just the `git config`.

---

## Issues that belong to `prj`, not the sandbox

Four are confirmed defects. One — the Sass task — is an observation that survived a deliberate
attempt to reproduce it, and is written up honestly as unresolved rather than as a defect to go
and fix.

1. **Hardcoded `C:\jboss\EAP-8.0.0` output paths — five modules, not one.** The original
   report found `agencySecurityRealm` (lines 31 and 56). Also affected:
   `vendorSecurityRealm`, `commonsWrapper`, `intraSecurityRealm`, `invSecurityRealm`. Only
   `agencySecurityRealm` surfaced because it is the only one in `agencyWWW`, so a single
   `agencySecurityRealm/C:/` gitignore entry covers one profile of five. Confirmed live:
   `git status` in the sandbox shows `?? agencySecurityRealm/C:/` **and** `?? .agents/`, both
   of which a `git add -A` would sweep into a review commit.
2. **A one-off Sass failure — mechanism plausible, NOT reproducible.** Recorded because the
   observation is real and the code pattern is genuine, but do not treat it as a confirmed bug.

   *What was seen, once:* on the first post-prepare build, Grunt's `sassTask` failed with
   `Error reading target/agency/css/apps: file already exists`, naming two different `.scss`
   files. It has not recurred.

   *The code pattern, which is factual:* `grunt-pera/grunt-pera-sass.js:25` calls
   `PGU.runProcess(command)` inside a `for` loop **without awaiting it**, so all 5 `agency`
   `.scss` files spawn `npm run sass` at once — and all 5 write into the same
   `target/agency/css/apps`, which after `mvn clean` does not exist yet. `shared` has the same
   shape with 2 files into `css/`. That suggested a check-then-create race on the shared output
   directory. Notably the sibling `terserTaskFunc` has the *identical* unawaited-promise
   pattern and does **not** race, because the parent pre-creates each destination with
   `FS.mkdirSync(destPath, {recursive: true})` before spawning. `sassTask` is the only one of
   the three tasks that does neither.

   *Attempt to reproduce — 45 isolated `sassTask` runs, every one clean:*

   | Condition | bwrap | `/tmp` grant | Runs | Failures | Silent partial |
   |---|---|---|---|---|---|
   | isolated `sassTask` | no | n/a | 25 | 0 | 0 |
   | isolated `sassTask` | yes | absent | 10 | 0 | 0 |
   | isolated `sassTask` | yes | present | 10 | 0 | 0 |

   Each iteration deleted `target/agency/css` first, recreating the post-clean condition. Across
   all 51 observed `sassTask` executions (the 45 above plus 6 full profile builds) there was
   exactly **one** failure: the original. Two hypotheses are therefore dead — it is not a plain
   `/tmp` artifact (the task runs fine without the grant) and it is not bwrap timing alone.

   *What is still untested:* concurrent load. The original failure came from `concurrentTask`,
   which runs `terserTaskFunc`, `angularTaskFunc` and `sassTask` as three simultaneous grunt
   processes, the angular build being heavy. Confirming or killing the hypothesis means looping
   full `mvn clean install -P agencyWWW` builds, ~3 min each; the full-build path is currently
   3/3 clean under the committed configuration.

   *Also worth knowing:* zero silent-partial results in 45 runs — no case of a zero exit code
   with fewer than 5 CSS files. That retires the worst version of this concern, a green build
   shipping incomplete CSS.

   *Recommendation:* don't change `prj` for the race. Making `sassTask` consistent with
   `terserTaskFunc` (pre-create the output directory in the parent), keeping the `this.async()`
   callback so completion and failure are deterministic, and returning the real exit code from
   `runProcess` instead of a hardcoded `code: 0`, are all defensible on their own merits as
   cleanup. They are not justified by a demonstrated defect. Dead config while you are in there:
   the `sourceMap: true` key in every `grunt.json` sass entry is never read.
3. **UTF-8 source mangled under US-ASCII.** `agencySecurityRealm/.../AgencyFormAuthenticationMechanism.java:209`
   contains a UTF-8 em-dash; the container's platform encoding is `ANSI_X3.4-1968`, so the
   build logs `unmappable character (0xE2/0x80/0x94)` as `[ERROR]` yet still reports SUCCESS —
   javac treats these as warnings. The literal is silently corrupted. Any Linux/CI build with
   no `LANG` set has the same problem; setting `project.build.sourceEncoding` fixes it.

4. **`ng test` is broken on `main` for 14 of 17 agency projects.** The highest-impact item on
   this list, and it undermines half the sandbox's purpose. `ng test` dies before running
   anything:

   ```
   Schema validation failed: Data path "/polyfills" must be array.
   ```

   The `@angular/build:karma` builder requires `polyfills` as an array; on `main` only
   `agency-root`, `legacy-layout` and `retirees-war-limit` have it. Reproduced identically on a
   Windows workstation and in the sandbox, so it is a repo defect, not environmental.

   **The fix already exists but is stranded.** Commit `14fa3296a` on
   `EPD-673-tooltip-standarization` converted all 17 targets to the array form — bundled into the
   popover migration rather than landed as its own change. That branch is not on `main`, which is
   23 commits ahead of the fork point, so porting the `polyfills` change is its own task
   independent of EPD-673 merging.

   Zero-mutation workaround to run the suite on `main` meanwhile (`karma.conf.js` sets
   `browsers: ['Chrome']` and `singleRun: false`, hence both overrides):

   ```bash
   cd prj/agency && node_modules/.bin/ng test --project agency-angular-tests \
     --watch=false --browsers=ChromeHeadless \
     --polyfills src/main/angular/configurations/polyfills.ts
   ```

5. **The four known test failures are real defects — and the 2026-07-28 report's explanation was
   wrong.** That report suggested the three `FileUploadService` timeouts might be "a slower
   containerised CPU… exceeding Jasmine's default 5 s interval, which would make them flaky
   rather than broken", and asked for a comparison against a developer workstation. That
   comparison has now been run, and the hypothesis does not hold: the entire suite completes in
   **15.9 s** on Windows and the same specs still time out at 5 s. A spec that never finishes
   inside a 16-second suite is not starved of CPU.

   | | Windows (`main`) | Sandbox (`main`) |
   |---|---|---|
   | Total / failed / passed | 72 / 4 / 68 | 72 / 4 / 68 |
   | Failing specs | same four | same four |
   | Reasons | 1× `Expected undefined`, 3× timeout | 1× `Expected undefined`, 3× timeout |

   * `FileUploadService fileUploadHandler should call uploadFile for valid submissions` — timeout
   * `FileUploadService fileUploadHandler should call uploadFile n times for n valid submissions` — timeout
   * `FileUploadService fileUploadHandler should inspect ASCII files` — timeout (all three share a fixture)
   * `GenderReactiveComponent should be disabled when disabled = true` — `Expected undefined to be true`

   **Corollary worth keeping in mind: the sandbox adds no test failures of its own.** The results
   are identical to a developer workstation, so it is a faithful `ng test` environment once
   `polyfills` is valid — don't chase test differences as sandbox artifacts. Note also that the
   2026-07-28 figures (67 specs, 63 passed) came from the `EPD-673` branch, not `main`, which is
   why the counts differ from the 72 here.

---

## Not verified

* `run-copilot` since the `setpriv` change — the script parses and the mechanism is shared with
  `run-agent`, but no Copilot session has been run.
* The VS Code Dev Containers path end-to-end, including the changed `postCreateCommand`.
* The one-way `open` guard and sticky allowlist *inside a live agent session* — both were
  tested in isolation, and lockdown itself is confirmed working in a real `run-agent`.
* Other Maven profiles (`memberWWW`, `vendorWWW`, `investment`). The cache fix is
  mechanism-level so it should apply identically, but they are unwarmed and unexercised.
* Whether the produced WARs deploy, and anything touching AS400/Oracle — out of scope by design.
* *(resolved — see prj issue 5 above)* The four Angular test failures have now been compared
  against a developer workstation. They are real defects, not container artifacts.

*Verified 2026-08-05 across a rebuilt image, one full prepare cycle, nine headless agent sessions,
45 isolated `sassTask` runs, and paired `ng test` runs on the sandbox and a Windows workstation.*
