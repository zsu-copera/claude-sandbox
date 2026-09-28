# Claude setup backlog

Recorded 2026-09-27, after the Phase 3 deployment and a survey of the workspace's Claude
configuration. The owner deferred all of these for later. Sandbox security items stay in
[SECURITY-REVIEW.md](SECURITY-REVIEW.md#open-items-as-of-2026-09-27); this file lists the rest
and points there for the sandbox. Line numbers are as of this date.

## Workspace and playbook configuration

These live outside this repository: in the workspace root, in `prj` and in `Documentation`.
Each needs a change in its own repository, on the right branch.

| # | Issue | Where | Suggested fix |
|---|---|---|---|
| B1 | **The adversarial-review model is hardcoded as `claude-opus-4-8`.** The EEP-24 implementation log (line 808) records that it was unavailable and Opus ran instead. | `C:\work\pera\CLAUDE.md:312`; `prj/.agents/skills/agency-jsp-to-angular/SKILL.md:55`; `Documentation/External-Team/agency/copilot-instructions.md:245, 247, 306` | Name the role, not a version: "the strongest available Opus model", with today's ID as an example. Regenerate `prj/.github/copilot-instructions.md` with `deploy-copilot-instructions.ps1`, never by hand. Until then, a review dispatch must use a model that exists. |
| B2 | **Fleet Mode orchestration is still in the shared playbook.** Line 237 says it moves to the Claude Code entry point "when the conversion skill lands"; the skill has landed. It also contradicts `jsp-conversion-pipeline/USERS-GUIDE.md:24`, which keeps tool-specific orchestration out of the shared knowledge base. | `copilot-instructions.md:235-309` | Move the section into the `agency-jsp-to-angular` skill, leaving a pointer. |
| B3 | **The conversion skill exists only on this machine.** `prj/.agents/skills` is git-ignored (`prj/.gitignore:112`), and `skills-lock.json` pins only `angular-developer`. A second copy of `angular-developer` at user level is unpinned. | `prj/.agents/skills/`, `prj/skills-lock.json` | Decide where the skill is versioned, before a second developer needs it. |
| B4 | **The `xray-test-doc` skill was never installed.** Its README says to copy it into `prj\.claude\skills\xray-test-doc`; that folder exists but is empty. | `Documentation/External-Team/ai-resources/.github/copilot/skills/xray-test-doc/` | Copy it, or remove the empty folder. |
| B5 | **The AI enablement docs predate the Claude setup.** They are Copilot-centric, list Sonnet 4.6 and Opus 4.5/4.6, have no Claude configuration standard, and contain no roadmap. Last changed 2026-06-05. | `Documentation/AI-ProCode-Enablement/` (02, 03, 13, 17) | Refresh only if other developers are expected to follow them. |

## Sandbox follow-ups

Details are in SECURITY-REVIEW's open items and in VERIFY-ASSERTIONS.

| # | Item | Status |
|---|---|---|
| S-1 | **Execution evidence for Claude Code sessions.** OPERATOR's capture gate has been demonstrated for Copilot only. | To be established with the EEP-24 follow-up |
| S-2 | **A live ticket round with Claude Code** under the context-aware workflow. Every live round so far ran on Copilot, including JWA-2906, whose Karma run therefore never met Claude's sandbox (spec §15). | To be exercised with the EEP-24 follow-up |
| S-3 | **Reproducible image inputs** (D2/D3). Each rebuild installs the current Claude Code and Copilot releases. | Open |
| S-4 | **G1 hardening.** Have the wrapper repeat the startup checks at the next rebuild. Mount `.claude/` read-only only if an in-session write route appears. | At the next rebuild |
| S-5 | **Small checks on the current image:** an interactive Copilot session, Copilot `/model` on a fresh volume, `/status` on Claude Code 2.1.283. | Open, minutes each |
| S-6 | **Leftovers from the 2026-09-22 operator findings.** Superseded canonical copies are guarded only by a warning, there is no pruning or crash-safe hashing, and live coverage has the gaps listed in VERIFY-ASSERTIONS. | Mostly relevant at volume |
| S-7 | **Runtime checks and CI** (V1/N2, CI deferred), **transcript retention and export** (V3), **a harvest helper** (V4, partly `sandbox-task.sh collect`). | Longer term |
| S-8 | **Security/IT sign-off for autonomous runs** (C5). A request packet is drafted. | Deferred by the owner |
| S-9 | **Owner actions:** delete the retired `Documentation` branch `claude-sandbox`; protect or move this repository before wider distribution; licensing, retention and credential governance evidence (I5). | Open |
