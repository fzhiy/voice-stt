# SPDX-License-Identifier: MIT
# launch.ps1 — voice-stt launcher (canonical, used by installer AND portable ZIP)
#
# What it does:
#   1. Loads .env into process environment variables so the AHK child
#      inherits them (ASR_WS_URL, RECORD_DEVICE_NAME, etc.).
#      Looks for .env at the extraction root in portable mode (detected via
#      a start.bat sibling at the parent), or in the script directory in
#      installed mode (%LOCALAPPDATA%\voice-stt\).
#   2. Verifies AutoHotkey v2 is installed.
#   3. Starts voice-hotkey.ahk under AutoHotkey64.exe.
#
# Used by:
#   - install.ps1's Startup shortcut (installed mode)
#   - start.bat in the voice-stt.zip release bundle (portable mode)

Set-StrictMode -Version Latest
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Resolve config dir (.env / .env.example location) ─────────────────────────
# Portable layout: launch.ps1 lives at <root>/windows/ next to a start.bat
# sentinel one level up. .env lives at the extraction root so users see it
# beside README.md.
# Installed layout: install.ps1 copies launch.ps1 + .env into the same
# %LOCALAPPDATA%\voice-stt\ dir, so $ScriptDir is the config dir.
$portableRoot = Split-Path -Parent $ScriptDir
if (Test-Path (Join-Path $portableRoot 'start.bat')) {
    $ConfigDir = $portableRoot
} else {
    $ConfigDir = $ScriptDir
}

$envFile = Join-Path $ConfigDir '.env'
if (-not (Test-Path $envFile)) {
    $envExample = Join-Path $ConfigDir '.env.example'
    if (Test-Path $envExample) {
        Copy-Item $envExample $envFile
        Write-Host "Created .env from .env.example. Edit it before continuing." -ForegroundColor Yellow
        Write-Host "  File: $envFile" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Required: ASR_WS_URL=ws://<your-server>:8082/" -ForegroundColor Yellow
        Write-Host "Required: RECORD_DEVICE_NAME=<your mic device>" -ForegroundColor Yellow
        Write-Host ""
        if ($Host.Name -eq 'ConsoleHost') { Read-Host "Press Enter after editing .env to continue" }
    } else {
        Write-Error ".env not found at $envFile. Copy .env.example to .env and configure it before launching."
        exit 1
    }
}

# Parse .env, set process environment variables for the AHK child to inherit.
# Lines: KEY=VALUE; comments start with #; empty lines ignored; values trimmed.
Get-Content $envFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -and $line -notmatch '^\s*#' -and $line -match '^([^=]+)=(.*)$') {
        $name  = $Matches[1].Trim()
        $value = $Matches[2].Trim()
        [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

# ── Locate AutoHotkey v2 ──────────────────────────────────────────────────────
$ahkExe = "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe"
if (-not (Test-Path $ahkExe)) {
    Write-Error @"
AutoHotkey v2 not found at $ahkExe.

Options:
  - Installed mode: re-run install.ps1 to download AHK v2 automatically.
  - Portable mode:  install AHK v2 manually from https://www.autohotkey.com
                    (download "AutoHotkey_2.0.x.zip" and extract to
                    $env:LOCALAPPDATA\Programs\AutoHotkey\v2\)
"@
    exit 1
}

# ── Launch voice-hotkey.ahk ───────────────────────────────────────────────────
$ahkScript = Join-Path $ScriptDir 'voice-hotkey.ahk'
if (-not (Test-Path $ahkScript)) {
    Write-Error "voice-hotkey.ahk not found at $ahkScript"
    exit 1
}

Write-Host "Starting voice-stt..." -ForegroundColor Green
Start-Process -FilePath $ahkExe -ArgumentList "`"$ahkScript`"" -WorkingDirectory $ScriptDir
