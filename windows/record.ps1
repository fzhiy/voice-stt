# Windows 录音脚本
# 三条录音路径，按推荐顺序：
#   - 默认：自动检测 ffmpeg；有就走 dshow（无 80KB 限制，最稳）
#   - -UseWaveIn：waveInOpen 直接 P/Invoke（实测在 Win11 winmm bridge 有 ~80KB 上限）
#   - -UseMci：老 MCI mciSendString（老 API，对蓝牙/某些驱动不稳，仅 debug 用）
# 用法：
#   .\record.ps1 -Duration 5                              # 自动用 ffmpeg
#   .\record.ps1 -Diagnose                                # 列设备 + dshow 设备名
#   .\record.ps1 -DeviceName "麦克风阵列 (<mic-vendor>(R) Audio)" -Duration 5
#   .\record.ps1 -UseWaveIn -DeviceId 0 -Duration 3       # 强制走 waveIn 路径

[CmdletBinding()]
param(
    [int]$Duration = 0,
    [string]$OutputPath = "$env:TEMP\voice-stt-default.wav",
    [switch]$Diagnose,
    [switch]$NoSetFormat,
    [switch]$UseWaveIn,
    [switch]$UseMci,
    [int]$DeviceId = -1,         # waveIn 路径用：-1 = WAVE_MAPPER
    [string]$DeviceName = "",    # ffmpeg 路径用：dshow 设备 friendly name
    [int]$Rate = 16000,
    [int]$Channels = 1,
    [int]$Bits = 16,
    # 录音预热：某些 driver 启动后前 N 秒输出 0 字节（仅 waveIn 路径有意义）
    [double]$WarmupSec = 0,
    # ffmpeg 路径：选哪个输入声道做单声道源
    # left = 只留左声道（Lenovo your laptop 这类右声道坏的机器必选）
    # right / mix / auto
    [string]$MicChannel = 'left',
    # PTT 模式：给出此路径就用"按住录音、信号文件出现即停"模式（无 -t）
    # 仅 ffmpeg 路径支持。waveIn/MCI 路径不支持。
    [string]$StopSignalPath = ""
)

