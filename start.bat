@echo off
REM SPDX-License-Identifier: MIT
REM start.bat — double-clickable wrapper for portable mode (no install).
REM Runs windows\launch.ps1 which loads .env then launches voice-hotkey.ahk.
REM Requires AutoHotkey v2 to be already installed; see README "Portable".

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\launch.ps1"
