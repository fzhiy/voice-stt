# SPDX-License-Identifier: MIT
# scripts/build-portable.ps1 — build voice-stt.zip (release bundle, dual mode)
#
# Usage:
#   .\scripts\build-portable.ps1 -OutDir ./dist
#
# Output: <OutDir>/voice-stt.zip
#   voice-stt/
#     install.bat           <- double-click for installed mode (wraps install.ps1)
#     start.bat             <- double-click for portable mode (wraps windows\launch.ps1)
#     install.ps1           <- installer (CLI alternative)
#     README.md, LICENSE, CHANGELOG.md, SECURITY.md, CONTRIBUTING.md
#     .env.example          <- copy; user renames to .env
#     scripts/
#       uninstall.ps1
#     windows/
#       launch.ps1          <- portable entry point (also copied to LOCALAPPDATA on install)
#       voice-hotkey.ahk
#       voice-ptt-stream-ws.ps1
#       voice-mic-daemon.ps1
#       voice-ptt.ps1
#       record.ps1
#       sapi-tts.ps1
#       voice-preview-renderer-fallback.ahk
#       voice-input.ps1
#       voice-mic-daemon-client.ps1
#     docs/
#       QUICKSTART.md, CONFIG.md, ARCHITECTURE.md, TROUBLESHOOTING.md
#
# Layout serves BOTH installation modes from one bundle:
#   - Installed (auto-start on login): double-click install.bat OR run install.ps1
#     in PowerShell. install.ps1 finds windows/ as sibling and copies to LOCALAPPDATA.
#   - Portable (no install): double-click start.bat OR run windows/launch.ps1.
#     launch.ps1 loads .env from same dir and launches voice-hotkey.ahk.
#
# NOTE: The portable bundle DOES write outside the zip extraction root:
#   %LOCALAPPDATA%\voice-stt\partial.txt  (preview state file — required for caption renderer)
#   %LOCALAPPDATA%\voice-stt\*.log        (diagnostic logs)
# Document this for users who assume "portable = zero writes outside zip".

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$OutDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$REPO_ROOT  = Split-Path -Parent $PSScriptRoot
$WIN_SRC    = Join-Path $REPO_ROOT 'windows'
$DOCS_SRC   = Join-Path $REPO_ROOT 'docs'
$ZIP_NAME   = 'voice-stt.zip'
$INNER_DIR  = 'voice-stt'

# Doc files copied verbatim from docs/ into the bundle's docs/ subdir.
# v0.1: SETUP-WSL.md + SETUP-SERVER.md (PWA/iPhone artifacts) removed;
# server-side setup lives in server/README.md instead.
$DOC_FILES = @(
    'QUICKSTART.md', 'CONFIG.md',
    'ARCHITECTURE.md', 'TROUBLESHOOTING.md'
)
# Top-level files copied verbatim into bundle root.
$ROOT_FILES = @(
    'install.ps1', 'install.bat', 'start.bat',
    'README.md', 'LICENSE', 'CHANGELOG.md',
    'SECURITY.md', 'CONTRIBUTING.md', '.env.example'
)

function Step([string]$msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Done([string]$msg) { Write-Host "  [ok] $msg" -ForegroundColor Green }

Write-Host ""
Write-Host "voice-stt build-portable" -ForegroundColor Magenta
Write-Host ""

# ── Validate source ───────────────────────────────────────────────────────────
if (-not (Test-Path $WIN_SRC)) {
    Write-Error "windows\ directory not found at $WIN_SRC. Run from repo root."
    exit 1
}

# ── Prepare output dir ────────────────────────────────────────────────────────
if (-not (Test-Path $OutDir)) {
    Step "Creating output directory: $OutDir"
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$zipPath = Join-Path $OutDir $ZIP_NAME
$stagingRoot = Join-Path $env:TEMP "voice-stt-build-$PID"
$stagingInner = Join-Path $stagingRoot $INNER_DIR

# ── Stage files ───────────────────────────────────────────────────────────────
Step "Staging files to $stagingInner ..."
New-Item -ItemType Directory -Path $stagingInner -Force | Out-Null

# Copy windows/ subdir (all runtime scripts, including launch.ps1)
$winStaging = Join-Path $stagingInner 'windows'
New-Item -ItemType Directory -Path $winStaging -Force | Out-Null
Get-ChildItem -Path $WIN_SRC | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $winStaging -Force
}

# Copy docs/ subdir (selected user-facing files only — skip docs/dev/)
$docsStaging = Join-Path $stagingInner 'docs'
New-Item -ItemType Directory -Path $docsStaging -Force | Out-Null
foreach ($docName in $DOC_FILES) {
    $src = Join-Path $DOCS_SRC $docName
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $docsStaging -Force
    }
}

