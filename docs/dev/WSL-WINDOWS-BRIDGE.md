# WSL ↔ Windows 录音桥接细节

## 为什么这样设计

WSL2 默认没 `/dev/snd` PCM 设备（`ls /dev/snd` 只有 `timer`）。三种方案对比：

| 方案 | 复杂度 | 稳定性 | 选了它吗 |
|---|---|---|---|
| WSL 内装 PulseAudio + Windows 跑 server | 高（需配 PA cookies、防火墙）| 中（重启 WSL 常断）| ❌ |
| Windows PowerShell 录音 + WSL 桥接 | 低（零依赖） | 高 | ✓ |
| Windows 端跑全套（不用 WSL） | 低 | 高 | 备选 |

## 数据流细节

```
WSL: wsl/voice-input.sh
  └─ powershell.exe -File "$(wslpath -w windows/voice-input.ps1)" -NoClipboard ...
        │
        └─ Windows 进程被 wsl 的 init 派生
              │
              ├─ NAudio/MCI 录音 → %TEMP%\voice-input.wav
              ├─ curl.exe POST → http://gpu-tower:8080/v1/audio/transcriptions
              ├─ ConvertFrom-Json 取 .text
              ├─ Write-Output $text  ← 关键，走 stdout（WSL 端能 capture）
              └─ Write-Host $status   ← Write-Host 走 host stream，WSL 端不会接收
        ↓
WSL: 把 stdout 用 `tr -d '\r'` 去掉 CRLF → 输出给调用者
```

## 关键点：stdout vs Write-Host

PowerShell 有两种"输出"：
- `Write-Output $x` / 表达式直接放着 → **走 stdout**，会被 WSL 端的 `$(powershell.exe ...)` 抓到
- `Write-Host "log"` → 走"信息流"，控制台直接渲染，**不进 stdout**

我们利用这个机制：转写结果走 stdout（WSL 拿得到），状态行走 Write-Host（用户在终端能看到但不污染 pipeline）。

## 字符编码

PowerShell 默认 UTF-16，WSL 期望 UTF-8。`powershell.exe`（**不是 pwsh**）在 Windows 10/11 上输出 UTF-8 通常 OK，但偶尔会有 BOM 或 CRLF。

`wsl/lib.sh` 里用 `tr -d '\r'` 去 CRLF，UTF-8 直读。如有乱码：

```bash
# 在 voice-input.sh 里包一层
powershell.exe ... | iconv -f UTF-8 -t UTF-8 -c | tr -d '\r'
```

或在 PowerShell 脚本开头加：
```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
```

## 路径转换

WSL 路径 → Windows 路径：`wslpath -w $HOME/voice-stt/windows`
得到 `\\wsl.localhost\<WSL_DISTRO>\home\<WSL_USER>\voice-stt\windows`

PowerShell 完全能读 UNC 路径，无需复制到 Windows 本地盘。

## 实测延迟（参考）

| 阶段 | 耗时 |
|---|---|
| WSL fork powershell.exe | 50-150ms |
| MCI 录音启动 | <50ms |
| 上传 WAV (10s 音频 ≈ 320KB) | 50-200ms |
| Whisper Large-v3-turbo 转写 10s | 300-500ms (GPU) |
| 总延迟 | **~1 秒**（录完到看见文字） |
