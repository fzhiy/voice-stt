# PTT 流式语音输入：录音过程中每 2s 把 WAV 当前 snapshot 上传 whisper，
# 写部分转写到 PartialTextPath；AHK 浮窗 GUI 实时显示。
# 停止信号到 → 干净 finalize ffmpeg → 最终上传 → 写最终文本到 OutputText。
#
# 跟 voice-ptt.ps1 的差别：
#   - 多 -PartialTextPath：每 2s 写最新转写文本到这里给 AHK GUI 读
#   - 不依赖 record.ps1（复制了 ffmpeg PTT 启动逻辑，省去层层调用）

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$StopSignalPath,
    [Parameter(Mandatory=$true)]
    [string]$OutputPath,
    [Parameter(Mandatory=$true)]
    [string]$OutputText,
    [string]$PartialTextPath = "",   # 给 AHK 实时显示用
    [int]$PartialIntervalMs = 2000,
    [string]$GatewayUrl = $env:GATEWAY_URL,
    [string]$Language   = $env:WHISPER_LANG,
    [string]$Model      = $env:WHISPER_MODEL,
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

$TraceLog = "$env:TEMP\voice-ptt-stream-trace.log"
function Trace-Log {
    param([string]$msg)
    try {
        $ts = (Get-Date).ToString('HH:mm:ss.fff')
        Add-Content -Path $TraceLog -Value "[$ts pid=$PID] $msg" -Encoding UTF8
    } catch {}
}
Trace-Log "=== stream.ps1 start; sig=$StopSignalPath out=$OutputPath partial=$PartialTextPath ==="

if (Test-Path $OutputText) { Remove-Item $OutputText -Force -ErrorAction SilentlyContinue }
if ($PartialTextPath -and (Test-Path $PartialTextPath)) {
    Remove-Item $PartialTextPath -Force -ErrorAction SilentlyContinue
}

# 解析 DeviceName（如果没给，从 DeviceId 拿）
if (-not $DeviceName) {
    # Set DeviceName to your mic's dshow device name.
    # Discover it with: ffmpeg -list_devices true -f dshow -i dummy
    Write-Warning "DeviceName not set; pass -DeviceName 'your mic device' or set RECORD_DEVICE env var"
    exit 1
}

# 找 ffmpeg
$FfmpegExe = $null
foreach ($cand in @(
    'C:\ffmpeg\bin\ffmpeg.exe',
    'C:\Program Files\ffmpeg\bin\ffmpeg.exe',
    "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-*-full_build\bin\ffmpeg.exe"
)) {
    $resolved = Get-Item $cand -ErrorAction SilentlyContinue
    if ($resolved) { $FfmpegExe = $resolved.FullName; break }
}
if (-not $FfmpegExe) {
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { $FfmpegExe = $cmd.Source }
}
if (-not $FfmpegExe) {
    Set-Content -Path $OutputText -Value "" -Encoding UTF8
    Trace-Log "FAIL: ffmpeg not found"
    Write-Error "ffmpeg.exe not found"
    exit 90
}
Trace-Log "ffmpeg: $FfmpegExe"

if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }

# 构建 ffmpeg 参数（同 record.ps1 PTT 分支，无 -t 无 -nostdin）
$core = "highpass=f=80,lowpass=f=8000,dynaudnorm=f=150:g=8:p=0.9"
$af = switch ($MicChannel) {
    'left'  { "pan=mono|c0=c0,$core" }
    'right' { "pan=mono|c0=c1,$core" }
    'mix'   { "pan=mono|c0=0.5*c0+0.5*c1,$core" }
    default { $core }
}
$ffArgs = @(
    '-hide_banner','-loglevel','error','-y',
    '-fflags','+flush_packets',
    '-f','dshow','-channels','2','-sample_rate','48000',
    '-i', "audio=$DeviceName",
    '-af', $af,
    '-ar', "$Rate", '-ac', "$Channels", '-c:a', 'pcm_s16le',
    '-flush_packets', '1',
    $OutputPath
)
$quoted = $ffArgs | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $FfmpegExe
$psi.Arguments = ($quoted -join ' ')
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)
Trace-Log "ffmpeg pid=$($proc.Id) started"

