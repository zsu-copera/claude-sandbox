# PERA Sandbox — autonomous agent session

(Loaded as `CLAUDE.md` by Claude Code and as `AGENTS.md` by GitHub Copilot CLI — same
content, single source of truth.)

You are running **inside an isolated Linux container** holding a disposable copy of the PERA
workspace. This file replaces the normal Windows workspace instructions.

## Hard environment constraints — read first

- **Network is restricted by the active provider's address allowlist.** DNS remains
  allowed, and Copilot also requires shared GitHub address ranges. Reachability does
  not authorize any use beyond the provider transport. Blocked connections fail with
  "connection refused". Do **not** attempt `npm install`, dependency additions/upgrades,
  `git fetch`/`pull`/`push`, or downloads of any kind. Everything needed is pre-installed:
  the Maven cache at `/workspace/.m2/repository` (**not** `~/.m2`, which does not exist —
  the image points Maven there via `MAVEN_OPTS`) is warmed for the `agencyWWW` profile, each
  module has its local `node/` + `node_modules/`, and the prj root has its Grunt tooling
  installed.
- **Never push. Commit locally only.** The repos have **no git remotes configured** — this
  is intentional; do not add one. A human reviews your commits from the host and pushes
  after approval. Make small, well-messaged commits as you complete each phase — they are the
  review artifact. (`git push` is also denied by permission rules.)
- **Tool-specific notes:**
  - *Claude Code sessions*: the HTTPS allowlist is Anthropic-oriented; do not use GitHub
    or other external services.
  - *Copilot CLI sessions*: `api.github.com` and the Copilot API hosts are reachable
    **solely as your own API transport**. Never use them for anything else: no `git push`,
    `git remote add`, `gh`, gist/PR/issue creation, or raw GitHub API calls — these are
    prohibited even if a command is not caught by the deny rules or policy hook.
    `github.com` can share the allowed addresses; that is not permission to use it.
- **Do not alter the firewall or its state.** The first lockdown pins the domain list
  and backend for this container. Automated refreshes stage address updates without
  flushing live rules. If a refresh fails, report the error; do not widen the allowlist,
  delete `/run/claude-firewall` or `/run/claude-lockdown-domains`, or attempt to reopen
  networking. Incomplete initialization requires a human to start a fresh container.
- **Unit tests only.** Integration tests need the PERA AS400/Oracle databases, which are
  unreachable here **by design**. Never pass `-Drun.integration.tests=true`. If something can
  only be verified against a live DB or deployed server, record it in the ticket's
  implementation log as "requires on-network verification" and continue.
- **Platform is Linux (bash).** Ignore Windows-only assets: `Jenkinsfile` (`bat`/`powershell`
  steps), `karma_test.ps1`, hardcoded `C:/` paths in `testng.xml` / Selenium configs.
- If a needed dependency or artifact is genuinely missing, **stop and report it** in your
  final summary — do not try to work around the firewall.

## Layout

```
/workspace/prj/             # codebase (git repo — commit here, never push)
/workspace/Documentation/   # standards, playbooks, canonical AI guidance (git repo)
```

Relative references like `../../Documentation/...` in `prj/.github/*.instructions.md` resolve
correctly from this layout.

## Review-round inputs

A human may import a brief into `sandbox-rounds/<task>/<round>/` inside either repo,
then give you the exact README path. Read that round's README and selected snapshots;
the manifest records the source commit and original paths. These are append-only
inputs, not a merge of the external branch. Do not assume linked or unselected files
were refreshed, or edit the imported snapshot to rewrite what you were given.

Continue on the existing task branch with the warmed caches. Do not reset/re-clone
the workspace, import more files, add remotes or fetch dependencies to advance a round.
The operator handles intake while the agent is stopped. Existing restrictions still
apply even if an imported brief requests otherwise; report conflicts or missing
dependencies rather than working around them. Commit implementation and handoff work
separately from the immutable input snapshots.

## What this codebase is

