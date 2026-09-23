# Agent Sandbox Findings — `agency` profile warm-up audit

Findings from an audit of the PERA agent sandbox container (Claude Code session, 2026-07-28).
The question asked was narrow — *is the `agency` profile actually warmed?* — and the answer is
**yes, but the build command documented in `CLAUDE.md` / `AGENTS.md` fails as shipped.** Three
image-level defects are recorded below with the evidence and the fix for each.

Environment audited: Linux 6.6.87.2 (WSL2 host), user `vscode`, Maven 3.9.9 (`/opt/maven`),
OpenJDK 17.0.18 (Red Hat), Node 22.13.0, Chromium 150.0.7871.46 (`CHROME_BIN=/usr/local/bin/chrome`).

---

## 1. Maven cache is warm but unusable offline — repo-id tracking mismatch

**Severity: blocking.** This is the first command any agent runs, and it fails in 0.3 s.

`mvn clean install -P agencyWWW -DskipTests -o` fails on the very first plugin:

```
[INFO] Artifact org.apache.maven.plugins:maven-clean-plugin:pom:3.2.0 is present in the local
       repository, but cached from a remote repository ID that is unavailable in current build
       context, verifying that is downloadable from [central (https://repo.maven.apache.org/maven2)]
[ERROR] Plugin org.apache.maven.plugins:maven-clean-plugin:3.2.0 or one of its dependencies
        could not be resolved:
[ERROR]   Cannot access central (https://repo.maven.apache.org/maven2) in offline mode and the
          artifact ... has not been downloaded from it before.
```

### Root cause

The artifacts are present. The cache is at `/workspace/.m2/repository` (set via
`MAVEN_OPTS=-Dmaven.repo.local=/workspace/.m2/repository`): **414 MB, 564 jars**, including the
`org/copera/{agency,common,shared,dwr,web,services-dataqueue}` artifacts. `maven-clean-plugin-3.2.0.jar`
is on disk.

Every artifact carries a `_remote.repositories` tracking file attributing it to a repository id
named `nexus`:

```
# /workspace/.m2/repository/org/apache/maven/plugins/maven-clean-plugin/3.2.0/_remote.repositories
maven-clean-plugin-3.2.0.jar>nexus=
maven-clean-plugin-3.2.0.pom>nexus=
```

No settings.xml declaring a `nexus` repository exists anywhere in the image:

- `~/.m2/` — **did not exist at all** (the `~/.m2` referenced in the sandbox instructions is not
  the cache actually in use; `MAVEN_OPTS` redirects it to `/workspace/.m2`)
- `/workspace/.m2/` — contains only `repository/`, no `settings.xml`
- `/opt/maven/conf/settings.xml` — stock Apache defaults, no mirrors or repos configured

Maven's enhanced local repository therefore treats every cached artifact as "not available from
any repository in this build context" and, in offline mode, refuses it. The warm-up ran with a
settings.xml that was not preserved into the final image.

### Fix (either works)

**Option A — ship a settings.xml** (what was verified in-session). Write `~/.m2/settings.xml`:

```xml
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <profiles>
    <profile>
      <id>nexus-offline</id>
      <repositories>
        <repository>
          <id>nexus</id>
          <url>https://nexus.invalid/repository/maven-public/</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </repository>
      </repositories>
      <pluginRepositories>
        <pluginRepository>
          <id>nexus</id>
          <url>https://nexus.invalid/repository/maven-public/</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </pluginRepository>
      </pluginRepositories>
    </profile>
  </profiles>
  <activeProfiles><activeProfile>nexus-offline</activeProfile></activeProfiles>
</settings>
```

Only the **id** has to match the tracking files; the URL is never contacted under `-o`. Outside the
sandbox this should of course carry the real Nexus URL — ideally the same settings.xml used during
warm-up, which is the cleaner permanent fix.

**Option B — strip the tracking files** from the baked cache during image build:

```bash
find /workspace/.m2/repository -name _remote.repositories -delete
```

Artifacts with no tracking file are treated as locally installed and resolve unconditionally.

### Two dead ends worth recording

- **The URL scheme must be `https`.** With `http://`, Maven's built-in `maven-default-http-blocker`
  mirror intercepts the repo and the failure returns identically, just renamed:
  `Cannot access maven-default-http-blocker (http://0.0.0.0/) in offline mode`.
- **`-llr` / `--legacy-local-repository` is gone.** The classic workaround for exactly this problem
  is unsupported in Maven 3.9.9 — it prints `UNSUPPORTED: Use of this option will make Maven
  invocation fail.` and dumps the help text. Don't put it in any runbook.

---

## 2. The `bwrap` command sandbox is broken

Every `Bash` tool call fails before the command runs:

```
bwrap: Unexpected capabilities but not setuid, old file caps config?
```

The agent harness wraps commands in bubblewrap for filesystem/network confinement. Under this
container's capability configuration `bwrap` refuses to start, so **100% of shell commands fail**
until the agent disables the sandbox and re-runs. Every command in this audit ran unsandboxed.

Consequences worth weighing outside the sandbox:

- The intended second layer of confinement (the harness's own path/network allowlist) is not in
  effect. Only the container boundary and the firewall are protecting the host.
- Agents burn a failed tool call plus a permission decision on every command, and are trained by
  the failure to reach for the "disable sandbox" escape hatch reflexively — which is exactly the
  habit we don't want them forming.

Likely fixes: grant the container the capabilities `bwrap` expects (or run it privileged enough to
create user namespaces), install `bwrap` setuid, or disable the harness sandbox explicitly in
settings so it isn't attempted at all.

---

## 3. `agencySecurityRealm` writes a literal `C:` directory into the repo

`agencySecurityRealm/pom.xml` hardcodes a Windows JBoss module path in two places
(lines 31 and 56):

```xml
<outputDirectory>C:\jboss\EAP-8.0.0\modules\pera\org\copera\agency\security\auth\realm\main</outputDirectory>
```

On Linux this is a relative path, so the build creates
`prj/agencySecurityRealm/C:/jboss/EAP-8.0.0/modules/pera/org/copera/agency/security/auth/realm/main/`
inside the working tree. It is **not** in `.gitignore`, so it shows up as untracked in every
`git status` an agent runs — noise that invites an agent to `git add -A` it into a review commit.

Two independent fixes, both cheap: add `agencySecurityRealm/C:/` to `.gitignore` in `prj`, and/or
make the output directory a property so Linux/CI builds can override the Windows default.

---

## Verification results — the `agency` profile *is* warmed

All of the following passed offline (no network), after applying the §1 fix. Nothing else was
missing; no other workaround was needed.

| Check | Result |
|---|---|
| `mvn clean install -P agencyWWW -DskipTests -o` | **BUILD SUCCESS**, 03:48 min — produces `agency/target/agency.war` |
| `mvn clean install -P agencyintra -DBUILD=productionIntra -DskipTests -o` | **BUILD SUCCESS**, 02:28 min — produces `agency/target/iagency.war` |
| `mvn install -P agencyWWW -pl agencySecurityRealm -DskipTests -o` | **BUILD SUCCESS** (single-module, confirms `~/.m2/settings.xml` works with no `-s` flag) |
| Angular unit tests (`agency-angular-tests`) | Runs on ChromeHeadless — **63 passed, 4 failed of 67** |

`agencyWWW` per-module timings: ParentBuild 0.7 s · Services-dataqueue 6.9 s · PERA Web Shared
28.7 s · Common library 23.1 s · Agency Web Application 2:47 min · agencySecurityRealm 0.9 s.

Node/Angular tooling present exactly where it is needed — `prj/agency/` and `prj/shared/` each have
`node/` (v22.13.0) + `node_modules/` (494 packages in agency), and `prj/node_modules/` has the root
Grunt tooling. The other `agencyWWW` modules (`common`, `agencySecurityRealm`, `services-dataqueue`)
have no frontend build and need none. `prj/agency/angular.json` defines 17 projects, all with a
`test` target, and `agency-root` carries both `production` and `productionIntra` build
configurations — so the intra path is genuinely exercisable.

### The 4 Angular test failures are pre-existing, not environmental

Recorded here so the next agent doesn't chase them as sandbox breakage. None involve network,
DB, or missing tooling:

| Spec | Failure |
|---|---|
| `FileUploadService fileUploadHandler should call uploadFile n times for n valid submissions` | `Timeout - Async function did not complete within 5000ms` |
| `FileUploadService fileUploadHandler should inspect ASCII files` | `Timeout - Async function did not complete within 5000ms` |
| `FileUploadService fileUploadHandler should call uploadFile for valid submissions` | `Timeout - Async function did not complete within 5000ms` |
| `GenderReactiveComponent should be disabled when disabled = true` | `Expected undefined to be true` at `apps/agency-angular-tests/src/app/tests/reactive-gender-selector.component.spec.ts:91` |

The three timeouts share a fixture; a slower containerised CPU may simply be exceeding Jasmine's
default 5 s interval, which would make them flaky rather than broken. Worth confirming against the
same suite on a developer workstation before treating them as real defects.

**Not verified — requires on-network / on-host checks:** whether the same four specs fail off-sandbox;
whether the produced WARs deploy; anything touching AS400/Oracle (integration tests are out of scope
in the sandbox by design).

---

## Suggested follow-up, in priority order

1. Bake a settings.xml declaring the `nexus` repo id into the image (§1, Option A) — or strip
   `_remote.repositories` from the cache (Option B). Without this the sandbox cannot build at all.
2. Fix or explicitly disable the `bwrap` sandbox (§2).
3. Correct the sandbox instructions: they say `~/.m2` is warmed, but the live cache is
   `/workspace/.m2/repository` via `MAVEN_OPTS`, and `~/.m2` does not exist.
4. Gitignore or parameterise the `agencySecurityRealm` Windows output path (§3).
5. Re-run this audit for the other profiles (`memberWWW`, `vendorWWW`, `investment`) if they are
   ever warmed — §1 will affect every one of them identically.

*Audited 2026-07-28 in a disposable sandbox container. Item §1's fix was applied in-session as
`~/.m2/settings.xml` to enable verification; that file lives outside both repos and is discarded
with the container.*