# === Win32 API ===
# sentinel 用最新加入的 WaveIn 类：如果脚本扩展了 C# 部分，老 session 缓存的 VoiceInput.Mci
# 会让守卫错误地跳过 Add-Type，新类永远不注册。下面 try/catch 会给出清晰提示。
if (-not ('VoiceInput.WaveIn' -as [type])) {
try {
Add-Type -ErrorAction Stop @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace VoiceInput {

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct WAVEINCAPS {
        public ushort wMid;
        public ushort wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]
        public string szPname;
        public uint dwFormats;
        public ushort wChannels;
        public ushort wReserved1;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WAVEFORMATEX {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WAVEHDR {
        public IntPtr lpData;
        public uint dwBufferLength;
        public uint dwBytesRecorded;
        public IntPtr dwUser;
        public uint dwFlags;
        public uint dwLoops;
        public IntPtr lpNext;
        public IntPtr reserved;
    }

    public class Mci {
        [DllImport("winmm.dll", CharSet=CharSet.Unicode)]
        public static extern int mciSendStringW(string command, StringBuilder buffer, int bufferSize, IntPtr hwndCallback);

        [DllImport("winmm.dll", CharSet=CharSet.Unicode)]
        public static extern int mciGetErrorStringW(int errCode, StringBuilder buffer, int bufferSize);

        [DllImport("winmm.dll")]
        public static extern uint waveInGetNumDevs();

        [DllImport("winmm.dll", CharSet=CharSet.Unicode)]
        public static extern int waveInGetDevCapsW(IntPtr uDeviceID, out WAVEINCAPS pwic, int cbwic);

        public static int Send(string cmd, out string reply) {
            var sb = new StringBuilder(512);
            int rc = mciSendStringW(cmd, sb, sb.Capacity, IntPtr.Zero);
            reply = sb.ToString();
            return rc;
        }

        public static string GetErrorString(int code) {
            var sb = new StringBuilder(256);
            if (mciGetErrorStringW(code, sb, sb.Capacity) != 0)
                return sb.ToString();
            return "";
        }
    }

    public class WaveIn {
        const ushort WAVE_FORMAT_PCM = 1;
        const uint   CALLBACK_NULL   = 0;
        const uint   WHDR_DONE       = 0x00000001;

        [DllImport("winmm.dll")] static extern int waveInOpen(out IntPtr phwi, int uDeviceID, ref WAVEFORMATEX pwfx, IntPtr cb, IntPtr inst, uint fdwOpen);
        [DllImport("winmm.dll")] static extern int waveInPrepareHeader(IntPtr hwi, IntPtr pwh, int cbwh);
        [DllImport("winmm.dll")] static extern int waveInAddBuffer(IntPtr hwi, IntPtr pwh, int cbwh);
        [DllImport("winmm.dll")] static extern int waveInStart(IntPtr hwi);
        [DllImport("winmm.dll")] static extern int waveInStop(IntPtr hwi);
        [DllImport("winmm.dll")] static extern int waveInReset(IntPtr hwi);
        [DllImport("winmm.dll")] static extern int waveInUnprepareHeader(IntPtr hwi, IntPtr pwh, int cbwh);
        [DllImport("winmm.dll")] static extern int waveInClose(IntPtr hwi);
        [DllImport("winmm.dll", CharSet=CharSet.Unicode)] static extern int waveInGetErrorTextW(int err, StringBuilder pszText, int cchText);

        public static string GetErrorText(int err) {
            var sb = new StringBuilder(256);
            if (waveInGetErrorTextW(err, sb, sb.Capacity) == 0) return sb.ToString();
            return "";
        }

        public class Result {
            public byte[] Data;
            public int ErrorCode;
            public string Stage;       // which API failed
            public string ErrorText;
            public string[] Timeline;  // diagnostic: per-tick byte counts
        }

        public static int Probe() { return 1; }   // 让 sentinel 容易匹配的标记方法

        // Multi-buffer 实现：把录音切成 N 个 chunk（每个 chunkMs 长），
        // 全部 AddBuffer 入队，driver 完成一个就标记 WHDR_DONE。
        // Stop 后扫描所有 buffer 的 dwBytesRecorded，拼成完整 PCM。
        // 对 <mic-vendor>/AudioEngine 类启动延迟、throughput 抖动远比单 buffer 鲁棒。
        public static Result Record(int deviceId, uint rate, ushort channels, ushort bits, double seconds) {
            return Record(deviceId, rate, channels, bits, seconds, 0.0);
        }

        public static Result Record(int deviceId, uint rate, ushort channels, ushort bits, double seconds, double warmupSec) {
            var r = new Result();

            var fmt = new WAVEFORMATEX();
            fmt.wFormatTag      = WAVE_FORMAT_PCM;
            fmt.nChannels       = channels;
            fmt.nSamplesPerSec  = rate;
            fmt.wBitsPerSample  = bits;
            fmt.cbSize          = 0;
            fmt.nBlockAlign     = (ushort)(fmt.nChannels * (fmt.wBitsPerSample / 8));
            fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;

            // chunk = 250ms；总时长 = warmup + seconds + 1.5s slack
            int chunkMs = 250;
            int chunkBytes = (int)((long)fmt.nAvgBytesPerSec * chunkMs / 1000);
            if (chunkBytes % fmt.nBlockAlign != 0)
                chunkBytes += fmt.nBlockAlign - (chunkBytes % fmt.nBlockAlign);
            double effSeconds = seconds + (warmupSec > 0 ? warmupSec : 0.0);
            double totalMs = effSeconds * 1000.0 + 1500.0;
            int numChunks = (int)Math.Ceiling(totalMs / chunkMs);
            if (numChunks < 4) numChunks = 4;

            byte[][] buffers   = new byte[numChunks][];
            GCHandle[] bufGchs = new GCHandle[numChunks];
            IntPtr[]  hdrPtrs  = new IntPtr[numChunks];
            int hdrSize = Marshal.SizeOf(typeof(WAVEHDR));

            for (int i = 0; i < numChunks; i++) {
                buffers[i] = new byte[chunkBytes];
                bufGchs[i] = GCHandle.Alloc(buffers[i], GCHandleType.Pinned);
                hdrPtrs[i] = Marshal.AllocHGlobal(hdrSize);
                var h = new WAVEHDR();
                h.lpData = bufGchs[i].AddrOfPinnedObject();
                h.dwBufferLength = (uint)chunkBytes;
                h.dwFlags = 0;
                Marshal.StructureToPtr(h, hdrPtrs[i], false);
            }

            IntPtr hwi = IntPtr.Zero;
            try {
                int rc = waveInOpen(out hwi, deviceId, ref fmt, IntPtr.Zero, IntPtr.Zero, CALLBACK_NULL);
                if (rc != 0) {
                    r.ErrorCode = rc; r.Stage = "waveInOpen"; r.ErrorText = GetErrorText(rc);
                    return r;
                }

                for (int i = 0; i < numChunks; i++) {
                    rc = waveInPrepareHeader(hwi, hdrPtrs[i], hdrSize);
                    if (rc != 0) { r.ErrorCode = rc; r.Stage = "waveInPrepareHeader[" + i + "]"; r.ErrorText = GetErrorText(rc); waveInClose(hwi); return r; }
                    rc = waveInAddBuffer(hwi, hdrPtrs[i], hdrSize);
                    if (rc != 0) { r.ErrorCode = rc; r.Stage = "waveInAddBuffer[" + i + "]"; r.ErrorText = GetErrorText(rc); waveInClose(hwi); return r; }
                }

                rc = waveInStart(hwi);
                if (rc != 0) { r.ErrorCode = rc; r.Stage = "waveInStart"; r.ErrorText = GetErrorText(rc); waveInClose(hwi); return r; }

                // 实时 collect + recycle: driver 填满一个 chunk 后立即收数据 +
                // Unprepare/Prepare/AddBuffer 同一 buffer 让 driver queue 不空。
                // 不 recycle 的话某些 driver（<mic-vendor> 这台）在 ~10 个 buffer in-flight
                // 后就 throttle 写入 ≈ 0。
                int waitMs = (int)(effSeconds * 1000.0) + 1000;
                int targetTotal = (int)(fmt.nAvgBytesPerSec * effSeconds);
                int elapsed = 0;
                int collectedBytes = 0;
                var collected = new List<byte[]>();
                var timeline = new List<string>();
                int nextTickAt = 500;

                while (elapsed < waitMs && collectedBytes < targetTotal) {
                    Thread.Sleep(50);
                    elapsed += 50;
                    for (int i = 0; i < numChunks; i++) {
                        var h2 = (WAVEHDR)Marshal.PtrToStructure(hdrPtrs[i], typeof(WAVEHDR));
                        if ((h2.dwFlags & WHDR_DONE) != 0) {
                            int br = (int)h2.dwBytesRecorded;
                            if (br > 0) {
                                byte[] c = new byte[br];
                                Array.Copy(buffers[i], 0, c, 0, br);
                                collected.Add(c);
                                collectedBytes += br;
                            }
                            // recycle 这个 buffer
                            waveInUnprepareHeader(hwi, hdrPtrs[i], hdrSize);
                            var fresh = new WAVEHDR();
                            fresh.lpData = bufGchs[i].AddrOfPinnedObject();
                            fresh.dwBufferLength = (uint)chunkBytes;
                            fresh.dwFlags = 0;
                            Marshal.StructureToPtr(fresh, hdrPtrs[i], false);
                            waveInPrepareHeader(hwi, hdrPtrs[i], hdrSize);
                            waveInAddBuffer(hwi, hdrPtrs[i], hdrSize);
                        }
                    }
                    if (elapsed >= nextTickAt) {
                        timeline.Add(string.Format("  t={0,5}ms  collected={1,7}  chunks_recycled={2}", elapsed, collectedBytes, collected.Count));
                        nextTickAt += 500;
                    }
                }

                waveInStop(hwi);
                Thread.Sleep(200);

                // 收 stop 后残留的 done/partial buffer
                for (int i = 0; i < numChunks; i++) {
                    var h2 = (WAVEHDR)Marshal.PtrToStructure(hdrPtrs[i], typeof(WAVEHDR));
                    int br = (int)h2.dwBytesRecorded;
                    if (br > 0 && (h2.dwFlags & WHDR_DONE) != 0) {
                        byte[] c = new byte[br];
                        Array.Copy(buffers[i], 0, c, 0, br);
                        collected.Add(c);
                        collectedBytes += br;
                    }
                    waveInUnprepareHeader(hwi, hdrPtrs[i], hdrSize);
                }
                timeline.Add(string.Format("  [final] collected={0}  chunks={1}", collectedBytes, collected.Count));
                r.Timeline = timeline.ToArray();
                waveInClose(hwi);

                // 拼接所有 collected 数据
                byte[] raw = new byte[collectedBytes];
                int off = 0;
                foreach (var c in collected) {
                    Array.Copy(c, 0, raw, off, c.Length);
                    off += c.Length;
                }

                // 丢 warmup 头 + 截到 target 长度
                int warmupBytes = (int)(fmt.nAvgBytesPerSec * (warmupSec > 0 ? warmupSec : 0.0));
                if (warmupBytes % fmt.nBlockAlign != 0)
                    warmupBytes -= warmupBytes % fmt.nBlockAlign;
                int targetBytes = (int)(fmt.nAvgBytesPerSec * seconds);
                int start = Math.Min(warmupBytes, collectedBytes);
                int len = Math.Min(targetBytes, collectedBytes - start);
                if (len < 0) len = 0;
                byte[] data = new byte[len];
                if (len > 0) Array.Copy(raw, start, data, 0, len);
                r.Data = data;
                return r;
            } finally {
                for (int i = 0; i < numChunks; i++) {
                    if (hdrPtrs[i] != IntPtr.Zero) Marshal.FreeHGlobal(hdrPtrs[i]);
                    if (bufGchs[i].IsAllocated)    bufGchs[i].Free();
                }
            }
        }
    }
}
'@
} catch {
    if ($_.Exception.Message -match 'already exists') {
        Write-Error "VoiceInput 类型在当前 PowerShell 进程已加载旧版本（不含 WaveIn）。请关掉这个 PowerShell 窗口重开一个再跑——.NET 不允许在同 session 卸载/替换 type。"
        exit 6
    }
    throw
}
}

# MCI 错误码 -> 名字（mciGetErrorString 已经给可读消息；这里只为日志里显示常量名）
$MciErrName = @{
    257 = 'MCIERR_INVALID_DEVICE_ID'
    263 = 'MCIERR_INVALID_DEVICE_NAME'
    265 = 'MCIERR_DEVICE_OPEN'
    266 = 'MCIERR_CANNOT_LOAD_DRIVER'
    276 = 'MCIERR_DEVICE_NOT_READY'
    277 = 'MCIERR_INTERNAL'
    282 = 'MCIERR_OUTOFRANGE'
    288 = 'MCIERR_DEVICE_LOCKED'
    289 = 'MCIERR_DUPLICATE_ALIAS'
    297 = 'MCIERR_NULL_PARAMETER_BLOCK'
    320 = 'MCIERR_WAVE_OUTPUTSINUSE'
    322 = 'MCIERR_WAVE_INPUTSINUSE'
    325 = 'MCIERR_WAVE_INPUTUNSPECIFIED'
    328 = 'MCIERR_WAVE_INPUTSUNSUITABLE'
}

function Format-MciError {
    param([int]$Code, [string]$Cmd, [string]$Reply)
    $name = $MciErrName[$Code]
    $sys  = [VoiceInput.Mci]::GetErrorString($Code)
    $parts = @("MCI($Code)")
    if ($name) { $parts += $name }
    if ($sys)  { $parts += "`"$sys`"" }
    $msg = ($parts -join ' ') + " | cmd=$Cmd"
    if ($Reply) { $msg += " | reply=$Reply" }
    return $msg
}

function Invoke-Mci {
    param([string]$Cmd, [switch]$Quiet)
    $reply = ''
    $code = [VoiceInput.Mci]::Send($Cmd, [ref]$reply)
    if ($code -ne 0 -and -not $Quiet) {
        Write-Error (Format-MciError -Code $code -Cmd $Cmd -Reply $reply)
    }
    return $code
}

function Show-WaveInputDevices {
    $n = [VoiceInput.Mci]::waveInGetNumDevs()
    Write-Host "waveInGetNumDevs() = $n"
    if ($n -eq 0) {
        Write-Warning "Windows 看不到任何录音设备。检查麦克风是否插入、Windows 设置 -> 隐私 -> 麦克风 -> 桌面应用是否允许"
        return
    }
    for ($i = 0; $i -lt $n; $i++) {
        $caps = New-Object VoiceInput.WAVEINCAPS
        $size = [System.Runtime.InteropServices.Marshal]::SizeOf($caps)
        $rc = [VoiceInput.Mci]::waveInGetDevCapsW([IntPtr]$i, [ref]$caps, $size)
        if ($rc -eq 0) {
            Write-Host ("  [{0}] {1}  channels={2}" -f $i, $caps.szPname.Trim(), $caps.wChannels)
        } else {
            Write-Host "  [$i] (waveInGetDevCaps rc=$rc)"
        }
    }
}

function Write-Status {
    # 录音过程中所有状态行用这个：直接写 stderr，stdout 留给最终输出
    param([string]$Msg)
    [Console]::Error.WriteLine($Msg)
}

function Find-Ffmpeg {
    # 返回 ffmpeg.exe 全路径，没找到返回 $null
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # winget Gyan.FFmpeg 通常装在用户级 WindowsApps
    $guesses = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe",
        "C:\ProgramData\chocolatey\bin\ffmpeg.exe",
        "C:\ffmpeg\bin\ffmpeg.exe"
    )
    foreach ($g in $guesses) { if (Test-Path $g) { return $g } }
    return $null
}

function Show-DshowDevices {
    param([string]$FfmpegPath)
    Write-Host "ffmpeg dshow 设备列表（录音用 audio name）："
    # ffmpeg -list_devices 把 device list 写到 stderr
    $tmp = "$env:TEMP\ffmpeg-devices-$PID.txt"
    & $FfmpegPath -hide_banner -f dshow -list_devices true -i dummy 2>$tmp 1>$null
    $lines = Get-Content $tmp -Encoding UTF8 -ErrorAction SilentlyContinue
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if (-not $lines) { Write-Host "  (无输出)"; return }
    $inAudio = $false
    foreach ($line in $lines) {
        if ($line -match 'DirectShow audio devices') { $inAudio = $true; continue }
        if ($line -match 'DirectShow video devices') { $inAudio = $false; continue }
        if ($inAudio -and $line -match '"([^"]+)"') {
            Write-Host ("  audio: `"{0}`"" -f $Matches[1])
        }
    }
}

