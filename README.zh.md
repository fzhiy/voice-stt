# ASR Anywhere

> *原名 `voice-stt`。Repo URL / install dir / 内部 identifier 仍用旧名,
> 等 Phase 2 整改一次到位 —— 见 [TODO_RENAME.md](TODO_RENAME.md)。*

**(简体中文 | [English](./README.md))**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-v0.1.3-green.svg)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2B%20%7C%20iOS-blue.svg)](#安装)

> **自托管实时 ASR 服务,可从 Windows 任何应用或 iPhone**(通过
> [HappyCoder](https://github.com/slopus/happy))**直接调用**,Mac/Android
> 等平台只需写客户端即可接入。按住热键说话,实时 partial 字幕,松开粘贴。
> **可插拔 ASR 后端** —— 自托管(FunASR Paraformer 流式 + Qwen3-ASR-1.7B
> + trie 热词偏置,12 GB 消费级 GPU),或指向云端(火山豆包 / 腾讯云 / 讯飞
> / OpenAI 兼容)。默认零云依赖。
>
> **当前已上线客户端**:Windows(AHK + PowerShell)· iOS(HappyCoder)。
> **服务端**:任意 Linux + NVIDIA GPU;客户端只需会发 WebSocket + 16 kHz
> PCM,**服务端不识别客户端类型**(纯 ASR backend,平台中性)。

```
Shift+Alt+S  →  按住说话, 松开粘贴  (流式 + 实时预览)
Shift+Alt+E  →  切换 ASR 后端 (本地 Qwen3 / 云端 provider)
Shift+Alt+V  →  批量 PTT (WAV 上传到 Whisper 兼容网关)
Shift+Alt+P  →  朗读选中文本 (SAPI TTS, 零延迟)
```

> 完整功能、架构图、roadmap 见 **[英文 README](./README.md)**。中文版只保留
> 安装 + 上手 + 中文用户最关心的词汇/历史部分。

---

## ✨ 特性

- **双引擎 ASR** — Paraformer 流式 `~300ms` 出 partial 实时字幕; Qwen3-ASR-1.7B
  在松开后 `~1s` 出最终高准确度文本
- **可插拔后端** — 一个 `ASRProvider` 抽象基类, 自托管 (FunASR + Qwen3-ASR,
  sherpa-onnx CPU) 和云端 (火山豆包 / 腾讯云 / 讯飞) 同协议, `Shift+Alt+E`
  一键切换。详见 [docs/PROVIDERS.md](docs/PROVIDERS.md)
- **暖捕获 mic** 含 `~300ms` 前置缓冲, 不吞首字
- **Hotwords 自动学习** — `≥ 3 次/30 天` 的纠正自动写进 `hotwords.yaml`
- **本地恢复日志** — 每次听写写一行 JSONL, `transcript-grep.sh` 帮你找回; 转写
  文本同时留在剪贴板, 焦点漂走也能手动 Ctrl+V 重贴
- **默认自托管** — 本地路径零云依赖, 音频不离开你的网络

---

## 🏗 架构

按住 Shift+Alt+S → AHK 通过 WebSocket 推 PCM 到 GPU host → Paraformer 出
流式 partial → 松开后 Qwen3-ASR 跑完整音频出 final → 粘贴到松开瞬间的窗口。

完整 mermaid sequence diagram + 角色分工 + 安全边界见
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**。

---

## 🚀 安装

**前置:** Windows 10+, PowerShell 5.1+, `ffmpeg` 在 PATH 里
(`winget install --id Gyan.FFmpeg -e`)。AutoHotkey v2 由 `install.bat` 自动
装; portable mode 需要你自己装一次。

下载 [最新 release ZIP](../../releases/latest) (`voice-stt.zip`), 解压到任
意位置, 双击下面其中之一:

| 模式 | 文件 | 干什么 |
|---|---|---|
| **安装** (开机自启) | `install.bat` | 没 AHK 就下载 → 拷脚本到 `%LOCALAPPDATA%\voice-stt\` → 生成 `.env` → 注册 Startup 快捷方式 |
| **便携** (不安装) | `start.bat` | 从解压目录读 `.env` → 启动 `voice-hotkey.ahk`。AHK v2 需预装 |
| **开发** (从 git) | `git clone … && .\install.ps1` | 跟"安装"模式一样, 从工作副本起 |

> **SmartScreen 警告**: 点 **More info → Run anyway**。脚本都是开源的, 不
> 放心可以自己看 `install.ps1`。

便携模式需自己装 AHK v2: 从 [autohotkey.com](https://www.autohotkey.com)
下载, 把 `AutoHotkey64.exe` 放到
`%LOCALAPPDATA%\Programs\AutoHotkey\v2\`。嫌麻烦直接用 `install.bat`。

---

## ⚡ 5 分钟上手

完整流程在 **[docs/QUICKSTART.md](docs/QUICKSTART.md)**。最小 `.env`:

```ini
ASR_WS_URL=ws://192.168.1.50:8082/    # 你的 FunASR server
RECORD_DEVICE_NAME=Microphone Array   # 用 record.ps1 -Diagnose 查
```

---

## 📝 词汇管理

`server/hotwords.yaml` 是 voice-stt 的词汇核心, 三层控制:

| 层 | 在哪 | 作用 |
|---|---|---|
| **Hotwords** (术语列表) | `hotwords.yaml` 各分类 (`ai_agent:` 等) | bias Qwen3-ASR 的 system context + Paraformer hotword boost |
| **Mappings** (post-correct) | `hotwords.yaml` `mappings:` 段 | 终态文本上的 LHS → RHS 确定性替换, 修同音字 (例: `"queen 3": "Qwen3"`) |
| **Snippets** | `hotwords.yaml` `snippets:` 段 | 口语简写扩展 (例: 说 `my email` → 完整邮箱) |

**自动晋升:** 网关 `/v1/text/learn` 端点从历史里挖 (wrong, right) 对。30 天
内出现 `≥ 3` 次的会自动追加到 `hotwords.yaml` 的 `auto_promoted:` 段 (日上
限 5 防失控)。审计日志在 `hotwords-auto-promoted.jsonl`。

WSL 助手脚本 (在 `wsl/`):
- `add-hotword.sh` — 交互式添加 + 原子 SCP + server reload
- `learn-review.sh` — 看积累的 (wrong, right) 候选
- `vocab-sync.sh` — 手动原子部署 `hotwords.yaml`

热更新: server 监听 mtime 自动 reload, 也支持 `SIGUSR1` /
`POST /v1/vocab/reload` 显式触发, 不用重启。

---

## 🗂 历史与恢复

每次听写 (`ok` / `empty` / `no_out` 等) 追加一行 JSONL 到:

```
%LOCALAPPDATA%\voice-stt\transcripts\YYYY-MM.jsonl
```

纯本地, 不上传, 月轮换。四个听写热键均写此文件。用 `wsl/transcript-grep.sh` 搜:

```bash
./wsl/transcript-grep.sh --since 1h --grep "embedding"
./wsl/transcript-grep.sh --last 20 --status ok
```

支持 `--last N`, `--since 1h|30m|2d`, `--grep <模式>`,
`--status <ok|empty|no_out|...>`, 加 `--raw` 看完整 JSON。

如果文本贴错窗口 (例如长录音中焦点漂走), **文本不丢** — 从 JSONL `--grep`
出来手动重粘。

---

## ⚙️ 详细配置

所有选项在 `.env` 里 (`install.bat` 会从 `.env.example` 生成)。每个变量的
默认值和"什么时候改"指南见 **[docs/CONFIG.md](docs/CONFIG.md)**。

---

## 🖥 ASR 后端

**自托管(默认)。** 完整 GPU server 部署见
**[server/README.md](server/README.md)**: vLLM 加载 Qwen3-ASR (默认 0.6B,
≥ 12 GB FP8 卡如 RTX 4070 Ti 可上 1.7B preset) + FunASR Paraformer + 可选
Whisper 批量路径; 另有零 GPU 的 sherpa-onnx CPU 路径。含各级消费卡 VRAM
调参矩阵 + CUDA 路径排障。

**云端。** provider 矩阵 + 各家配置见 **[docs/PROVIDERS.md](docs/PROVIDERS.md)**
(火山豆包 / 腾讯云 / 讯飞), 含跨境计费坑提醒。每个 provider 是一个独立的
`*-stream-server.py`, 实现 `server/asr_common.py` 的 `ASRProvider` 抽象基类
—— 自己加一家就一个文件。`Shift+Alt+E` 运行时切换 (选择跨重启保留)。

---

## 🗺 Roadmap

**v0.1 之后已实现**(已进代码库): 可插拔 `ASRProvider` 抽象基类; 云端
provider 火山豆包 / 腾讯云 / 讯飞; 零 GPU 的 sherpa-onnx CPU 路径;
`Shift+Alt+E` 后端切换; OpenAI 兼容 Bearer ASR provider(后端轮换里的
`openai-compat` 槽); 网关后处理模式 `strict_correction`(只修同音字/术语,
不改语气); custom 模式的 prompt 变量 `{text}` / `{selected}` / `{clipboard}`。

**下一步、未实现**(参考 [joewongjc/type4me](https://github.com/joewongjc/type4me)
的功能集):

- **AI agent 管词汇** —— 你说「Qwen3.5 被识别成 Queen 3.5」, 一个编码
  agent(比如一个 Claude Code skill, 本仓库未自带)自动推 3-8 个谐音变体
  写进 `hotwords.yaml` `mappings:` 段, 再用现有 `add-hotword.sh` 部署。
  把手写 YAML 包成自然语言。
- **分模式热键** —— 网关已经实现 polish / translate / prompt-optimize /
  custom 后处理模式, 计划用 `Shift+Alt+1/2/3` 暴露, 免去改 `.env`。
- **历史 CSV 导出** —— 恢复日志已是 JSONL, 补一个导出便于表格审阅。
- **Windows 侧抓选区 for `{selected}`** —— 服务器端变量替换 v0.1.1 已上线,
  但 AHK 通过 Ctrl+C 抓当前选区并透传过去这部分仍待做。
- **语音命令**(撤销 / 换段)—— 探索中, 跟模型内 self-correction 权衡。
- **Demo GIF / 录屏** —— 长期待办。

完整讨论见 [docs/ARCHITECTURE.md § What's NOT in v0.1](docs/ARCHITECTURE.md#whats-not-in-v01-and-v02-plans)。

---

## 🤔 为什么做这个

桌面端听写工具要么 macOS only (Wispr Flow, Aqua), 要么云端订阅, 要么 IME
模式 (讯飞) 而不是 paste-anywhere。voice-stt 填这个空缺: **Windows + WSL
按住说话 + 自托管 GPU ASR**, 双引擎兼顾 `~300ms` 实时预览和 `~1s` 终态准
确度, hotwords/历史/恢复日志完全自己拥有, 默认零云依赖。

为单一用户 (维护者本人) 优化, 每天用它往 Claude Code / Codex / Cursor 终端
里听写, 高频出现 Tailscale / Qwen3-ASR / embedding 这类技术词, 通用 ASR
听不准。如果你也是这个场景, 应该比较合适。

---

## 🙏 致谢

依赖:
- [FunASR](https://github.com/modelscope/FunASR) — Paraformer 流式 ASR
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) — final-pass ASR (Qwen 团队)
- [vLLM](https://github.com/vllm-project/vllm) — GPU 推理 runtime
- [OpenAI Whisper](https://github.com/openai/whisper) — 批量后端
- [AutoHotkey v2](https://www.autohotkey.com) — Windows 热键 + UI 层

完整 license 见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

---

## 📜 License

[MIT](LICENSE)。欢迎贡献 — 见 [CONTRIBUTING.md](CONTRIBUTING.md) 和
[SECURITY.md](SECURITY.md)。
