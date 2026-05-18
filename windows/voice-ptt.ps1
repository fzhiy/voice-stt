# PTT（Press-To-Talk）语音输入入口
# 跟 voice-input.ps1 同结构，但不传 -Duration，靠 -StopSignalPath 文件触发停止
# AHK 调用流程：
#   1. Run "powershell ... voice-ptt.ps1 -StopSignalPath sig -OutputPath wav -OutputText txt"
#      → ffmpeg 立即起来（无 -t），等信号文件
#   2. AHK KeyWait V 释放 → FileAppend sig
#      → ffmpeg 收到 'q' 干净退出
#   3. PS 上传 wav → 写转写文本到 OutputText
#   4. AHK ProcessWaitClose 后读 OutputText、粘贴

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$StopSignalPath,
    [Parameter(Mandatory=$true)]
    [string]$OutputPath,
    [Parameter(Mandatory=$true)]
    [string]$OutputText,
    [string]$GatewayUrl = $env:GATEWAY_URL,
    [string]$Language   = $env:WHISPER_LANG,
    [string]$Model      = $env:WHISPER_MODEL,
    # 默认值与 .env 中的 RECORD_* 一致
    [int]$DeviceId      = 0,
    [string]$DeviceName = "",
    [string]$MicChannel = 'left',
    [int]$Rate          = 16000,
    [int]$Channels      = 1,
    [int]$Bits          = 16,
    [switch]$KeepWav
)

if (-not $GatewayUrl) { $GatewayUrl = 'http://127.0.0.1:9080' }
if (-not $Language)   { $Language = 'zh' }
if (-not $Model)      { $Model = 'small' }

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RespPath  = "$env:TEMP\voice-stt-ptt-resp-$PID.json"

# 详细 trace 日志，给 AHK 失败时回溯用。Append 模式保留历史。
$voiceSttDir = "$env:LOCALAPPDATA\voice-stt"
if (-not (Test-Path $voiceSttDir)) { New-Item -ItemType Directory -Path $voiceSttDir -Force | Out-Null }
$TraceLog = "$voiceSttDir\ptt-trace.log"
function Trace-Log {
    param([string]$msg)
    try {
        $ts = (Get-Date).ToString('HH:mm:ss.fff')
        Add-Content -Path $TraceLog -Value "[$ts pid=$PID] $msg" -Encoding UTF8
    } catch {}
}
Trace-Log "=== voice-ptt.ps1 start; args: sig=$StopSignalPath out=$OutputPath txt=$OutputText ==="

# 找 record.ps1：优先同目录（install.ps1 会把它复制过去）；
# 可选 UNC 回退用于 dev 模式直接从 WSL 仓库运行——通过环境变量 VOICE_STT_WSL_REPO_UNC 配置
# (例如：\\wsl.localhost\Ubuntu\home\<USER>\voice-stt\windows)
$RecordPs1Candidates = @(
    (Join-Path $ScriptDir 'record.ps1')
)
if ($env:VOICE_STT_WSL_REPO_UNC) {
    $RecordPs1Candidates += (Join-Path $env:VOICE_STT_WSL_REPO_UNC 'record.ps1')
}
$RecordPs1 = $null
foreach ($cand in $RecordPs1Candidates) {
    if (Test-Path $cand) { $RecordPs1 = $cand; break }
}
if (-not $RecordPs1) {
    Set-Content -Path $OutputText -Value "" -Encoding UTF8
    Write-Error "record.ps1 not found in any of: $($RecordPs1Candidates -join '; ')"
    exit 90
}

# 提前清空 OutputText，避免 AHK 读到上次残留
if (Test-Path $OutputText) { Remove-Item $OutputText -Force -ErrorAction SilentlyContinue }

# === 1. 录音（PTT） ===
$recordArgs = @{
    OutputPath     = $OutputPath
    StopSignalPath = $StopSignalPath
    DeviceId       = $DeviceId
    Rate           = $Rate
    Channels       = $Channels
    Bits           = $Bits
    MicChannel     = $MicChannel
}
if ($DeviceName) { $recordArgs.DeviceName = $DeviceName }

Trace-Log "calling record.ps1 at $RecordPs1"
& $RecordPs1 @recordArgs
$recordRc = $LASTEXITCODE
Trace-Log "record.ps1 returned exit=$recordRc; wav exists=$(Test-Path $OutputPath)"
if ($recordRc -ne 0) {
    Set-Content -Path $OutputText -Value "" -Encoding UTF8
    Trace-Log "FAIL: record.ps1 exit $recordRc"
    Write-Error "PTT recording failed (record.ps1 exit $recordRc)"
    exit 1
}
if (-not (Test-Path $OutputPath)) {
    Set-Content -Path $OutputText -Value "" -Encoding UTF8
    Trace-Log "FAIL: WAV not produced"
    Write-Error "WAV not produced"
    exit 1
}

# === 2. 上传到 Gateway ===
$endpoint = "$GatewayUrl/v1/audio/transcriptions"
[Console]::Error.WriteLine("Transcribing via $endpoint ...")

if (Test-Path $RespPath) { Remove-Item $RespPath -Force }
$curlArgs = @(
    '-sS',
    '--max-time', '120',
    '-X', 'POST',
    $endpoint,
    '-F', ('file=@' + $OutputPath),
    '-F', ('model=' + $Model),
    '-F', ('language=' + $Language),
    '-F', 'response_format=json',
    '-o', $RespPath
)
Trace-Log "POST $endpoint (wav size=$((Get-Item $OutputPath).Length))"
& curl.exe @curlArgs
$curlRc = $LASTEXITCODE
Trace-Log "curl returned exit=$curlRc; resp exists=$(Test-Path $RespPath)"
if ($curlRc -ne 0) {
    Set-Content -Path $OutputText -Value "" -Encoding UTF8
    Trace-Log "FAIL: curl exit $curlRc"
    Write-Error "Transcription request failed (curl exit $curlRc)"
    if (-not $KeepWav) { Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue }
    exit 2
}

$response = Get-Content $RespPath -Raw -Encoding UTF8
try {
    $json = $response | ConvertFrom-Json
    $text = $json.text
} catch {
    Set-Content -Path $OutputText -Value "" -Encoding UTF8
    Write-Error "Failed to parse response: $response"
    exit 3
} finally {
    Remove-Item $RespPath -Force -ErrorAction SilentlyContinue
}
if (-not $text) { $text = '' }
$text = $text.Trim()

# === 3. 写到 OutputText 给 AHK 读 ===
# 显式 UTF-8 无 BOM；AHK FileRead 用 "UTF-8" 选项即可正常读
[System.IO.File]::WriteAllText($OutputText, $text, [System.Text.UTF8Encoding]::new($false))
Trace-Log "wrote OutputText ($($text.Length) chars): '$text'"

# === 4. 清理 ===
if (-not $KeepWav) {
    Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
}
Trace-Log "=== voice-ptt.ps1 end ==="