function Invoke-FfmpegRecord {
    param(
        [string]$FfmpegPath,
        [string]$DeviceName,
        [int]$Duration,
        [int]$Rate,
        [int]$Channels,
        [int]$Bits,
        [string]$OutputPath,
        # MicChannel: 'left' | 'right' | 'mix' | 'auto'
        #   left  - 强制 stereo 48k 输入 + 只留左声道（your laptop / <mic-vendor> 右声道坏的机器必选）
        #   right - 只留右声道
        #   mix   - 默认 stereo mix（如果两声道都正常）
        #   auto  - 让 ffmpeg 自动选（最不稳）
        [string]$MicChannel = 'left',
        # PTT 模式：信号文件路径。给出后 ffmpeg 无 -t，靠 stdin 'q' 干净退出
        [string]$StopSignalPath = ""
    )
    if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }

    $pttMode = -not [string]::IsNullOrEmpty($StopSignalPath)

    # 选 audio filter chain
    # 顺序：声道选择 -> 带通 -> dynaudnorm。
    # silenceremove + areverse 组合在 ffmpeg 7 + dshow 实时流下会死锁（areverse
    # 需要完整 input EOF，dshow -t 完成后不发清晰 EOF）。靠 Whisper 自身的 VAD
    # 处理静音段，不在 ffmpeg 端 trim。
    $core = "highpass=f=80,lowpass=f=8000,dynaudnorm=f=150:g=8:p=0.9"
    $af = switch ($MicChannel) {
        'left'  { "pan=mono|c0=c0,$core" }
        'right' { "pan=mono|c0=c1,$core" }
        'mix'   { "pan=mono|c0=0.5*c0+0.5*c1,$core" }
        default { $core }
    }

    # 输入 stereo 48k 强制（DirectShow capture 默认格式，避开格式协商坑）
    $inChannels = if ($MicChannel -eq 'auto') { @() } else { @('-channels','2','-sample_rate','48000') }

    # PTT 模式去掉 -nostdin（要保留 stdin 给 'q'）和 -t（无固定时长）
    $stdinFlag = if ($pttMode) { @() } else { @('-nostdin') }
    $durationFlag = if ($pttMode) { @() } else { @('-t', "$Duration") }

    $args = @(
        '-hide_banner',
        '-loglevel', 'error',
        '-y',
        '-f', 'dshow'
    ) + $stdinFlag + $inChannels + @(
        '-i', "audio=$DeviceName"
    ) + $durationFlag + @(
        '-af', $af,
        '-ar', "$Rate",
        '-ac', "$Channels",
        '-c:a', 'pcm_s16le',
        $OutputPath
    )
    $stderrFile = "$env:TEMP\ffmpeg-rec-$PID.err"

    if ($pttMode) {
        Write-Status "[ffmpeg PTT] $DeviceName  channel=$MicChannel  out=${Rate}/${Bits}/${Channels}ch  signal=$StopSignalPath"
        # 信号文件如果已存在（上次残留）先删
        if (Test-Path $StopSignalPath) { Remove-Item $StopSignalPath -Force -ErrorAction SilentlyContinue }

        # [Diagnostics.Process] + stdin 写 'q' 让 ffmpeg 干净 finalize wav。
        # 关键：stderr 同步处理（WaitForExit 之后再 ReadToEnd），不挂异步事件。
        # PS 5.1 异步 ErrorDataReceived 历史上会 deadlock；同步读 + -loglevel error
        # 保证 stderr 体量极小，不会涨满 pipe buffer。
        # PS 5.1 / .NET Framework 4.x 没有 ProcessStartInfo.ArgumentList，
        # 必须用 Arguments 字符串。含空格/引号的参数要正确转义。
        $quoted = $args | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FfmpegPath
        $psi.Arguments = ($quoted -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)

        Write-Status "  ffmpeg PID=$($proc.Id)，等待 stop 信号文件..."
        # 轮询：信号文件出现 OR ffmpeg 自己崩了
        while (-not (Test-Path $StopSignalPath)) {
            if ($proc.HasExited) { break }
            Start-Sleep -Milliseconds 100
        }

        if (-not $proc.HasExited) {
            Write-Status "  收到 stop 信号，写 'q' 触发 ffmpeg finalize..."
            try {
                $proc.StandardInput.WriteLine('q')
                $proc.StandardInput.Flush()
                $proc.StandardInput.Close()
            } catch {
                Write-Status "  stdin 写入失败: $($_.Exception.Message)，回退 Stop-Process"
            }
            if (-not $proc.WaitForExit(5000)) {
                Write-Status "  ffmpeg 5s 未退出，强杀（WAV 可能损坏）"
                try { $proc.Kill() } catch {}
                $proc.WaitForExit(2000) | Out-Null
            }
        }

        $rc = $proc.ExitCode
        $stderrText = ''
        try { $stderrText = $proc.StandardError.ReadToEnd() } catch {}
        if ($stderrText) { Set-Content -Path $stderrFile -Value $stderrText -Encoding UTF8 }

        # 清理信号文件
        if (Test-Path $StopSignalPath) { Remove-Item $StopSignalPath -Force -ErrorAction SilentlyContinue }

        # ffmpeg 接收 'q' 后正常退出码是 255（用户中断）或 0。两者都视为成功，
        # 只要 WAV 文件生成且非空。
        if (-not (Test-Path $OutputPath)) {
            Write-Error "ffmpeg PTT 未生成 WAV 文件 (exit=$rc)`nstderr 文件: $stderrFile`n--- 内容 ---`n$stderrText"
            return $false
        }
        $sz = (Get-Item $OutputPath).Length
        if ($sz -le 44) {
            Write-Error "ffmpeg PTT 生成的 WAV 太小 ($sz bytes，按得太短？)`nstderr: $stderrText"
            return $false
        }
        Remove-Item $stderrFile -ErrorAction SilentlyContinue
        return $true
    }

    Write-Status "[ffmpeg] $DeviceName  channel=$MicChannel  out=${Rate}/${Bits}/${Channels}ch  duration=${Duration}s"
    # 注意：ffmpeg 7 + dshow 在 -t 完成后会 hang ~13s 才真正退出。整个 voice-input
    # 调用因此比 Duration 多 ~13s。已知问题。Kill 优化方案（PS Start-Job timer +
    # Stop-Process）会让 ffmpeg 来不及 finalize wav header → wav 0 字节。.NET
    # Process + 异步 stderr 事件在 PS 5.1 上 deadlock。当前接受 hang 延迟。
    # PTT 模式（StopSignalPath）走上面的 [Diagnostics.Process] 分支，避开 13s hang。
    & $FfmpegPath @args 2>$stderrFile
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        $errText = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
        # 失败时保留 stderr 文件供 debug，路径回写
        Write-Error "ffmpeg 退出码 $rc`nstderr 文件: $stderrFile`n--- 内容 ---`n$errText"
        return $false
    }
    Remove-Item $stderrFile -ErrorAction SilentlyContinue
    if (-not (Test-Path $OutputPath)) {
        Write-Error "ffmpeg 未生成 WAV 文件"
        return $false
    }
    return $true
}

