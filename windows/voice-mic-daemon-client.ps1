# voice-mic-daemon-client.ps1 — L2 smoke test helper for voice-mic-daemon.
# 连 daemon 的 named pipe, 读 $Seconds 秒 PCM dump 到 $OutFile (默认 daemon-test.pcm).
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File voice-mic-daemon-client.ps1
#
# 验证标准: 文件大小应该 ~= Seconds * 16000 * 2 bytes (默认 5s -> 160000 bytes).
# 如果文件大小明显 < 预期, daemon 在掉数据或者 ffmpeg 抓不到 mic.

[CmdletBinding()]
param(
    [string]$PipeName = 'voice-mic-pcm-server',
    [int]$Seconds     = 5,
    [string]$OutFile  = "$env:TEMP\daemon-test.pcm"
)

$client = New-Object System.IO.Pipes.NamedPipeClientStream(
    '.', $PipeName,
    [System.IO.Pipes.PipeDirection]::In,
    [System.IO.Pipes.PipeOptions]::None
)
try {
    $client.Connect(2000)
} catch {
    Write-Error "connect to \\.\pipe\$PipeName failed: $($_.Exception.Message)"
    exit 1
}
Write-Host "connected to \\.\pipe\$PipeName; reading ${Seconds}s -> $OutFile"

if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
$fs = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
$buf = New-Object byte[] 4096
$deadline = (Get-Date).AddSeconds($Seconds)
$total = 0
try {
    while ((Get-Date) -lt $deadline) {
        $n = $client.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $fs.Write($buf, 0, $n); $total += $n
    }
} finally {
    $fs.Dispose(); $client.Dispose()
}
$expected = $Seconds * 16000 * 2
Write-Host ("read {0} bytes ({1:N1}% of expected {2})" -f $total, ($total * 100.0 / $expected), $expected)