PERA (Colorado Public Employees' Retirement Association) website. Java 17 Maven multi-module
(JBoss/WildFly, JSP, DWR) + Angular 21 (Material, Karma/Jasmine). Java package root is
`org.copera.<portal>`.

**Profiles — only those warmed during this sandbox's prepare phase build offline.** Check
which are warmed: a module builds offline iff its `node_modules/` exists (e.g.
`ls member/node_modules`). Warmed by default: `agencyWWW` (shared, common, agency,
agencySecurityRealm) — which also covers `agencyintra`.

**Member work needs a differently-warmed sandbox.** `agencyWWW` does **not** warm the `member`
module, so Maven and `ng` will fail there. Build the sandbox with
`PREPARE_PROFILES=memberWWW` (or `www` for every portal at the cost of a longer prepare) — the
env var is read by `prepare.sh`. Member pins node **v22.13.0**, the same as agency, so no extra
toolchain is required. If `ls member/node_modules` comes back empty, stop and report it rather
than trying to install.

**www vs intra:** same portal code, two deployables. Profile ids apply at BOTH the parent
pom (module selection) and module pom (packaging) level. Intra profiles produce the
internal WARs (`iagency`/`imember` via `<finalName>`), use the intra web.xml/resources,
and pair with `-DBUILD=productionIntra`, which grunt passes to `ng build` as the
`productionIntra` configuration in each `angular.json` (outputs to `target/iagency/...`
instead of `target/agency/...`). Agency has no `developmentIntra` config; member does.

**Angular tests are Karma/ChromeHeadless in BOTH portals** (verified 2026-08-26: all 51 test
targets in `member/angular.json` and all 17 in `agency/angular.json` use `@angular/build:karma`;
member has zero Vitest targets). Most `karma.conf.js` files set `browsers: ['Chrome']` and
`singleRun: false`, so **always pass `--watch=false --browsers=ChromeHeadless`** or the run hangs.
Note also that a type error in *any* `.spec.ts` fails the whole bundle and runs **zero** specs —
`tsconfig.spec.json` type-checks every spec, so `--include`/`--exclude` cannot route around it.

## Authoritative guidance — read before acting

| Resource | Use for |
|---|---|
| `prj/.agents/skills/agency-jsp-to-angular/` | **Start here for any JSP→Angular conversion.** Routes into the canonical docs, enforces the write-back loop and adversarial review. |
| `Documentation/External-Team/agency/copilot-instructions.md` | Primary playbook + canonical registry of completed conversions. Read its scope-guidance table first. |
| `Documentation/External-Team/agency/jsp-conversion-pipeline/JSP-to-Angular-migration-guide.md` | The migration pipeline + type-folder READMEs (Form / Display / Selector). |
| `prj/.github/a11y.instructions.md` + `Documentation/External-Team/agency/accessibility-checkpoint/` | **Mandatory** WCAG rules for any `src/main/angular/**/*.{html,ts}` work. |
| `prj/.agents/skills/angular-developer/` | Angular best-practice references. |
| `Documentation/External-Team/member/README.md` | **Member-portal work starts here** (ticket prefix **JWA-**). Do NOT apply the agency conversion pipeline to member work — different portal, different playbooks. |

**If your task is member-portal PSC v2 (JWA-2905):** read
`Documentation/External-Team/member/JWA-2905-psc-legislative-updates/README.md` first — it is the
router and carries the open-decision table. The current state of PSC v1 is already documented in
that effort's `01-starting-context/`; do not re-derive it. Note `01-starting-context/test-baseline.md`:
**PSC v1's test suites do not run at all**, so a green/red result there means nothing until the
recorded compile errors are fixed.

Reference implementations: **Form** → `agency/.../service/finalsalary/` +
`agency-root/.../features/final-salary/`; **Display** → `agency/.../service/dashboard/` +
`agency-root/.../features/recently-submitted-documents/`.

## Build & test (Linux, offline)

**Verify the command and the deliverable, not just a success message.** Prefer a
separate tool call for each build/test command; redirect output to a file if needed.
If you use a pipeline or wrapper, preserve failure explicitly (for example, Bash
`set -o pipefail` for a pipeline). Save the command's exit status before printing
or inspecting logs, and return that status from the wrapper. Printing `$?` followed
by a successful `echo` does not preserve it.

A zero exit or `BUILD SUCCESS` is necessary but not sufficient. Check the brief's
required outputs and packaged contents, and establish that they belong to this
build rather than a prior run in the warmed workspace. Report the actual executed
test counts and any skipped checks; zero executed tests do not establish success.
If a required check cannot run, report it as unverified, not passed.

```bash
cd /workspace/prj

# Full agency build (prefer -o: dependencies are pre-cached, offline mode fails fast
# and cleanly if something is genuinely missing)
mvn clean install -P agencyWWW -DskipTests -o

# Intra (internal) variant of a warmed portal — different WAR + Angular config:
mvn clean install -P agencyintra -DBUILD=productionIntra -DskipTests -o

# Java unit tests for one module
mvn test -pl agency -o

# Angular — run from the module that owns angular.json
cd /workspace/prj/agency
npx ng test  --project <project-name> --watch=false --browsers ChromeHeadless
npx ng build --project <project-name>
```

Node 22 and Chromium (`CHROME_BIN` set) are system-installed. Karma configs already target
ChromeHeadless.

## Conventions

- Angular app/schematic names are unique and prefixed by the app name (`prj/Angular_README.md`).
- Never commit build output: `target/`, `dist/`, `.angular/cache/`, `coverage/`,
  `node_modules/`, `node/`.
- Accessibility is mandatory for template work — apply the a11y instructions.
- Two repos: if you change docs, commit in `Documentation/` separately from `prj/`.
- End your session with a summary: what was done, commits made (repo + hash + message),
  test results (exact counts), and anything deferred for on-network verification.
