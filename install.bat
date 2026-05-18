@echo off
REM SPDX-License-Identifier: MIT
REM install.bat — double-clickable wrapper for install.ps1.
REM Windows does NOT execute .ps1 on double-click; this .bat bridges that.
REM Forwards any arguments (e.g., -DryRun) verbatim.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
