<#
.SYNOPSIS
  Assembles the disposable Claude Code sandbox workspace (default: C:\work\pera-sandbox).

.DESCRIPTION
  - Clones prj + Documentation from the LOCAL working copies (committed state of the
    currently checked-out branch; no SSH keys required) with LF line endings.
  - Overlays the git-ignored AI assets (.github, .agents) from the live working copy.
  - Drops in the sandbox CLAUDE.md, .claude\settings.json, and the container definition.
  - Stages %USERPROFILE%\.m2\settings.xml under .secrets\ for the prepare phase
    (run-agent deletes it before the autonomous session starts).

.EXAMPLE
  .\New-Sandbox.ps1
  .\New-Sandbox.ps1 -Force          # rebuild from scratch (recommended per task)
#>
param(
    [string]$SourceRoot  = "C:\work\pera",
    [string]$SandboxRoot = "C:\work\pera-sandbox",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$scaffold = Split-Path -Parent $MyInvocation.MyCommand.Path

function Assert-LastExit([string]$what) {
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}

# --- Preflight -------------------------------------------------------------
foreach ($p in @("$SourceRoot\prj\.git", "$SourceRoot\Documentation\.git")) {
    if (-not (Test-Path $p)) { throw "Expected git repo not found: $p" }
}
$m2Settings = Join-Path $env:USERPROFILE ".m2\settings.xml"
if (-not (Test-Path $m2Settings)) { throw "Missing $m2Settings (Nexus mirror + creds needed for prepare phase)" }
$npmrc = Join-Path $env:USERPROFILE ".npmrc"
if (-not (Test-Path $npmrc)) { throw "Missing $npmrc (Nexus npm registry + auth needed for prepare phase)" }

# Warn (don't fail) if the developer-local AI assets are absent on this machine.
$overlayGithub = Test-Path "$SourceRoot\prj\.github"
$overlayAgents = Test-Path "$SourceRoot\prj\.agents"
if (-not $overlayGithub) { Write-Warning "prj\.github not found - instruction files will be missing in the sandbox" }
if (-not $overlayAgents) { Write-Warning "prj\.agents not found - conversion skills will be missing in the sandbox" }

if (Test-Path $SandboxRoot) {
    if ($Force) {
        Write-Host "Removing existing sandbox at $SandboxRoot ..."
        Remove-Item -Recurse -Force $SandboxRoot -Confirm:$false
    } else {
        throw "$SandboxRoot already exists. Use -Force to rebuild (any un-reviewed agent commits there will be lost)."
    }
}
New-Item -ItemType Directory -Force $SandboxRoot | Out-Null

# --- 1. Clone both repos from local working copies (LF endings for the Linux container) ---
Write-Host "Cloning prj (committed state of current branch) ..."
git clone --no-hardlinks --single-branch -c core.autocrlf=false -c core.eol=lf "$SourceRoot\prj" "$SandboxRoot\prj"
Assert-LastExit "git clone prj"

Write-Host "Cloning Documentation ..."
git clone --no-hardlinks --single-branch -c core.autocrlf=false -c core.eol=lf "$SourceRoot\Documentation" "$SandboxRoot\Documentation"
Assert-LastExit "git clone Documentation"

# Note: uncommitted changes in your working copies are intentionally NOT carried over.

# Strip remotes: the agent must not have a push/fetch target; harvest fetches FROM the
# real repo pointing AT the sandbox, so the sandbox needs no remotes at all.
git -C "$SandboxRoot\prj" remote remove origin
git -C "$SandboxRoot\Documentation" remote remove origin

# --- 2. Overlay the git-ignored AI assets ----------------------------------
if ($overlayGithub) {
    Write-Host "Overlaying prj\.github (instructions) ..."
    Copy-Item -Recurse -Force "$SourceRoot\prj\.github" "$SandboxRoot\prj\.github"
}
if ($overlayAgents) {
    Write-Host "Overlaying prj\.agents (skills) ..."
    Copy-Item -Recurse -Force "$SourceRoot\prj\.agents" "$SandboxRoot\prj\.agents"
}

# --- 3. Sandbox CLAUDE.md + Claude settings --------------------------------
Copy-Item "$scaffold\overlay\CLAUDE.md" "$SandboxRoot\CLAUDE.md"
Copy-Item "$scaffold\overlay\CLAUDE.md" "$SandboxRoot\AGENTS.md"   # Copilot CLI reads AGENTS.md
Copy-Item -Recurse "$scaffold\overlay\.claude" "$SandboxRoot\.claude"

# --- 4. Container definition ------------------------------------------------
Copy-Item -Recurse "$scaffold\.devcontainer" "$SandboxRoot\.devcontainer"
Copy-Item -Recurse "$scaffold\container" "$SandboxRoot\container"
# Keep the repos/secrets out of the docker build context (context root = sandbox root)
Copy-Item "$scaffold\dockerignore" "$SandboxRoot\.dockerignore"

# --- 5. Nexus credentials for the prepare phase only ------------------------
New-Item -ItemType Directory -Force "$SandboxRoot\.secrets" | Out-Null
Copy-Item $m2Settings "$SandboxRoot\.secrets\settings.xml"
Copy-Item $npmrc "$SandboxRoot\.secrets\npmrc"

Write-Host ""
Write-Host "Sandbox ready at $SandboxRoot" -ForegroundColor Green
Write-Host @"

Next steps:
  1. Open $SandboxRoot in VS Code -> 'Reopen in Container'
  2. In the container terminal:   prepare-sandbox     (network open, one-time build)
  3. Then:                        run-agent           (locks firewall, starts Claude)
  4. Review from Windows:         git -C $SandboxRoot\prj log --oneline
"@