# === Diagnose 模式 ===
if ($Diagnose) {
    Write-Host "=== record.ps1 诊断 ==="
    Write-Host "PowerShell : $($PSVersionTable.PSVersion)"
    Write-Host "Host       : $($Host.Name)"
    Write-Host "User       : $env:USERNAME"
    Write-Host "Session    : $env:SESSIONNAME"
    Write-Host ""
    Show-WaveInputDevices
    Write-Host ""
    $ff = Find-Ffmpeg
    if ($ff) {
        Write-Host "ffmpeg: $ff"
        Write-Host ""
        Show-DshowDevices -FfmpegPath $ff
    } else {
        Write-Host "ffmpeg: 未找到（推荐装：winget install --id Gyan.FFmpeg -e）"
    }
    Write-Host ""
    Write-Host "测试 MCI open/close（不录音）..."
    $reply = ''
    $rc = [VoiceInput.Mci]::Send('open new type waveaudio alias rectest', [ref]$reply)
    if ($rc -eq 0) {
        Write-Host "  open OK"
        $null = [VoiceInput.Mci]::Send('close rectest', [ref]$reply)
        Write-Host "  close OK"
    } else {
        Write-Host (Format-MciError -Code $rc -Cmd 'open new type waveaudio' -Reply $reply)
    }
    exit 0
}

