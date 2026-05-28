# ASR Providers

> **Default path is self-hosted.** ASR Anywhere ships ready to run end-to-end
> against a local GPU (FunASR Paraformer + Qwen3-ASR-1.7B) — no cloud account
> required, no audio leaves your network. **The cloud providers below
> (Volcano / Tencent / 讯飞 / OpenAI-compat) are optional alternatives**, useful
> if you don't have a GPU or want a no-setup fallback. They are
> community-maintained: the maintainer's daily driver is self-hosted, so cloud
> backends are smoke-tested but receive less day-to-day validation.

ASR Anywhere's streaming path supports multiple ASR backends behind one wire
protocol. The Windows AHK client and the Happy iPhone client both send int16
PCM frames + `"EOF"` and expect `{type:partial|final}` JSON envelopes back —
which server handles those frames is selectable per-session.

This document covers:

- [What's available](#provider-matrix)
- [How to enable each](#provider-setup)
- [Cross-border caveats](#cross-border-billing-caveats) — especially relevant for users outside mainland China
- [Adding a new provider](#adding-a-new-provider)

For troubleshooting specific errors, see
[TROUBLESHOOTING.md § Cloud ASR providers](TROUBLESHOOTING.md#cloud-asr-providers).

## Provider Matrix

| Provider | Type | Streaming Partials | Free Tier | Cross-Border (海外 IP) | Auth Complexity |
|---|---|---|---|---|---|
| **Volcano 豆包 ASR 2.0** | Cloud (字节) | ✓ | 20 h / 6 months + 注册送 40 h | ✓ Free tier applies | Low (4 headers, no signing) |
| **Tencent ASR Realtime** | Cloud (腾讯) | ✓ | 5 h / month recurring | ⚠️ **Post-pay only, free tier does NOT apply** | Medium (HMAC-SHA1 signed URL) |
| **讯飞 RTASR** | Cloud (科大讯飞) | ✓ | 50 h / 1 year trial | ❓ Unverified — test before relying | Medium (HMAC-SHA1 signed URL) |
| **Qwen3-ASR (self-hosted)** | Local + cloud | ✓ | $0, unlimited | ✓ (via SSH tunnel / Tailscale) | None |
| **FunASR Paraformer (self-hosted)** | Local | ✓ | $0, unlimited | ✓ | None |
| **sherpa-onnx (self-hosted)** | Local (CPU) | ✓ | $0, unlimited | ✓ | None |

All providers expose the **same** WS endpoint contract — the Windows AHK
script and the Happy iPhone app speak this contract regardless of which
provider is on the other end. Switching backends does not require a client
rebuild; it only requires pointing the client at a different port.

## Provider Setup

Each cloud provider has a dedicated `*-stream-server.py` and a systemd user
unit at `~/.config/systemd/user/voice-stt-<name>.service`. Self-hosted
options live in `server/funasr-stream-server.py` and
`server/sherpa-onnx-stream-server.py` and run on the GPU host (see
[ARCHITECTURE.md](ARCHITECTURE.md)).

> The three cloud sections below (Volcano / Tencent / 讯飞) are **optional**.
> Skip straight to [Self-hosted](#self-hosted-qwen3-asr--funasr--sherpa-onnx--default-path)
> if you have a GPU and want the zero-billing default path. A generic
> OpenAI-compatible Bearer backend is also available; see
> [Adding a New Provider](#adding-a-new-provider) at the bottom.

### Volcano 豆包 (optional cloud backend)

Recommended as primary cloud backend — generous free tier, works
cross-border, simplest auth.

```bash
mkdir -p ~/.config/voice-stt/secrets && chmod 700 ~/.config/voice-stt/secrets
cat > ~/.config/voice-stt/secrets/volcano.env <<'EOF'
VOLCANO_APP_ID=<from console.volcengine.com>
VOLCANO_ACCESS_TOKEN=<paired access token from 豆包语音控制台>
EOF
chmod 600 ~/.config/voice-stt/secrets/volcano.env
systemctl --user enable --now voice-stt-volcano.service
```

Default port: 18093. Free tier: 20 h over 6 months (ASR 2.0 hour-based),
plus a one-time 40 h signup bonus per the 豆包语音控制台.

### Tencent ASR Realtime (optional cloud backend)

**Mainland CN users:** 5 h / month free, recurring. Enable freely.

**Overseas users:** Read the
[cross-border caveats](#cross-border-billing-caveats) below — every call is
billed at the post-pay rate, the 5 h / month free tier does NOT apply.
This file is shipped with the systemd unit **disabled** for that reason.

```bash
cat > ~/.config/voice-stt/secrets/tencent.env <<'EOF'
TENCENT_APP_ID=<10-digit; see "Finding the AppID" below>
TENCENT_SECRET_ID=<CAM SecretId>
TENCENT_SECRET_KEY=<paired SecretKey>
EOF
chmod 600 ~/.config/voice-stt/secrets/tencent.env
systemctl --user enable --now voice-stt-tencent.service
```

Default port: 18094. Required CAM sub-user policies:
**`QcloudASRFullAccess`** + **`QcloudFinanceFullAccess`** (the finance
policy is needed to consume the free-tier quota — without it the WS
endpoint returns `code=4004`).

**Finding the AppID.** Tencent's UIN ≠ AppID; both are ~10-digit numbers
but mean different things (UIN is account identity, AppID is resource
routing). To discover the AppID for a given SecretId/Key pair:

```bash
python server/tools/tencent_get_appid.py
# Response: {"Uin": "100...", "OwnerUin": "100...", "AppId": 1301574382, ...}
```

Use **`AppId`** (not Uin or OwnerUin) in tencent.env.

### 讯飞 RTASR (optional cloud backend)

```bash
cat > ~/.config/voice-stt/secrets/xfyun.env <<'EOF'
XFYUN_APP_ID=<from console.xfyun.cn 创建应用>
XFYUN_API_KEY=<the API Key paired with the AppID, NOT API Secret>
EOF
chmod 600 ~/.config/voice-stt/secrets/xfyun.env
systemctl --user enable --now voice-stt-xfyun.service
```

Default port: 18095. Free tier: 50 h trial over 1 year from account
creation, paid afterwards.

**讯飞 has separate `APIKey` vs `APISecret` fields** — RTASR uses only
`APIKey`; `APISecret` is for newer Spark LLM endpoints. Do not mix them.

**Cross-border behavior unverified.** If you're overseas, test with
`server/tools/provider_smoke.py` before committing to 讯飞 as a backend
in your client config.

### Self-hosted (Qwen3-ASR / FunASR / sherpa-onnx) — default path

These don't speak to cloud APIs; they run their own ASR models locally.
This is the maintainer's daily driver and what the project is tuned for.
See **[server/README.md](../server/README.md)** for setup. The client
connects to whatever local or SSH-tunneled port the server listens on
(`18082` is the canonical FunASR/Qwen3-ASR port).

## Cross-Border Billing Caveats

### Tencent: free tier does NOT cover cross-border traffic

If you're outside mainland China and call
`wss://asr.cloud.tencent.com/asr/v2/<appid>?...`, expect:

```
code=4004 msg='资源包耗尽，请开通后付费或者购买资源包'
```

Even though the console shows "5 h / month 免费额度". Tencent splits
billing into two channels:

1. **Domestic traffic** — consumes the 5 h / month free tier
2. **Cross-border traffic** — billed at post-pay rates from the first
   second; the free tier does not apply

To use it overseas you must explicitly enable
**「跨境流量后付费」** in the Tencent Cloud console, after which calls
**succeed but every call is billed**. Verified empirically as of
2026-05-19.

**Practical guidance:**

- **In mainland CN:** Enable normally; 5 h / month covers light personal use.
- **Overseas:** Prefer **Volcano** (works cross-border, free tier applies)
  and **self-hosted** (no billing at all). Keep `voice-stt-tencent.service`
  disabled unless you're prepared to pay per call.

### Volcano: cross-border behavior verified working

Confirmed by the maintainer (UK → 火山引擎) over several test recordings:
the 20 h / 6 mo free tier applies to cross-border calls without separate
activation. If this changes, please open an issue.

### 讯飞: cross-border behavior unverified

Treat as "unknown" until you test. Both Tencent and Volcano have had
opposite behaviors here — don't assume one or the other from the docs.

## Diagnostic Tools

`server/tools/` contains stand-alone helpers — none are required at
runtime, but they make new-provider setup and "why isn't this working"
debugging fast. See [server/tools/README.md](../server/tools/README.md)
for full descriptions.

| Tool | When to use |
|---|---|
| `provider_smoke.py` | Verify any voice-stt-protocol WS server works end-to-end with real audio |
| `tencent_get_appid.py` | Find the AppID for a given Tencent SecretId/Key pair |
| `tencent_sentence_probe.py` | If Tencent WS returns 4004, check whether 一句话识别 HTTP works — narrows down whether the issue is account-wide or product-specific |

## Adding a New Provider

The `ASRProvider` ABC in `server/asr_common.py` is the contract. A new
provider is one file that:

1. Subclasses `ASRProvider`
2. Implements 5 async methods: `connect`, `send_audio`, `end_audio`,
   `events` (async iterator), `close`
3. Defines `BACKEND_TAG = "your-provider-name"` and (optionally)
   `SAMPLE_RATE = 16000`
4. Sets up an entrypoint at the bottom that loads credentials and calls
   `asr_common.serve(YourProviderFactory, host, port)`

See `volcano-stream-server.py` (binary-frame protocol), 
`tencent-stream-server.py` (signed-URL JSON-over-WS), and
`xfyun-stream-server.py` (signed-URL + custom audio framing) for three
distinct reference implementations covering the common upstream protocols.

The voice-stt protocol layer (PCM frame ingest, `"EOF"` handling, EOF-
with-no-audio short-circuit, partial/final JSON emission) is entirely
inside `serve()` — you don't need to reimplement any of it.

For an **HTTP-based** upstream (no WS streaming, batch-style POST per
utterance), see `server/openai-compat-stream-server.py`. It buffers PCM in
`send_audio`, packages the buffer as a WAV in `end_audio`, and POSTs a
multipart/form-data request with `Authorization: Bearer ...`, then emits
exactly one `final` event.
