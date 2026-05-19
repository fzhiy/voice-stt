# 真流式 PTT 客户端（WebSocket 到 FunASR Paraformer-zh-streaming 服务）
#
# 跟 voice-ptt-stream.ps1 的差别：
#   - 不走 mini-gateway batch /v1/audio/transcriptions
#   - ffmpeg -f s16le 直接吐 PCM 到 stdout，PS 读 200ms 切片，binary frame 发 WS
#   - WS 服务端每 chunk 推理 ~600ms 延迟，partial 回 JSON 文本帧
#   - 停止信号到 → 发 "EOF" 文本帧 → 等 final → 写文件
#
# 依赖：.NET 4.5+（PS 5.1 自带），有 System.Net.WebSockets.ClientWebSocket
# 假设：远端 ws://127.0.0.1:8082 已通（SSH tunnel 转 GPU host 8082）

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$StopSignalPath,
    [Parameter(Mandatory=$true)]
    [string]$OutputText,
    [string]$PartialTextPath = "",
    [string]$WsUrl           = "ws://127.0.0.1:18082/",   # ASR server WS endpoint (local, or SSH-tunneled to a remote GPU host)
    [int]$DeviceId           = 0,
    [string]$DeviceName      = "",
    [string]$MicChannel      = 'mix',
    [int]$Rate               = 16000,
    # Daemon pipe (voice-mic-daemon.ps1). Try this first for warm-mic pre-roll;
    # fall back to local ffmpeg if not reachable in $DaemonConnectTimeoutMs.
    [string]$DaemonPipeName        = 'voice-mic-pcm-server',
    [int]$DaemonConnectTimeoutMs   = 500
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

$voiceSttDir = "$env:LOCALAPPDATA\voice-stt"
if (-not (Test-Path $voiceSttDir)) { New-Item -ItemType Directory -Path $voiceSttDir -Force | Out-Null }
$TraceLog = "$voiceSttDir\stream-ws-trace.log"
function Trace-Log([string]$msg) {
    try {
        $ts = (Get-Date).ToString('HH:mm:ss.fff')
        Add-Content -Path $TraceLog -Value "[$ts pid=$PID] $msg" -Encoding UTF8
    } catch {}
}
Trace-Log "=== ws stream start; sig=$StopSignalPath partial=$PartialTextPath ws=$WsUrl ==="

if (Test-Path $OutputText) { Remove-Item $OutputText -Force -ErrorAction SilentlyContinue }
if ($PartialTextPath -and (Test-Path $PartialTextPath)) {
    Remove-Item $PartialTextPath -Force -ErrorAction SilentlyContinue
}
if (-not $DeviceName) { $DeviceName = $env:RECORD_DEVICE_NAME }
if (-not $DeviceName) {
    # Discover mic dshow names with: ffmpeg -list_devices true -f dshow -i dummy
    Write-Warning "DeviceName not set; pass -DeviceName 'your mic device' or set RECORD_DEVICE_NAME env var"
    exit 1
}

# PCM source: 优先连 voice-mic-daemon 的 named pipe (拿 ~300ms pre-roll),
# 失败回退到本地启 ffmpeg (老路径; 吞前 0.3s 但保证可用).
# $ffProc 仅 fallback 路径有值, cleanup 时 null-check.
$ffProc      = $null
$ffOutSource = $null
$pipeClient  = $null
try {
    $pipeClient = New-Object System.IO.Pipes.NamedPipeClientStream(
        '.', $DaemonPipeName,
        [System.IO.Pipes.PipeDirection]::In,
        [System.IO.Pipes.PipeOptions]::None
    )
    $pipeClient.Connect($DaemonConnectTimeoutMs)
    $ffOutSource = $pipeClient
    Trace-Log "PCM source: daemon pipe \\.\pipe\$DaemonPipeName (pre-roll enabled)"
} catch {
    Trace-Log "daemon pipe connect failed ($($_.Exception.Message)); falling back to local ffmpeg"
    if ($pipeClient) { try { $pipeClient.Dispose() } catch {}; $pipeClient = $null }
}