# === 录音 ===
if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }

# 预检：有录音设备吗？
$nDev = [VoiceInput.Mci]::waveInGetNumDevs()
if ($nDev -eq 0) {
    Write-Error "没有可用的录音设备 (waveInGetNumDevs=0)。检查 Windows 设置 -> 隐私 -> 麦克风 -> 允许桌面应用访问"
    exit 2
}

function Write-WavFile {
    param(
        [string]$Path,
        [int]$Rate,
        [int]$Channels,
        [int]$Bits,
        [byte[]]$Data
    )
    $blockAlign = $Channels * ($Bits / 8)
    $byteRate   = $Rate * $blockAlign
    $dataSize   = $Data.Length
    $fileSize   = 36 + $dataSize

    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $bw.Write([byte[]]@(0x52,0x49,0x46,0x46))      # "RIFF"
        $bw.Write([uint32]$fileSize)
        $bw.Write([byte[]]@(0x57,0x41,0x56,0x45))      # "WAVE"
        $bw.Write([byte[]]@(0x66,0x6d,0x74,0x20))      # "fmt "
        $bw.Write([uint32]16)
        $bw.Write([uint16]1)                           # PCM
        $bw.Write([uint16]$Channels)
        $bw.Write([uint32]$Rate)
        $bw.Write([uint32]$byteRate)
        $bw.Write([uint16]$blockAlign)
        $bw.Write([uint16]$Bits)
        $bw.Write([byte[]]@(0x64,0x61,0x74,0x61))      # "data"
        $bw.Write([uint32]$dataSize)
        if ($dataSize -gt 0) { $bw.Write($Data) }
    } finally {
        $bw.Close()
        $fs.Close()
    }
}

