# FunASR WebSocket Protocol Contract

**Source of truth** for the streaming ASR protocol spoken between
`funasr-stream-server.py` and any WebSocket client (the v0.1 Windows
PowerShell client `voice-ptt-stream-ws.ps1`, and any future client that
wants to implement the same protocol).

Last updated: 2026-05-16

---

## 1. Endpoint

`ws://<server>:8082/` — the WebSocket served by `funasr-stream-server.py`
on the GPU host. Reach it over your LAN, a Tailscale name, or any other
private network path (firewall + ACL provide access control; v0.1 does not
ship a TLS-terminating reverse proxy).

---

## 2. Session lifecycle

```
Client                              Server
  |                                   |
  |---- WS connect -------------------->|
  |---- binary PCM frame (repeat) ----->|   (server streams partials back)
  |<--- text JSON {type:"partial"} -----|
  |<--- text JSON {type:"partial"} -----|
  |---- text "EOF" -------------------->|   (client signals end of audio)
  |<--- text JSON {type:"final"} -------|
  |---- WS close (code 1000) ---------->|
  |                                   |
```

One WebSocket connection = one transcription session. The server holds
Paraformer streaming state (cache) for the lifetime of the connection.

---

## 3. Client -> Server frames

### 3a. Audio frames (binary)

- **Type:** binary WebSocket frame
- **Content:** raw PCM audio
- **Format:** signed 16-bit little-endian integers (Int16, not Float32)
- **Sample rate:** 16000 Hz
- **Channels:** mono (single channel, left only)
- **Chunk size:** any size is accepted; reference client uses 4096 samples (~256 ms)

Send as `ArrayBuffer` (the underlying buffer of an `Int16Array`):

```js
// JavaScript (Web / React Native)
ws.send(int16Array.buffer);   // send ArrayBuffer, not the typed array itself
```

```python
# Python
ws.send(pcm_int16_bytes)      # bytes object of raw int16 PCM
```

The server accumulates all received bytes into a PCM buffer for the final
Qwen3-ASR pass and simultaneously feeds chunks to the Paraformer streaming
model for real-time partials.

> **Mic hardware note:** Some stereo mic arrays have one unusable / noisy
> element. Clients should capture mono, or explicitly mix or select a single
> channel (left, right, or mix), before converting to Int16.

### 3b. EOF sentinel (text)

- **Type:** text WebSocket frame
- **Content:** the exact string `EOF` (case-insensitive; server uppercases before comparing)

Signals that audio capture is complete. The server will run final inference
on the accumulated PCM buffer and send a `final` response, then the server
closes the session.

Send EOF before calling `ws.close()` to ensure the server has time to return
the final result:

```js
ws.send("EOF");
// wait for {type:"final"} message, then the client or server closes
```

---

## 4. Server -> Client frames (all text, JSON)

All server messages are UTF-8 encoded JSON text frames.

### 4a. Partial result

Emitted during recording as transcription progresses. May be sent multiple
times per session. The text is **cumulative** (each partial replaces the
previous one, not appended).

```json
{
  "type": "partial",
  "text": "<accumulated transcript so far>"
}
```

Extended form (Qwen3 speculative partial, carries extra metadata):

```json
{
  "type": "partial",
  "text": "<accumulated transcript>",
  "language": "Chinese",
  "backend": "qwen3-asr-partial",
  "seq": 3
}
```

Clients MUST handle both forms. Only `type` and `text` are guaranteed.

### 4b. Final result

Sent exactly once per session, after the client sends `EOF`. After this
message the server closes the WebSocket connection.

```json
{
  "type": "final",
  "text": "<final corrected transcript>"
}
```

Extended form (includes debugging fields):

```json
{
  "type": "final",
  "text": "<final corrected transcript>",
  "language": "Chinese",
  "raw_streaming": "<paraformer raw accumulation>",
  "backend": "qwen3-asr",
  "derived_from": "last_partial"
}
```

Or (paraformer-only fallback path):

```json
{
  "type": "final",
  "text": "<polished transcript>",
  "punctuated": "<with punctuation>",
  "raw": "<paraformer raw>",
  "backend": "paraformer+ctpunc+polish"
}
```

Clients MUST use only the `text` field. All other fields are informational.

### 4c. Error

The server does not currently send an explicit `{type:"error"}` JSON frame.
Errors surface as WebSocket close codes (non-1000). Common codes:

| Code | Meaning |
|---|---|
| 1000 | Normal close (session complete) |
| 1006 | Abnormal closure (network drop, TLS failure) |
| 1008 | Policy violation (server rejected handshake, e.g. no Tailscale auth) |
| 1011 | Server-side unexpected error |
| 1015 | TLS handshake failure |

Clients should treat any close code other than 1000 as an error condition.

---

## 5. Recommended client implementation pattern

```js
// Minimal correct client (pseudocode)
const ws = new WebSocket(ASR_URL);
ws.binaryType = "arraybuffer";  // must set before use

ws.onmessage = (evt) => {
  if (typeof evt.data !== "string") return;  // ignore any binary server frames
  const msg = JSON.parse(evt.data);
  if (msg.type === "partial") showPartial(msg.text);
  if (msg.type === "final")  { showFinal(msg.text); ws.close(1000); }
};

ws.onerror = (e) => console.error("ASR WS error", e);
ws.onclose = (e) => { if (e.code !== 1000) showError(e.code, e.reason); };

// Send audio:
ws.send(int16Array.buffer);   // repeat for each chunk

// End session:
ws.send("EOF");               // server sends {type:"final"} then closes
```

---

## 6. Server-side parameters (informational)

These are server configuration values. Clients do not need to set them, but
they explain server timing behaviour.

| Parameter | Default | Effect |
|---|---|---|
| `CHUNK_SIZE` | `[0, 5, 3]` | Paraformer streaming window (60ms units): 300ms emit cadence |
| `PARTIAL_INTERVAL_SEC` | varies | How often Qwen3 speculative partials are triggered |
| `MAX_PARTIAL_AUDIO_SEC` | varies | Max audio tail sent to Qwen3 for partial |
| `VAD_CHUNK_THRESHOLD_SEC` | 25 | Audio longer than this is VAD-chunked for final inference |
| `PARTIAL_AS_FINAL_MIN_COVERAGE` | 0.9 | Coverage threshold to reuse last partial as final |

---

## 7. Changelog

| Date | Change |
|---|---|
| 2026-05-16 | Initial version. |
