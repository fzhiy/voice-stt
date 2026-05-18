# SAPI TTS 朗读脚本
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File sapi-tts.ps1 -TextFile <path>
# TextFile：UTF-8 文本文件，由 AHK 写入，内容为要朗读的文字
# 输出：SAPI 默认语音朗读（英文/中文跟随 Windows 语音设置）

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TextFile
)

if (-not (Test-Path $TextFile)) {
    Write-Error "文本文件不存在: $TextFile"
    exit 1
}

Add-Type -AssemblyName System.Speech
$syn = New-Object System.Speech.Synthesis.SpeechSynthesizer
$text = Get-Content -Path $TextFile -Encoding UTF8 -Raw
$syn.Speak($text)