# === ffmpeg dshow 路径（默认，最稳）===
# 选择规则：未显式指定 -UseWaveIn / -UseMci 时，且 ffmpeg 可用，且能解析出 DeviceName
$useFfmpegPath = $false
$ffmpegExe = $null
if (-not $UseWaveIn -and -not $UseMci) {
    $ffmpegExe = Find-Ffmpeg
    if ($ffmpegExe) { $useFfmpegPath = $true }
}

if ($useFfmpegPath) {
    if ($Duration -le 0 -and -not $StopSignalPath) {
        Write-Error "ffmpeg 路径必须给 -Duration N 或 -StopSignalPath <path>（PTT 模式）"
        exit 4
    }
    # 若没给 DeviceName，按 DeviceId 从 winmm 枚举映射出 winmm friendly name
    # （dshow 名字一般跟 winmm 一致；不一致就用 -Diagnose 看 dshow 列表，显式 -DeviceName 传）
    $devName = $DeviceName
    if (-not $devName) {
        $idx = if ($DeviceId -lt 0) { 0 } else { $DeviceId }
        $caps = New-Object VoiceInput.WAVEINCAPS
        $size = [System.Runtime.InteropServices.Marshal]::SizeOf($caps)
        $rc = [VoiceInput.Mci]::waveInGetDevCapsW([IntPtr]$idx, [ref]$caps, $size)
        if ($rc -eq 0) {
            $devName = $caps.szPname.Trim()
        } else {
            Write-Error "无法从 DeviceId=$DeviceId 拿到设备名，请用 -DeviceName 显式指定（-Diagnose 看 dshow 列表）"
            exit 7
        }
    }
    $ok = Invoke-FfmpegRecord -FfmpegPath $ffmpegExe -DeviceName $devName -Duration $Duration -Rate $Rate -Channels $Channels -Bits $Bits -OutputPath $OutputPath -MicChannel $MicChannel -StopSignalPath $StopSignalPath
    if (-not $ok) { exit 8 }
    $size = (Get-Item $OutputPath).Length
    $pcm  = [math]::Max(0, $size - 44)
    $bps  = $Rate * $Channels * ($Bits / 8)
    $sec  = if ($bps -gt 0) { [math]::Round($pcm / $bps, 2) } else { 0 }
    Write-Status "Saved: $OutputPath ($size bytes, ${pcm} PCM, ~${sec}s)"
    exit 0
}