if (-not $ffOutSource) {
    # ===== Fallback: local ffmpeg launch (legacy path) =====
    $FfmpegExe = $null
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { $FfmpegExe = $cmd.Source }
    if (-not $FfmpegExe) {
        foreach ($cand in @(
            "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-*-full_build\bin\ffmpeg.exe"
        )) {
            $r = Get-Item $cand -ErrorAction SilentlyContinue
            if ($r) { $FfmpegExe = $r.FullName; break }
        }
    }
    if (-not $FfmpegExe) {
        Set-Content -Path $OutputText -Value "" -Encoding UTF8
        Trace-Log "FAIL: ffmpeg not found (and daemon pipe unavailable)"
        exit 90
    }
    Trace-Log "fallback ffmpeg: $FfmpegExe"

    # 单声道 16kHz int16 LE 是 FunASR 的输入格式
    # dynaudnorm 的 frame_len * gauss_size/2 是 look-ahead 延迟。f=150 g=8 ≈ 600ms 启动延迟，
    # 把流式预览拖到 ~2s 才出第一个字。f=50 g=3 ≈ 100ms 延迟，正常化效果略弱但够用。
    $core = "highpass=f=80,lowpass=f=8000,dynaudnorm=f=50:g=3:p=0.95"
    $af = switch ($MicChannel) {
        'left'  { "pan=mono|c0=c0,$core" }
        'right' { "pan=mono|c0=c1,$core" }
        'mix'   { "pan=mono|c0=0.5*c0+0.5*c1,$core" }
        default { $core }
    }
    $ffArgs = @(
        '-hide_banner','-loglevel','error',
        '-fflags','+flush_packets',
        '-f','dshow','-channels','2','-sample_rate','48000',
        '-i', "audio=$DeviceName",
        '-af', $af,
        '-ar', "$Rate", '-ac', '1', '-c:a','pcm_s16le',
        '-flush_packets','1',
        '-f','s16le', 'pipe:1'
    )
    $quoted = $ffArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }
    $ffStderr = "$env:TEMP\voice-stream-ws-ffmpeg-$PID.err"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfmpegExe
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $ffProc = [System.Diagnostics.Process]::Start($psi)
    $ffOutSource = $ffProc.StandardOutput.BaseStream
    Trace-Log "ffmpeg pid=$($ffProc.Id) started (fallback path)"
}

# 连 WebSocket
Add-Type -AssemblyName System.Net.WebSockets 2>$null  # PS 5.1 might need
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = (New-Object System.Threading.CancellationTokenSource 10000).Token
try {
    $ws.ConnectAsync([Uri]$WsUrl, $ct).GetAwaiter().GetResult()
    Trace-Log "ws connected, state=$($ws.State)"
} catch {
    Trace-Log "ws connect FAILED: $($_.Exception.Message)"
    if ($ffProc) { try { $ffProc.Kill() } catch {} }
    if ($pipeClient) { try { $pipeClient.Dispose() } catch {} }
    Set-Content -Path $OutputText -Value "" -Encoding UTF8
    exit 91
}

# 后台接收循环用 Task 模式
$rxBuffer = New-Object byte[] 32768
$rxSegment = [System.ArraySegment[byte]]::new($rxBuffer)
$finalText = $null
$lastPartial = $null  # 最新一条 partial 文本，final timeout 时作为兜底
$rxText = ''  # 累积一帧的内容（处理多帧 fragment）
# 收到第一个 qwen3-asr-partial 后置 true 永不复位：之后忽略 paraformer 流式 partial。
# UX：开头 ~1.5s 显示 paraformer "立刻见字"，第一个 qwen3 partial 到达后切准确文本。
$qwen3PartialSeen = $false