# Copy scripts/uninstall.ps1
$scriptsStaging = Join-Path $stagingInner 'scripts'
New-Item -ItemType Directory -Path $scriptsStaging -Force | Out-Null
$uninstallSrc = Join-Path $REPO_ROOT 'scripts\uninstall.ps1'
if (Test-Path $uninstallSrc) {
    Copy-Item -Path $uninstallSrc -Destination $scriptsStaging -Force
}

# Copy top-level files (install.ps1, install.bat, start.bat, README.md, etc.)
foreach ($rootName in $ROOT_FILES) {
    $src = Join-Path $REPO_ROOT $rootName
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $stagingInner -Force
    }
}

# Sanity: install.ps1 + install.bat + start.bat + windows/launch.ps1 + windows/voice-hotkey.ahk
# all must be present in staging (verification block below repeats these as
# guards on the produced zip, but fail-fast is friendlier).
$mustExist = @(
    'install.ps1', 'install.bat', 'start.bat',
    'README.md', 'LICENSE',
    'windows\launch.ps1', 'windows\voice-hotkey.ahk',
    '.env.example'
)
foreach ($f in $mustExist) {
    $check = Join-Path $stagingInner $f
    if (-not (Test-Path $check)) {
        Write-Error "Staging incomplete — missing $check"
        exit 1
    }
}
Done "Staged: root files + windows/ + docs/ + scripts/"

# ── Build ZIP ─────────────────────────────────────────────────────────────────
if (Test-Path $zipPath) {
    Step "Removing existing $ZIP_NAME ..."
    Remove-Item $zipPath -Force
}

Step "Compressing to $zipPath ..."
# Pass `$stagingInner\*` (contents glob) NOT `$stagingInner` (folder itself).
# When user runs Windows "Extract All" on voice-stt.zip it auto-creates a
# folder named after the zip; we want the zip contents flat so the user gets
# `<Desktop>\voice-stt\install.bat`, not `<Desktop>\voice-stt\voice-stt\install.bat`.
Compress-Archive -Path "$stagingInner\*" -DestinationPath $zipPath -CompressionLevel Optimal

# ── Cleanup staging ───────────────────────────────────────────────────────────
Remove-Item $stagingRoot -Recurse -Force

# ── Verify ZIP ───────────────────────────────────────────────────────────────
$zipItem = Get-Item $zipPath
$zipSizeMB = [math]::Round($zipItem.Length / 1MB, 2)
$sha256 = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash

Write-Host ""
Done "Built: $zipPath"
Write-Host "  Size  : ${zipSizeMB} MB"
Write-Host "  SHA256: $sha256"

if ($zipSizeMB -gt 50) {
    Write-Error "ZIP exceeds 50MB (${zipSizeMB} MB). Check for accidental model/recording inclusion."
    exit 2
}

# ── Quick content check ───────────────────────────────────────────────────────
Step "Verifying zip contents ..."
$tmpExtract = Join-Path $env:TEMP "voice-stt-verify-$PID"
Expand-Archive -Path $zipPath -DestinationPath $tmpExtract -Force

# Zip is now flat (no inner voice-stt/ dir); files are at $tmpExtract root.
# Both entry points present (installed mode requires install.ps1 + windows\;
# portable mode requires windows\launch.ps1).
$verifyPaths = @(
    'install.ps1', 'install.bat', 'start.bat',
    'README.md', 'LICENSE',
    'windows\launch.ps1', 'windows\voice-hotkey.ahk',
    '.env.example'
)
foreach ($p in $verifyPaths) {
    $full = Join-Path $tmpExtract $p
    if (-not (Test-Path $full)) {
        Remove-Item $tmpExtract -Recurse -Force
        Write-Error "VERIFY FAILED: $p not found in extracted zip"
        exit 3
    }
}

# Check no absolute paths in extracted text files
$absPathPattern = 'C:\\Users\\[A-Za-z0-9_]+|/home/[a-z]+/'
$badFiles = Get-ChildItem -Path $tmpExtract -Include '*.ps1','*.ahk','*.example' -Recurse |
    Select-String -Pattern $absPathPattern -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Path -Unique
if ($badFiles) {
    Remove-Item $tmpExtract -Recurse -Force
    Write-Error "VERIFY FAILED: absolute paths found in: $($badFiles -join ', ')"
    exit 4
}

Remove-Item $tmpExtract -Recurse -Force
Done "Zip verified: entry points present, no absolute paths, size OK"

Write-Host ""
Write-Host "Release ZIP ready: $zipPath" -ForegroundColor Green
Write-Host "SHA256: $sha256" -ForegroundColor Green
Write-Host ""
Write-Host "End-user flow:" -ForegroundColor Gray
Write-Host "  Installed:  extract zip -> double-click install.bat" -ForegroundColor Gray
Write-Host "  Portable:   extract zip -> double-click start.bat" -ForegroundColor Gray
Write-Host ""