# WAV header patcher：ffmpeg 输出的 WAV 在 fmt 和 data chunk 之间会插一个
# LIST/INFO 元数据块（Lavf62.x），所以 data chunk 起始位置不固定。
# 必须扫一下找到 'data' 4-byte 标记的偏移，再 patch 它的 size 跟 RIFF 总长。
function Save-WavSnapshot {
    param([string]$src, [string]$dst)
    if (-not (Test-Path $src)) { return $false }
    try {
        $fs = [System.IO.File]::Open($src, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $bytes = New-Object byte[] $fs.Length
        [void]$fs.Read($bytes, 0, $bytes.Length)
        $fs.Close()
    } catch {
        return $false
    }
    if ($bytes.Length -lt 48) { return $false }
    # 扫前 256 字节找 'data' (44 61 74 61)
    $dataOff = -1
    $scanEnd = [Math]::Min(256, $bytes.Length - 8)
    for ($i = 12; $i -lt $scanEnd; $i++) {
        if ($bytes[$i] -eq 0x64 -and $bytes[$i+1] -eq 0x61 -and $bytes[$i+2] -eq 0x74 -and $bytes[$i+3] -eq 0x61) {
            $dataOff = $i
            break
        }
    }
    if ($dataOff -lt 0) { return $false }
    $pcmStart = $dataOff + 8
    $pcmSize = $bytes.Length - $pcmStart
    if ($pcmSize -le 0) { return $false }
    # patch data chunk size（紧跟 'data' 标记的 4 字节）
    [BitConverter]::GetBytes([uint32]$pcmSize).CopyTo($bytes, $dataOff + 4)
    # patch RIFF total size = file size - 8（RIFF header 前 8 字节不计）
    [BitConverter]::GetBytes([uint32]($bytes.Length - 8)).CopyTo($bytes, 4)
    [System.IO.File]::WriteAllBytes($dst, $bytes)
    return $true
}

function Invoke-PartialTranscribe {
    # PowerShell 函数有自己 scope，外层 $GatewayUrl 等看不到 → 显式传参
    param([string]$wavPath, [string]$gateway, [string]$model, [string]$lang)
    $endpoint = "$gateway/v1/audio/transcriptions"
    $resp = "$env:TEMP\voice-ptt-stream-partial-$PID.json"
    $curlErr = "$env:TEMP\voice-ptt-stream-curl-$PID.err"
    & curl.exe -sS --max-time 30 -X POST $endpoint `
        -F "file=@$wavPath" -F "model=$model" -F "language=$lang" `
        -F 'response_format=json' -o $resp 2>$curlErr
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        $errTxt = if (Test-Path $curlErr) { Get-Content $curlErr -Raw -ErrorAction SilentlyContinue } else { '' }
        Trace-Log "curl exit=$rc err='$errTxt'"
        Remove-Item $resp, $curlErr -Force -ErrorAction SilentlyContinue
        return $null
    }
    if (-not (Test-Path $resp)) {
        Trace-Log "curl exit=0 but no resp file"
        return $null
    }
    $rawResp = Get-Content $resp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    try {
        $json = $rawResp | ConvertFrom-Json
        Remove-Item $resp, $curlErr -Force -ErrorAction SilentlyContinue
        return $json.text.Trim()
    } catch {
        Trace-Log "JSON parse failed; raw resp (first 200): '$(if ($rawResp) { $rawResp.Substring(0, [Math]::Min(200, $rawResp.Length)) } else { '' })'"
        Remove-Item $resp, $curlErr -Force -ErrorAction SilentlyContinue
        return $null
    }
}