function Process-Message([string]$text) {
    Trace-Log "rx: $text"
    try {
        $json = $text | ConvertFrom-Json
        if ($json.type -eq 'partial') {
            # PS 5.1：用 PSObject.Properties 显式检查字段存在性（无 null-coalescing）
            $isQwen3 = $json.PSObject.Properties['backend'] -and ($json.backend -eq 'qwen3-asr-partial')
            if ($isQwen3) {
                $global:qwen3PartialSeen = $true
            } elseif ($global:qwen3PartialSeen) {
                return  # 已切到 qwen3，忽略后续 paraformer partial
            }
            if ($PartialTextPath) {
                [System.IO.File]::WriteAllText($PartialTextPath, $json.text, [System.Text.UTF8Encoding]::new($false))
            }
            $global:lastPartial = $json.text
        } elseif ($json.type -eq 'final') {
            $global:finalText = $json.text
        }
    } catch {
        Trace-Log "parse rx failed: $($_.Exception.Message)"
    }
}

# 主循环：PCM source 读 → 发 WS；同时 poll 接收
# 100ms 切片让第一帧更早到 server（200ms 时会多 100ms 启动延迟）
# Source 可能是 ffmpeg.StandardOutput.BaseStream (fallback) 或 NamedPipeClientStream (daemon).
# 两条路径都用 Stream.Read API; daemon 路径下没有 ffProc, source-alive 判定改用 pipeClient.IsConnected.
$audioBuf = New-Object byte[] 3200   # 100ms @ 16kHz mono 16-bit = 3200 bytes
$ffOut = $ffOutSource
$totalSent = 0
$rxTask = $null
$eofSent = $false
# 松手后继续读 PCM 的 grace period (ms):
# - dynaudnorm look-ahead ~100ms (filter 输出落后输入 100ms)
# - daemon ring buffer broadcast 也有少量延迟
# - server-side qwen3-asr-partial 推理间隔 ~1s, 短 drain 会让 EOF 早于"包含话尾的那条 partial",
#   server 立刻 derive_from_last_partial → final 缺末尾几个字 (实测 30s+ 录音 "强大的音频" 后面全吞)
# 1500ms 保证至少多 1 次完整 qwen3 推理周期, server 拿到的最新 partial 包含真正的话尾.
# 代价: 松手到 final 的 latency 多 ~1.3s, 但用户已经习惯松手等 1s.
$drainMs = 1500
$drainStarted   = $false
$drainStartedAt = 0L  # TickCount64 absolute, only valid when $drainStarted = $true

function Test-SourceAlive {
    if ($ffProc) { return -not $ffProc.HasExited }
    if ($pipeClient) { return $pipeClient.IsConnected }
    return $false
}

function Stop-Source {
    # PTT 结束时关 PCM 流: ffmpeg 路径 kill 进程; daemon 路径仅断开 pipe (daemon 继续跑).
    if ($ffProc) { try { $ffProc.Kill() } catch {} }
    if ($pipeClient) { try { $pipeClient.Dispose() } catch {} }
}

