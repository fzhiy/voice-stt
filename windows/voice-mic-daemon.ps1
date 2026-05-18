# voice-mic-daemon.ps1 — warm mic capture daemon
#
# 一直常驻的 ffmpeg dshow 进程，把 mic PCM (16kHz int16 mono, left-channel only)
# 写入一个 500ms 环形缓冲；同时跑一个 named pipe server。每来一个 PTT client
# 连接 (voice-ptt-stream-ws.ps1 / 未来 record.ps1)，先把环形缓冲当前快照写过去
# (= ~300ms pre-roll，覆盖按下热键之前那段被吞的语音)，然后实时跟随 ffmpeg
# 输出广播 PCM。
#
# 业内对标：Discord / Mumble / TeamSpeak / macOS Dictation 都这么做。
# Reference: docs/dev/changes/2026-05-16-mic-warm-capture.md
#
# 依赖：.NET 4.5+ (PS 5.1 自带). System.IO.Pipes.NamedPipeServerStream 走 byte 模式.
# 假设：ffmpeg.exe 在 PATH 或 winget Gyan.FFmpeg 默认目录.
#
# 日志：$env:TEMP\voice-mic-daemon-<pid>.log
# 退出：被 AHK OnExit kill (taskkill /F /T /PID)，子 ffmpeg 自然随之退.

[CmdletBinding()]
param(
    # Mic dshow device name. Discover with: ffmpeg -list_devices true -f dshow -i dummy
    # Resolution order: -DeviceName param > $env:RECORD_DEVICE_NAME > error.
    [string]$DeviceName = "",
    [int]$Rate          = 16000,
    [int]$BufferMs      = 500,
    [string]$MicChannel = 'left',
    [string]$PipeName   = 'voice-mic-pcm-server',
    [int]$MaxClients    = 4
)

# Fall back to env var if -DeviceName not supplied (allows AHK-spawned daemons to inherit
# the user's .env without having to pass -DeviceName on the command line every time).
if (-not $DeviceName) { $DeviceName = $env:RECORD_DEVICE_NAME }
if (-not $DeviceName) {
    Write-Error "Mic device name not set. Pass -DeviceName 'your mic' or set RECORD_DEVICE_NAME env var. Discover names with: ffmpeg -list_devices true -f dshow -i dummy"
    exit 91
}

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$voiceSttDir = "$env:LOCALAPPDATA\voice-stt"
if (-not (Test-Path $voiceSttDir)) { New-Item -ItemType Directory -Path $voiceSttDir -Force | Out-Null }
$LogPath = "$voiceSttDir\mic-daemon-$PID.log"
function Trace-Log([string]$msg) {
    try {
        $ts = (Get-Date).ToString('HH:mm:ss.fff')
        Add-Content -Path $LogPath -Value "[$ts pid=$PID] $msg" -Encoding UTF8
    } catch {}
}
Trace-Log "=== daemon start: device='$DeviceName' rate=$Rate bufferMs=$BufferMs pipe=\\.\pipe\$PipeName ==="

# Find ffmpeg (same probe order as voice-ptt-stream-ws.ps1)
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
if (-not $FfmpegExe) { Trace-Log "FAIL: ffmpeg not found"; exit 90 }
Trace-Log "ffmpeg: $FfmpegExe"

# 同 voice-ptt-stream-ws.ps1 line 66-82 的 dshow 配置；左声道 mono 16kHz int16.
# <mic-vendor> 阵列右声道损坏 (见 memory)，必须 pan=mono|c0=c0.
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
$ffStderr = "$env:TEMP\voice-mic-daemon-ffmpeg-$PID.err"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = $FfmpegExe
$psi.Arguments              = ($quoted -join ' ')
$psi.UseShellExecute        = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.CreateNoWindow         = $true
$ffProc = [System.Diagnostics.Process]::Start($psi)
Trace-Log "ffmpeg pid=$($ffProc.Id) started"

# Ring buffer: BufferMs * Rate * 2 bytes (int16 mono).
# 500ms * 16000 * 2 = 16000 bytes. 写满后循环覆盖最旧.
$bufferSize    = [int]($BufferMs * $Rate / 1000) * 2
$ringBuffer    = New-Object byte[] $bufferSize
$writePos      = 0
$bufferFilled  = $false   # 还没写满一圈前快照只取 [0..writePos)
Trace-Log "ring buffer initialized: $bufferSize bytes (= $BufferMs ms @ $Rate Hz)"

# Pipe server: 用 MaxClients 个 instance allow 并发 (虽然实际只会 1 个 PTT 同时按).
# Asynchronous + WaitForConnectionAsync 让主 loop 不阻塞地接受新连接.
[System.IO.Pipes.PipeOptions]$pipeOpts = [System.IO.Pipes.PipeOptions]::Asynchronous
function New-PipeInstance() {
    return New-Object System.IO.Pipes.NamedPipeServerStream(
        $PipeName,
        [System.IO.Pipes.PipeDirection]::Out,
        $MaxClients,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        $pipeOpts
    )
}
$pendingPipe = New-PipeInstance
$pendingConnectTask = $pendingPipe.WaitForConnectionAsync()
Trace-Log "pipe server listening on \\.\pipe\$PipeName (max=$MaxClients)"

