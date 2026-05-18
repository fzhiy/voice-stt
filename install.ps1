# SPDX-License-Identifier: MIT
# voice-stt installer — iwr-able, idempotent, Windows 10+ (PowerShell 5.1+)
#
# Usage:
#   iwr https://raw.githubusercontent.com/fzhiy/voice-stt/main/install.ps1 | iex
#   .\install.ps1              # install
#   .\install.ps1 -DryRun      # list planned actions without executing
#
# What it does:
#   1. Installs AutoHotkey v2 (direct download from autohotkey.com, pinned version)
#   2. Copies windows\ scripts to %LOCALAPPDATA%\voice-stt\
#   3. Seeds .env from .env.example if .env is missing
#   4. Creates Startup shortcut so voice-hotkey.ahk launches at login

[CmdletBinding()]
param(
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Configuration ─────────────────────────────────────────────────────────────
$AHK_VERSION   = '2.0.19'
# Versioned ZIP URL pattern documented by AutoHotkey project (also referenced
# by Chocolatey's autohotkey.portable package verification metadata).
$AHK_URL       = "https://www.autohotkey.com/download/2.0/AutoHotkey_${AHK_VERSION}.zip"
$INSTALL_DIR   = "$env:LOCALAPPDATA\voice-stt"
$AHK_INSTALL   = "$env:LOCALAPPDATA\Programs\AutoHotkey\v2"
$AHK_EXE       = "$AHK_INSTALL\AutoHotkey64.exe"
$STARTUP_DIR   = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$SHORTCUT_PATH = "$STARTUP_DIR\voice-hotkey.lnk"
$HOTKEY_AHK    = "$INSTALL_DIR\voice-hotkey.ahk"
$LAUNCH_PS1    = "$INSTALL_DIR\launch.ps1"
$WIN_PS_EXE    = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

# ── Helpers ───────────────────────────────────────────────────────────────────
function Step([string]$msg) {
    Write-Host "  $msg" -ForegroundColor Cyan
}

function DryStep([string]$msg) {
    Write-Host "  [DRY-RUN] $msg" -ForegroundColor Yellow
}

function Done([string]$msg) {
    Write-Host "  [ok] $msg" -ForegroundColor Green
}

# ── Dry-run: list all planned actions then exit ───────────────────────────────
if ($DryRun) {
    Write-Host ""
    Write-Host "voice-stt install.ps1 -- DRY RUN (no changes will be made)" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "Planned actions:"

    if (-not (Test-Path $AHK_EXE)) {
        DryStep "Download AHK v$AHK_VERSION from autohotkey.com and extract to $AHK_INSTALL"
    } else {
        DryStep "AHK already at $AHK_EXE -- SKIP"
    }

    DryStep "Create install directory: $INSTALL_DIR"

    # Determine source dir
    $srcDir = $PSScriptRoot
    if (-not $srcDir) { $srcDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $windowsSrc = Join-Path $srcDir 'windows'
    if (Test-Path $windowsSrc) {
        DryStep "Copy scripts from $windowsSrc to $INSTALL_DIR"
    } else {
        DryStep "windows\ dir not found at $windowsSrc -- will skip file copy (run from repo root)"
    }

    $envDst = Join-Path $INSTALL_DIR '.env'
    $envSrc = Join-Path $srcDir '.env.example'
    if (-not (Test-Path $envDst)) {
        DryStep "Seed $envDst from $envSrc"
    } else {
        DryStep "$envDst already exists -- SKIP (user config preserved)"
    }

    if (-not (Test-Path $SHORTCUT_PATH)) {
        DryStep "Create Startup shortcut: $SHORTCUT_PATH -> powershell.exe -File $LAUNCH_PS1"
    } else {
        DryStep "Startup shortcut already exists -- SKIP"
    }

    Write-Host ""
    Write-Host "Re-run without -DryRun to apply." -ForegroundColor Magenta
    Write-Host ""
    exit 0
}

# ── Step 1: Install AutoHotkey v2 ────────────────────────────────────────────
Write-Host ""
Write-Host "voice-stt installer" -ForegroundColor Magenta
Write-Host ""

if (Test-Path $AHK_EXE) {
    Done "AutoHotkey v2 already installed at $AHK_EXE"
} else {
    Step "Downloading AutoHotkey v$AHK_VERSION from autohotkey.com ..."
    Write-Host ""
    Write-Host "  NOTE: Windows SmartScreen may warn about the downloaded installer." -ForegroundColor Yellow
    Write-Host "  This is normal for unsigned downloads. Click 'More info' -> 'Run anyway'." -ForegroundColor Yellow
    Write-Host "  AHK v2 is open-source at https://github.com/AutoHotkey/AutoHotkey" -ForegroundColor Yellow
    Write-Host ""

    $tmpZip = "$env:TEMP\ahk-v$AHK_VERSION.zip"
    $tmpDir = "$env:TEMP\ahk-extract-$PID"
    try {
        Invoke-WebRequest -Uri $AHK_URL -OutFile $tmpZip -UseBasicParsing
        Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
        if (-not (Test-Path $AHK_INSTALL)) {
            New-Item -ItemType Directory -Path $AHK_INSTALL -Force | Out-Null
        }
        # AHK zip contains AutoHotkey64.exe at archive root (alongside v1 + UX64).
        # Copy the CONTENTS of the parent directory (not the directory itself)
        # so that AutoHotkey64.exe lands at $AHK_INSTALL\AutoHotkey64.exe.
        $exeSrc = Get-ChildItem -Path $tmpDir -Filter 'AutoHotkey64.exe' -Recurse | Select-Object -First 1
        if (-not $exeSrc) {
            throw "AutoHotkey64.exe not found in downloaded archive. Contents: $(Get-ChildItem $tmpDir -Recurse | Select-Object -ExpandProperty Name | Out-String)"
        }
        $exeSrcParent = Split-Path $exeSrc.FullName -Parent
        Copy-Item -Path (Join-Path $exeSrcParent '*') -Destination $AHK_INSTALL -Recurse -Force
        if (-not (Test-Path $AHK_EXE)) {
            throw "Install verification failed: $AHK_EXE not present after copy. Extract source was: $exeSrcParent"
        }
        Done "AutoHotkey v$AHK_VERSION installed to $AHK_INSTALL"
    } finally {
        Remove-Item $tmpZip -ErrorAction SilentlyContinue
        Remove-Item $tmpDir -Recurse -ErrorAction SilentlyContinue
    }
}

# ── Step 2: Install scripts ───────────────────────────────────────────────────
Step "Creating install directory: $INSTALL_DIR"
if (-not (Test-Path $INSTALL_DIR)) {
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
}
Done "Directory ready"

$srcDir = $PSScriptRoot
if (-not $srcDir) { $srcDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$windowsSrc = Join-Path $srcDir 'windows'

if (Test-Path $windowsSrc) {
    Step "Copying scripts from $windowsSrc ..."
    Get-ChildItem -Path $windowsSrc | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $INSTALL_DIR -Force
    }
    Done "Scripts installed"
} else {
    Write-Warning "windows\ directory not found at $windowsSrc. Skipping script copy."
    Write-Warning "Run install.ps1 from the repo root directory."
}

# ── Step 3: Seed .env ────────────────────────────────────────────────────────
$envDst = Join-Path $INSTALL_DIR '.env'
$envSrc = Join-Path $srcDir '.env.example'
if (Test-Path $envDst) {
    Done ".env already exists — user config preserved (not overwritten)"
} elseif (Test-Path $envSrc) {
    Step "Seeding .env from .env.example ..."
    Copy-Item -Path $envSrc -Destination $envDst
    Done ".env created at $envDst"
    Write-Host ""
    Write-Host "  IMPORTANT: Edit $envDst and set ASR_WS_URL" -ForegroundColor Yellow
    Write-Host "  See docs/CONFIG.md for all options." -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Warning ".env.example not found at $envSrc. Create .env manually before running."
}

# ── Step 4: Startup shortcut ─────────────────────────────────────────────────
# Shortcut targets launch.ps1 (not AHK directly) so .env gets loaded into
# process env vars before AHK starts. -WindowStyle Hidden avoids a PS console
# flashing on each login.
if (Test-Path $SHORTCUT_PATH) {
    Done "Startup shortcut already exists"
} elseif (Test-Path $LAUNCH_PS1) {
    Step "Creating Startup shortcut ..."
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($SHORTCUT_PATH)
    $lnk.TargetPath      = $WIN_PS_EXE
    $lnk.Arguments       = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LAUNCH_PS1`""
    $lnk.WorkingDirectory = $INSTALL_DIR
    $lnk.Description     = 'voice-stt — AI-powered PTT voice input'
    $lnk.Save()
    Done "Startup shortcut created: $SHORTCUT_PATH"
} else {
    Write-Warning "launch.ps1 not found at $LAUNCH_PS1. Startup shortcut not created."
    Write-Warning "Re-run install.ps1 after the script copy completes."
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Installation complete." -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Edit $envDst"
Write-Host "     Set ASR_WS_URL=ws://<your-server>:8082/"
Write-Host "     Set RECORD_DEVICE_NAME=<your mic device>"
Write-Host "     (discover device names: record.ps1 -Diagnose)"
Write-Host "  2. Run `"$LAUNCH_PS1`"  (or reboot for autostart via Startup shortcut)"
Write-Host "  3. Press and hold Shift+Alt+S to dictate. Release to paste."
Write-Host ""
Write-Host "Docs: docs/QUICKSTART.md | docs/CONFIG.md"
Write-Host ""
