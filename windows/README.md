# Windows 录音端

为什么需要这块：**WSL2 没有原生音频设备**，必须借 Windows 主机录音。

## 文件清单

| 文件 | 作用 |
|---|---|
| `record.ps1` | 纯录音，winmm.dll 零依赖，输出 16kHz/16-bit/mono WAV |
| `voice-input.ps1` | 录音 + POST Whisper Gateway + 写剪贴板 |
| `config.example.ps1` | 环境变量模板 |

## 零依赖说明

用 Windows 原生 `winmm.dll`（`mciSendString`），**不需要装 NAudio、ffmpeg、Python 或任何第三方组件**。Win10/11 都自带。

## 单机测试（在 Windows PowerShell 里跑）

```powershell
# 1. 进入项目录（替换 <WSL_DISTRO> 和 <WSL_USER> 为你自己的）
cd \\wsl.localhost\<WSL_DISTRO>\home\<WSL_USER>\voice-stt\windows
# 或从 WSL 路径运行：powershell.exe -File "$(wslpath -w voice-input.ps1)"

# 2. 配 Gateway 地址（Tailscale 名或 IP）
$env:GATEWAY_URL = 'http://gpu-tower:8080'

# 3. 录 5 秒中文测试
.\voice-input.ps1 -Duration 5
```

输出：
```
Recording for 5 seconds...
Saved: C:\Users\<USERNAME>\AppData\Local\Temp\voice-stt-input-1234.wav (160044 bytes)
Transcribing via http://gpu-tower:8080/v1/audio/transcriptions ...
你好世界这是一个测试
(copied to clipboard, 11 chars)
```

## 交互式录音（按回车开始 / 停止）

```powershell
.\voice-input.ps1 -Interactive
```

适合长内容：开始录 → 想完一句话 → 按回车结束。

## 常见问题

### 提示"无法加载文件，因为在此系统上禁止运行脚本"
PowerShell 默认禁止脚本。两种解法：
1. 单次：`powershell.exe -ExecutionPolicy Bypass -File voice-input.ps1`
2. 永久：以管理员开 PowerShell 跑 `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

### 录到的是静音
- 麦克风权限：Windows 设置 → 隐私 → 麦克风 → 允许应用访问 → PowerShell 打开
- 默认录音设备：声音设置 → 输入设备 选对

### 中文识别成乱码
WSL 端用 `iconv` 转 UTF-8，或在 PowerShell 输出前：
```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
```
（WSL 桥接脚本 `wsl/voice-input.sh` 已经处理）