# === waveInOpen 路径 ===
if ($UseWaveIn) {
    if ($Duration -le 0) {
        Write-Error "-UseWaveIn 模式必须给 -Duration N（waveInOpen 不支持交互式停止）"
        exit 4
    }
    $devLabel = if ($DeviceId -lt 0) { "WAVE_MAPPER" } else { "device #$DeviceId" }
    $warmMsg = if ($WarmupSec -gt 0) { " warmup=${WarmupSec}s" } else { "" }
    Write-Status "[WaveIn] $devLabel  format=${Rate}/${Bits}/${Channels}ch  duration=${Duration}s${warmMsg}"

    $res = [VoiceInput.WaveIn]::Record($DeviceId, [uint32]$Rate, [uint16]$Channels, [uint16]$Bits, [double]$Duration, [double]$WarmupSec)
    if ($res.ErrorCode -ne 0) {
        Write-Error ("waveIn {0} 失败 mmr={1} `"{2}`"" -f $res.Stage, $res.ErrorCode, $res.ErrorText)
        exit $res.ErrorCode
    }
    $n = $res.Data.Length
    if ($n -eq 0) {
        Write-Error "waveIn 没采到样本 (bytesRecorded=0)。可能是麦克风权限被拒、或设备 ID $DeviceId 不存在"
        if ($res.Timeline) {
            Write-Status "[Timeline]"
            $res.Timeline | ForEach-Object { Write-Status $_ }
        }
        exit 5
    }
    $expected = $Rate * $Channels * ($Bits / 8) * $Duration
    $actualSec = [math]::Round($n / ($Rate * $Channels * ($Bits/8)), 2)
    Write-WavFile -Path $OutputPath -Rate $Rate -Channels $Channels -Bits $Bits -Data $res.Data
    $size = (Get-Item $OutputPath).Length
    Write-Status "Saved: $OutputPath ($size bytes, ${n}/${expected} PCM, ~${actualSec}s)"
    if ($n -lt $expected * 0.9) {
        Write-Warning "录到的字节数明显少于期望（${actualSec}s vs ${Duration}s）"
        if ($res.Timeline) {
            Write-Status "[Timeline] driver 每 500ms 已写入字节："
            $res.Timeline | ForEach-Object { Write-Status $_ }
        }
    }
    exit 0
}

function Open-RecDevice {
    # 先 quiet close 一次，清掉同一 PS 进程里上一次失败残留的 alias
    $null = Invoke-Mci -Quiet 'close rec'

    $rc = Invoke-Mci 'open new type waveaudio alias rec'
    if ($rc -eq 289) {
        # MCIERR_DUPLICATE_ALIAS：close 没清掉（极少见），再试一次
        Write-Warning "MCI 289 (DUPLICATE_ALIAS)，强制重 close 后重试..."
        $null = Invoke-Mci -Quiet 'close rec'
        Start-Sleep -Milliseconds 200
        $rc = Invoke-Mci 'open new type waveaudio alias rec'
    }
    if ($rc -ne 0) { return $rc }

    if (-not $script:NoSetFormat) {
        foreach ($cmd in @(
            'set rec samplespersec 16000',
            'set rec bitspersample 16',
            'set rec channels 1',
            'set rec format tag pcm'
        )) {
            $rc = Invoke-Mci $cmd
            if ($rc -ne 0) {
                $null = Invoke-Mci -Quiet 'close rec'
                return $rc
            }
        }
    } else {
        Write-Status "[NoSetFormat] 跳过 PCM 格式设置，用驱动默认 format 录"
    }
    return 0
}

# 把 param 暴露给 Open-RecDevice
$script:NoSetFormat = $NoSetFormat

$rc = Open-RecDevice
if ($rc -ne 0) {
    if ($rc -eq 289) {
        Write-Status ""
        Write-Status "MCI 289 = alias 'rec' 在当前 PowerShell 进程残留，自动清理失败。"
        Write-Status "  最快解法：退出这个 PowerShell 窗口重开一个再跑"
    }
    exit $rc
}

$rc = Invoke-Mci 'record rec'
if ($rc -eq 322) {
    Write-Warning "录音设备忙 (MCI 322 = WAVE_INPUTSINUSE)，等 1.5s 后重试一次..."
    $null = Invoke-Mci -Quiet 'close rec'
    Start-Sleep -Milliseconds 1500
    $rc = Open-RecDevice
    if ($rc -eq 0) {
        $rc = Invoke-Mci 'record rec'
    }
}
if ($rc -ne 0) {
    if ($rc -eq 322) {
        Write-Status ""
        Write-Status "MCI 322 = 录音设备被占用。"
        Write-Status "  - 关掉占麦克风的应用：Teams、Zoom、Discord、浏览器（Google Meet/语音消息标签）"
        Write-Status "  - 任务管理器查 powershell.exe / pwsh.exe 是否还有上次残留实例"
        Write-Status "  - 再跑：.\record.ps1 -Diagnose"
    }
    $null = Invoke-Mci -Quiet 'close rec'
    exit $rc
}

try {
    if ($Duration -gt 0) {
        Write-Status "Recording for $Duration seconds..."
        Start-Sleep -Seconds $Duration
    } else {
        Write-Status "Recording... Press Enter to stop."
        [void][Console]::ReadLine()
    }
} finally {
    $null = Invoke-Mci -Quiet 'stop rec'
    $null = Invoke-Mci -Quiet "save rec `"$OutputPath`""
    $null = Invoke-Mci -Quiet 'close rec'
}

if (Test-Path $OutputPath) {
    $size = (Get-Item $OutputPath).Length
    Write-Status "Saved: $OutputPath ($size bytes)"
} else {
    Write-Error "Failed to save recording"
    exit 1
}