while ($true) {
    # 检查停止信号 — 启动 drain mode，不立刻 EOF
    if ((Test-Path $StopSignalPath) -and -not $drainStarted) {
        $drainStarted   = $true
        $drainStartedAt = [Environment]::TickCount64
        Trace-Log "stop signal received, entering ${drainMs}ms drain"
    }

    # drain 完成 → 发 EOF
    if ($drainStarted -and -not $eofSent) {
        $elapsed = [Environment]::TickCount64 - $drainStartedAt
        if ($elapsed -ge $drainMs) {
            Trace-Log "drain complete (${elapsed}ms), sending EOF (totalSent=$totalSent)"
            try {
                $eofBytes = [System.Text.Encoding]::UTF8.GetBytes("EOF")
                $eofSeg = [System.ArraySegment[byte]]::new($eofBytes)
                $ws.SendAsync($eofSeg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
                $eofSent = $true
            } catch {
                Trace-Log "send EOF failed: $($_.Exception.Message)"
                break
            }
            Stop-Source
        }
    }

    # 读 PCM (非阻塞之前先确认有数据)
    if (-not $eofSent -and (Test-SourceAlive)) {
        $n = 0
        try {
            $n = $ffOut.Read($audioBuf, 0, $audioBuf.Length)
        } catch {
            Trace-Log "read PCM source failed: $($_.Exception.Message)"
            $n = 0
        }
        if ($n -gt 0) {
            $totalSent += $n
            $seg = [System.ArraySegment[byte]]::new($audioBuf, 0, $n)
            try {
                $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Binary, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            } catch {
                Trace-Log "send chunk failed: $($_.Exception.Message)"
                break
            }
        }
    }

    # 非阻塞接收：用 1ms 超时的 CTS
    if (-not $rxTask -or $rxTask.IsCompleted) {
        if ($rxTask -and $rxTask.IsCompleted) {
            try {
                $result = $rxTask.GetAwaiter().GetResult()
                if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                    $msg = [System.Text.Encoding]::UTF8.GetString($rxBuffer, 0, $result.Count)
                    Process-Message $msg
                    if ($finalText -ne $null) { break }
                } elseif ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    Trace-Log "server closed connection"
                    break
                }
            } catch {
                Trace-Log "rx task ex: $($_.Exception.Message)"
            }
        }
        # 开新 receive
        $rxTask = $ws.ReceiveAsync($rxSegment, [System.Threading.CancellationToken]::None)
    }

    if ($eofSent -and -not (Test-SourceAlive)) {
        # 已发 EOF，等 final。server 处理速度 ~1.5x realtime，60s 录音可能要 40s+，
        # 留 90s 缓冲。超时后用 $lastPartial 兜底，绝不输出空。
        $waitStart = [System.Diagnostics.Stopwatch]::StartNew()
        while ($finalText -eq $null -and $waitStart.ElapsedMilliseconds -lt 90000) {
            if ($rxTask.IsCompleted) {
                try {
                    $result = $rxTask.GetAwaiter().GetResult()
                    if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                        $msg = [System.Text.Encoding]::UTF8.GetString($rxBuffer, 0, $result.Count)
                        Process-Message $msg
                        if ($finalText -ne $null) { break }
                    }
                } catch {}
                $rxTask = $ws.ReceiveAsync($rxSegment, [System.Threading.CancellationToken]::None)
            }
            Start-Sleep -Milliseconds 50
        }
        if ($finalText -eq $null -and $lastPartial -ne $null) {
            Trace-Log "final not received in 90s, using lastPartial as fallback"
            $finalText = $lastPartial
        }
        break
    }
}

Trace-Log "loop exit; totalSent=$totalSent bytes, eofSent=$eofSent, final='$finalText'"

# CloseAsync 可能会等 pending receive task 完成 → 无超时会永远 hang，
# 上游 AHK 也跟着死等。给 2s CTS 兜底，超过就强 dispose。
try {
    $closeCts = New-Object System.Threading.CancellationTokenSource 2000
    $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "bye", $closeCts.Token).GetAwaiter().GetResult()
} catch {
    Trace-Log "ws close timed out or errored: $($_.Exception.Message)"
}
try { $ws.Dispose() } catch {}
if ($pipeClient) { try { $pipeClient.Dispose() } catch {} }
if ($ffProc -and -not $ffProc.HasExited) { try { $ffProc.Kill() } catch {} }
if (Test-Path $StopSignalPath) { Remove-Item $StopSignalPath -Force -ErrorAction SilentlyContinue }

if ($finalText -eq $null) { $finalText = '' }
[System.IO.File]::WriteAllText($OutputText, $finalText.Trim(), [System.Text.UTF8Encoding]::new($false))
Trace-Log "wrote OutputText ($($finalText.Length) chars)"
Trace-Log "=== ws stream end ==="