$activeClients = @{}   # hashtable: pipe-object -> @{stream=pipe; lastSeq=[long]}
$chunkSeq      = 0L   # monotonic counter, incremented each time a chunk enters the ring buffer
$chunkBuf      = New-Object byte[] 4096

# Main loop: ffmpeg.read -> ring buffer -> broadcast to active clients.
# 每次 chunk 之后看 pendingConnectTask 是否完成 -> 发 snapshot + 加入 active list,
# 然后开新的 pending pipe instance 等下一个连接.
$totalRead = 0
try {
    $ffOut = $ffProc.StandardOutput.BaseStream
    while (-not $ffProc.HasExited) {
        $n = 0
        try {
            $n = $ffOut.Read($chunkBuf, 0, $chunkBuf.Length)
        } catch {
            Trace-Log "ffmpeg read err: $($_.Exception.Message)"; break
        }
        if ($n -le 0) { break }
        $totalRead += $n

        # Write into ring buffer (chunk could wrap around end)
        $remain = $n; $offset = 0
        while ($remain -gt 0) {
            $space  = $bufferSize - $writePos
            $toCopy = [Math]::Min($remain, $space)
            [Array]::Copy($chunkBuf, $offset, $ringBuffer, $writePos, $toCopy)
            $writePos = ($writePos + $toCopy) % $bufferSize
            if ($writePos -eq 0) { $bufferFilled = $true }
            $offset += $toCopy; $remain -= $toCopy
        }
        $chunkSeq++   # advance sequence counter after ring-buffer write

        # Accept new pipe client (non-blocking; check task status)
        if ($pendingConnectTask.IsCompleted) {
            try {
                $pendingConnectTask.GetAwaiter().GetResult()
                # Snapshot the ring buffer in chronological order
                if ($bufferFilled) {
                    $snap = New-Object byte[] $bufferSize
                    $tail = $bufferSize - $writePos
                    [Array]::Copy($ringBuffer, $writePos, $snap, 0, $tail)
                    [Array]::Copy($ringBuffer, 0, $snap, $tail, $writePos)
                } elseif ($writePos -gt 0) {
                    $snap = New-Object byte[] $writePos
                    [Array]::Copy($ringBuffer, 0, $snap, 0, $writePos)
                } else {
                    $snap = New-Object byte[] 0
                }
                if ($snap.Length -gt 0) {
                    $pendingPipe.Write($snap, 0, $snap.Length)
                }
                Trace-Log "client connected; pre-rolled $($snap.Length) bytes (~$([int]($snap.Length / 32))ms)"
                # Register with lastSeq = $chunkSeq so the broadcast loop does NOT
                # re-send the chunk that is already included in the snapshot above.
                $activeClients[$pendingPipe] = @{ stream = $pendingPipe; lastSeq = $chunkSeq }
            } catch {
                Trace-Log "accept connection failed: $($_.Exception.Message)"
                try { $pendingPipe.Dispose() } catch {}
            }
            $pendingPipe = New-PipeInstance
            $pendingConnectTask = $pendingPipe.WaitForConnectionAsync()
        }

        # Broadcast chunk to active clients; mark dead ones for removal
        if ($activeClients.Count -gt 0) {
            $deadKeys = [System.Collections.ArrayList]::new()
            foreach ($entry in $activeClients.GetEnumerator()) {
                $clientInfo = $entry.Value
                if ($chunkSeq -le $clientInfo.lastSeq) { continue }   # already received via snapshot
                try {
                    $clientInfo.stream.Write($chunkBuf, 0, $n)
                    $clientInfo.lastSeq = $chunkSeq
                } catch {
                    Trace-Log "client write err (disconnect): $($_.Exception.Message)"
                    [void]$deadKeys.Add($entry.Key)
                }
            }
            foreach ($key in $deadKeys) {
                try { $activeClients[$key].stream.Dispose() } catch {}
                $activeClients.Remove($key)
            }
        }
    }
} catch {
    Trace-Log "main loop EX: $($_.Exception.Message)"
} finally {
    Trace-Log "shutdown: totalRead=$totalRead bytes, activeClients=$($activeClients.Count)"
    foreach ($entry in $activeClients.GetEnumerator()) { try { $entry.Value.stream.Dispose() } catch {} }
    try { $pendingPipe.Dispose() } catch {}
    if (-not $ffProc.HasExited) { try { $ffProc.Kill() } catch {} }
    Trace-Log "=== daemon end ==="
}
