# Working on the sandbox scaffold

@AGENTS.md

The guidance for this directory lives in `AGENTS.md`, imported above, so that Claude Code and
GitHub Copilot CLI read the same single source. If the import did not resolve, open `AGENTS.md`
and read it before doing anything else.

**One thing that cannot wait for the import:** `overlay/CLAUDE.md` in this directory is a
*payload* that gets deployed into an assembled sandbox — it is not a description of your
environment. You are on the Windows host with full network and filesystem access, not inside a
locked-down container. `AGENTS.md` has the full comparison.