# 主循环：轮询 stop signal，同时按间隔做 partial upload
$snapshotPath = "$env:TEMP\voice-stt-stream-snap-$PID.wav"
$lastPartialAt = [System.Diagnostics.Stopwatch]::StartNew()
$inFlight = $false

while (-not (Test-Path $StopSignalPath)) {
    if ($proc.HasExited) { break }
    Start-Sleep -Milliseconds 100

    if ($PartialTextPath -and $lastPartialAt.ElapsedMilliseconds -ge $PartialIntervalMs -and -not $inFlight) {
        $inFlight = $true
        $lastPartialAt.Restart()
        Trace-Log "partial tick: snapshotting wav (size=$((Get-Item $OutputPath -ErrorAction SilentlyContinue).Length))"
        $ok = Save-WavSnapshot -src $OutputPath -dst $snapshotPath
        Trace-Log "snapshot ok=$ok"
        if ($ok) {
            $partial = Invoke-PartialTranscribe -wavPath $snapshotPath -gateway $GatewayUrl -model $Model -lang $Language
            Trace-Log "partial returned: $(if ($null -eq $partial) {'<null>'} else {"'$($partial.Substring(0, [Math]::Min(60, $partial.Length)))...'"})"
            if ($null -ne $partial) {
                try {
                    [System.IO.File]::WriteAllText($PartialTextPath, $partial, [System.Text.UTF8Encoding]::new($false))
                    Trace-Log "wrote partial ($($partial.Length) chars)"
                } catch {
                    Trace-Log "write partial failed: $($_.Exception.Message)"
                }
            }
        }
        $inFlight = $false
    }
}
Trace-Log "stop signal received OR ffmpeg exited"

# 给 ffmpeg 写 q 触发干净退出
if (-not $proc.HasExited) {
    try {
        $proc.StandardInput.WriteLine('q')
        $proc.StandardInput.Flush()
        $proc.StandardInput.Close()
    } catch {
        Trace-Log "stdin q failed: $($_.Exception.Message)"
    }
    if (-not $proc.WaitForExit(5000)) {
        Trace-Log "ffmpeg 5s timeout, killing"
        try { $proc.Kill() } catch {}
        $proc.WaitForExit(2000) | Out-Null
    }
}
Trace-Log "ffmpeg exit code=$($proc.ExitCode)"

# 清理 snapshot 跟 signal 文件
if (Test-Path $snapshotPath) { Remove-Item $snapshotPath -Force -ErrorAction SilentlyContinue }
if (Test-Path $StopSignalPath) { Remove-Item $StopSignalPath -Force -ErrorAction SilentlyContinue }

if (-not (Test-Path $OutputPath)) {
    Set-Content -Path $OutputText -Value "" -Encoding UTF8
    Trace-Log "FAIL: WAV not produced"
    Write-Error "WAV not produced"
    exit 1
}
$sz = (Get-Item $OutputPath).Length
if ($sz -le 44) {
    Set-Content -Path $OutputText -Value "" -Encoding UTF8
    Trace-Log "FAIL: WAV empty ($sz bytes)"
    Write-Error "Empty WAV"
    exit 1
}

# 最终上传：完整 WAV，让 whisper 在完整上下文里出最终结果（最高质量）
Trace-Log "FINAL POST $GatewayUrl/v1/audio/transcriptions (wav=$sz bytes)"
$final = Invoke-PartialTranscribe -wavPath $OutputPath -gateway $GatewayUrl -model $Model -lang $Language
if ($null -eq $final) {
    Set-Content -Path $OutputText -Value "" -Encoding UTF8
    Trace-Log "FAIL: final transcribe returned null"
    Write-Error "Final transcribe failed"
    exit 2
}

[System.IO.File]::WriteAllText($OutputText, $final, [System.Text.UTF8Encoding]::new($false))
Trace-Log "wrote OutputText ($($final.Length) chars)"

if (-not $KeepWav) {
    Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
}
Trace-Log "=== stream.ps1 end ==="
