# 录音 → 上传到 Whisper Gateway → 输出转写文本
# 用法：
#   .\voice-input.ps1                              # 默认 10 秒
#   .\voice-input.ps1 -Duration 15
#   .\voice-input.ps1 -Interactive                 # 回车开始/停止
#   .\voice-input.ps1 -GatewayUrl http://gpu:8080  # 覆盖 URL
#
# 输出：转写文本写入剪贴板 + 打印到 stdout

[CmdletBinding()]
param(
    [int]$Duration = 10,
    [switch]$Interactive,
    [string]$GatewayUrl = $env:GATEWAY_URL,
    [string]$Language = $env:WHISPER_LANG,
    [string]$Model = $env:WHISPER_MODEL,
    [switch]$NoClipboard,
    [switch]$KeepWav,
    # 录音引擎：默认走 waveInOpen（MCI 老 API 跟 Win11 + 现代音频驱动协商不稳）
    [switch]$UseMci,
    [int]$DeviceId = -1,    # -1 = WAVE_MAPPER（系统默认）
    [string]$DeviceName = "",
    [int]$Rate = 16000,
    [int]$Channels = 1,
    [int]$Bits = 16,
    [double]$WarmupSec = 0,
    # 强制路径选择：默认 auto = 有 ffmpeg 走 ffmpeg，否则 waveIn
    [switch]$UseWaveIn,
    [string]$MicChannel = 'left'
)

# 默认值
if (-not $GatewayUrl) { $GatewayUrl = 'http://127.0.0.1:9080' }
if (-not $Language)   { $Language = 'zh' }
if (-not $Model)      { $Model = 'small' }

# PowerShell 5.1 输出/读取都强制 UTF-8（含中文 JSON 不乱码）
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# 带 PID 后缀避免并发 voice-input.ps1 实例（AHK + 手动同时跑等）争用同一 wav 文件
$WavPath  = "$env:TEMP\voice-stt-input-$PID.wav"
$RespPath = "$env:TEMP\voice-stt-resp-$PID.json"

# === 1. 录音 ===
# 默认 auto：record.ps1 检测到 ffmpeg 就走 ffmpeg dshow，否则 waveInOpen
# -UseMci / -UseWaveIn 显式选老路径
# Interactive 模式只 MCI 支持
$recordArgs = @{ OutputPath = $WavPath }
if ($Interactive) {
    if (-not $UseMci) {
        [Console]::Error.WriteLine("[voice-input] -Interactive 目前只 MCI 路径支持；自动转 MCI")
        $UseMci = $true
    }
} else {
    $recordArgs.Duration = $Duration
}

if ($UseMci) {
    $recordArgs.UseMci = $true
} else {
    if ($UseWaveIn) { $recordArgs.UseWaveIn = $true }
    $recordArgs.DeviceId   = $DeviceId
    if ($DeviceName) { $recordArgs.DeviceName = $DeviceName }
    $recordArgs.Rate       = $Rate
    $recordArgs.Channels   = $Channels
    $recordArgs.Bits       = $Bits
    $recordArgs.WarmupSec  = $WarmupSec
    $recordArgs.MicChannel = $MicChannel
}

& "$ScriptDir\record.ps1" @recordArgs
if ($LASTEXITCODE -ne 0) { Write-Error "Recording failed"; exit 1 }
if (-not (Test-Path $WavPath)) { Write-Error "WAV not produced"; exit 1 }

# === 2. 上传到 Gateway ===
$endpoint = "$GatewayUrl/v1/audio/transcriptions"
[Console]::Error.WriteLine("Transcribing via $endpoint ...")

# 用 curl.exe（Win10+ 自带），multipart/form-data 支持稳
# 关键：把响应直接 -o 写文件，再用 PowerShell UTF-8 读，避开 OEM 编码污染
if (Test-Path $RespPath) { Remove-Item $RespPath -Force }
$curlArgs = @(
    '-sS',
    '--max-time', '60',
    '-X', 'POST',
    $endpoint,
    '-F', ('file=@' + $WavPath),
    '-F', ('model=' + $Model),
    '-F', ('language=' + $Language),
    '-F', 'response_format=json',
    '-o', $RespPath
)

& curl.exe @curlArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "Transcription request failed (curl exit $LASTEXITCODE)"
    if (-not $KeepWav) { Remove-Item $WavPath -Force -ErrorAction SilentlyContinue }
    exit 2
}
$response = Get-Content $RespPath -Raw -Encoding UTF8

# === 3. 解析 JSON ===
try {
    $json = $response | ConvertFrom-Json
    $text = $json.text
} catch {
    Write-Error "Failed to parse response: $response"
    exit 3
} finally {
    Remove-Item $RespPath -Force -ErrorAction SilentlyContinue
}

if (-not $text) {
    Write-Warning "Empty transcription"
    $text = ''
}

# === 4. 输出 ===
$text = $text.Trim()
# 关键：Write-Output 走 PowerShell pipeline，被 WSL 接收时可能落到 GBK stdout。
# 直接走 raw byte stream 写 UTF-8，确保 WSL 端能正确读取中文。
$utf8Bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text + "`n")
$stdout = [System.Console]::OpenStandardOutput()
$stdout.Write($utf8Bytes, 0, $utf8Bytes.Length)
$stdout.Flush()
if (-not $NoClipboard -and $text) {
    Set-Clipboard -Value $text
    [Console]::Error.WriteLine("(copied to clipboard, $($text.Length) chars)")
}

# === 5. 清理 ===
if (-not $KeepWav) {
    Remove-Item $WavPath -Force -ErrorAction SilentlyContinue
}
