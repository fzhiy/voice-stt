# SPDX-License-Identifier: MIT
# voice-stt uninstaller — reverses install.ps1
#
# What it removes:
#   - Startup shortcut (%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\voice-hotkey.lnk)
#   - Installed scripts (%LOCALAPPDATA%\voice-stt\*.ps1, *.ahk)
#
# What it DOES NOT remove:
#   - User's .env file (contains personal config — intentionally preserved)
#   - AutoHotkey v2 (shared tool, may be used by other scripts)
#   - Logs and partial.txt under %LOCALAPPDATA%\voice-stt\ (user data)
#
# Usage:
#   .\scripts\uninstall.ps1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$INSTALL_DIR   = "$env:LOCALAPPDATA\voice-stt"
$STARTUP_DIR   = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$SHORTCUT_PATH = "$STARTUP_DIR\voice-hotkey.lnk"

function Step([string]$msg)  { Write-Host "  $msg" -ForegroundColor Cyan }
function Done([string]$msg)  { Write-Host "  [ok] $msg" -ForegroundColor Green }
function Skip([string]$msg)  { Write-Host "  [skip] $msg" -ForegroundColor Gray }

Write-Host ""
Write-Host "voice-stt uninstaller" -ForegroundColor Magenta
Write-Host ""

# ── Kill running instances ────────────────────────────────────────────────────
Step "Stopping any running voice-hotkey.ahk processes ..."
$ahkProcs = Get-Process -Name 'AutoHotkey*' -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -eq '' -or $_.MainWindowTitle -match 'voice' }
if ($ahkProcs) {
    $ahkProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Done "Stopped $($ahkProcs.Count) AHK process(es)"
} else {
    Skip "No running AHK processes found"
}

# ── Remove startup shortcut ───────────────────────────────────────────────────
Step "Removing Startup shortcut ..."
if (Test-Path $SHORTCUT_PATH) {
    Remove-Item $SHORTCUT_PATH -Force
    Done "Removed $SHORTCUT_PATH"
} else {
    Skip "Shortcut not found (already removed?)"
}

# ── Remove installed scripts ──────────────────────────────────────────────────
Step "Removing installed scripts from $INSTALL_DIR ..."
if (Test-Path $INSTALL_DIR) {
    # -Include requires a wildcard in -Path or -Recurse; otherwise it silently
    # returns nothing and the uninstall leaves files behind.
    $scriptFiles = Get-ChildItem -Path (Join-Path $INSTALL_DIR '*') `
        -Include '*.ps1','*.ahk' -File -ErrorAction SilentlyContinue
    if ($scriptFiles) {
        $scriptFiles | Remove-Item -Force
        Done "Removed $($scriptFiles.Count) script file(s)"
    } else {
        Skip "No script files found in $INSTALL_DIR"
    }
} else {
    Skip "$INSTALL_DIR does not exist"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host ""
Write-Host "Preserved (NOT removed):"
Write-Host "  - $INSTALL_DIR\.env  (your configuration)"
Write-Host "  - $INSTALL_DIR\*.log  (your logs)"
Write-Host "  - AutoHotkey v2 (shared; remove via winget/Programs)"
Write-Host ""
Write-Host "To fully clean up: Remove-Item '$INSTALL_DIR' -Recurse"
Write-Host ""
