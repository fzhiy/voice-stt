"""Shared ABC + voice-stt WS protocol handler for all cloud ASR providers.

Lifts the common scaffolding out of <provider>-stream-server.py so adding a
new cloud backend is: subclass ASRProvider, fill 5 async methods, call serve().

voice-stt wire protocol (client ↔ this server, unchanged across providers):
    client → server:
        binary frame  = int16 LE PCM @ 16kHz mono
        text "EOF"    = end-of-utterance signal
    server → client:
        {"type":"partial","text":"...","backend":"..."}
        {"type":"final","text":"...","backend":"...","language":"..."}

Each provider subclass owns:
    - upstream WS handshake + auth signing
    - per-provider frame encoding (binary vs JSON)
    - per-provider response parsing (mapping to voice-stt's partial/final)

Two surprising-but-load-bearing details kept here, not in subclasses:
    1. EOF-with-no-audio short-circuit (Test-Connection probe) — avoids
       hanging upstream sessions that drain free-tier quota.
    2. Tasks are torn down in finally so an upstream-side cancel always
       closes the client cleanly (one user complaint per provider otherwise).
"""

from __future__ import annotations

import abc
import asyncio
import json
import os
import re
import time
from pathlib import Path
from typing import AsyncIterator, Callable

import websockets


# ────────────────────── logging ──────────────────────
def log(*args):
    print(f"[{time.strftime('%H:%M:%S')}]", *args, flush=True)


# ────────────────────── credentials ──────────────────────
def parse_env_file(path: Path, required_keys: list[str]) -> dict[str, str]:
    """Parse KEY=VALUE lines from a mode-600 secrets file.
    Returns dict containing exactly the required_keys (raises if any missing).
    """
    if not path.exists():
        raise FileNotFoundError(
            f"secrets file not found: {path}\n"
            f"create with mode 600 and entries: {', '.join(required_keys)}"
        )
    parsed: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        if k in required_keys:
            parsed[k] = v
    missing = [k for k in required_keys if not parsed.get(k)]
    if missing:
        raise ValueError(f"missing keys in {path}: {', '.join(missing)}")
    return parsed


# ────────────────────── hotwords + mappings (YAML, no pyyaml dep) ──────────────────────
def load_hotwords_terms(
    yaml_path: str,
    max_count: int = 100,
    min_ascii_len: int = 3,
    min_cjk_len: int = 2,
) -> list[str]:
    """Flatten yaml category lists into a flat list of hotword terms.

    Used by providers whose upstream supports hotword injection (Volcano,
    Xfyun, Tencent's `hotword_id` flow). Caller is expected to know the
    upstream's token-count cap (Volcano: 100, Xfyun: 2000, Tencent: 1024).

    Filters drop too-short terms (configurable per provider). The
    `mappings:` section is skipped — those are post-correct rewrites, not
    hotwords.
    """
    if not Path(yaml_path).exists():
        return []
    text = Path(yaml_path).read_text(encoding="utf-8")
    terms: list[str] = []
    seen: set[str] = set()
    in_category = False
    in_mappings = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if re.match(r"^[a-z_]+:\s*$", line):
            in_mappings = (stripped == "mappings:")
            in_category = not in_mappings
            continue
        if in_mappings:
            continue
        if in_category:
            m = re.match(r"^\s*-\s+(.+?)\s*$", line)
            if m:
                term = m.group(1).strip().strip('"').strip("'")
                if not term or term.lower() in seen:
                    continue
                has_cjk = any("一" <= c <= "鿿" for c in term)
                if has_cjk and len(term) < min_cjk_len:
                    continue
                if not has_cjk and len(term) < min_ascii_len:
                    continue
                seen.add(term.lower())
                terms.append(term)
                if len(terms) >= max_count:
                    break
    return terms


def load_mappings(yaml_path: str) -> dict[str, str]:
    """Parse `mappings:` section. Tolerant regex parse so pyyaml stays optional."""
    if not Path(yaml_path).exists():
        return {}
    text = Path(yaml_path).read_text(encoding="utf-8")
    mp: dict[str, str] = {}
    in_mappings = False
    for line in text.splitlines():
        if re.match(r"^[a-z_]+:\s*$", line):
            in_mappings = line.strip().startswith("mappings:")
            continue
        if not in_mappings:
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = re.match(r'^"?([^"]+?)"?\s*:\s*"?([^"]+?)"?\s*$', stripped)
        if m:
            mp[m.group(1)] = m.group(2)
    return mp


def apply_mappings(text: str, mappings: dict[str, str]) -> str:
    """Post-correct: long LHS first; CJK substring, ASCII word boundary."""
    if not text or not mappings:
        return text
    out = text
    for lhs in sorted(mappings, key=len, reverse=True):
        rhs = mappings[lhs]
        has_cjk = any("一" <= c <= "鿿" for c in lhs)
        pattern = re.escape(lhs) if has_cjk else r"\b" + re.escape(lhs) + r"\b"
        new_out, n = re.subn(pattern, rhs, out, flags=re.IGNORECASE)
        if n > 0:
            log(f"  [mapping] '{lhs}' -> '{rhs}'")
            out = new_out
    return out


# ────────────────────── ASRProvider ABC ──────────────────────
class ASRProvider(abc.ABC):
    """One streaming ASR session: open → send PCM → end → drain → close.

    Subclasses encapsulate provider-specific upstream WS handshake, frame
    encoding, and response parsing. The voice-stt protocol layer (this
    file's serve()) drives the lifecycle.
    """

    # Subclasses set these:
    BACKEND_TAG: str = ""              # e.g. "volcano-doubao-2.0"
    SAMPLE_RATE: int = 16000

    @abc.abstractmethod
    async def connect(self) -> None:
        """Open upstream WS + send any initial handshake.
        Raises on auth / network errors so serve() can surface them.
        """

    @abc.abstractmethod
    async def send_audio(self, pcm: bytes) -> None:
        """Send one chunk of int16 LE mono PCM @ SAMPLE_RATE."""

    @abc.abstractmethod
    async def end_audio(self) -> None:
        """Signal end-of-utterance to upstream so it flushes its decoder."""

    @abc.abstractmethod
    def events(self) -> AsyncIterator[dict]:
        """Async iterator yielding voice-stt envelope dicts:
            {"type": "partial", "text": "..."}
            {"type": "final",   "text": "...", "language": "..."}
            {"type": "final",   "text": "",    "error_code": N, "error_message": "..."}
        backend tag is added by serve(); providers may set extra fields.
        Generator must terminate after the final event so serve() can drain.
        """

    @abc.abstractmethod
    async def close(self) -> None:
        """Idempotent upstream teardown; safe to call multiple times."""


# ────────────────────── voice-stt protocol server ──────────────────────
async def _handle_one_client(ws, provider_factory: Callable[[], ASRProvider]):
    peer = ws.remote_address
    provider = provider_factory()
    backend_tag = provider.BACKEND_TAG
    log(f"client connected: {peer}")
    audio_bytes = 0

    try:
        try:
            await provider.connect()
        except Exception as e:
            log(f"  {peer} provider connect FAILED: {e!r}")
            await ws.send(json.dumps({
                "type": "final",
                "text": "",
                "backend": backend_tag,
                "error_message": f"upstream connect failed: {e!r}",
            }, ensure_ascii=False))
            return

        # Drain provider events to client in background.
        async def pump_events():
            async for event in provider.events():
                if "backend" not in event:
                    event = {**event, "backend": backend_tag}
                await ws.send(json.dumps(event, ensure_ascii=False))

        events_task = asyncio.create_task(pump_events())

        try:
            async for msg in ws:
                if isinstance(msg, (bytes, bytearray)):
                    if not msg:
                        continue
                    await provider.send_audio(bytes(msg))
                    audio_bytes += len(msg)
                elif isinstance(msg, str):
                    if msg.strip().upper() == "EOF":
                        if audio_bytes == 0:
                            # Test-Connection probe (or VAD false-start): client
                            # sent EOF with no audio. Most providers will hang
                            # waiting for audio they'll never get, burning
                            # free-tier session quota. Short-circuit here.
                            await ws.send(json.dumps({
                                "type": "final",
                                "text": "",
                                "backend": backend_tag,
                            }, ensure_ascii=False))
                            log(f"  {peer} EOF (no audio) -> empty final")
                            events_task.cancel()
                            return
                        await provider.end_audio()
                        # Wait for events_task to emit final + return.
                        try:
                            await asyncio.wait_for(events_task, timeout=30)
                        except asyncio.TimeoutError:
                            log(f"  {peer} drain timeout after EOF")
                        return
                    else:
                        log(f"  {peer} unknown text frame: {msg[:40]!r}")
            # Client closed without EOF — still try to drain a final if any audio sent.
            if audio_bytes > 0:
                try:
                    await provider.end_audio()
                    await asyncio.wait_for(events_task, timeout=10)
                except Exception:
                    pass
        finally:
            if not events_task.done():
                events_task.cancel()
                try:
                    await events_task
                except (asyncio.CancelledError, Exception):
                    pass
    except websockets.ConnectionClosed:
        pass
    except Exception as e:
        log(f"  {peer} session error: {e!r}")
    finally:
        try:
            await provider.close()
        except Exception:
            pass
        log(f"client disconnected: {peer}")


async def serve(
    provider_factory: Callable[[], ASRProvider],
    host: str,
    port: int,
):
    """Run a voice-stt-protocol WebSocket server.
    provider_factory is called once per client to construct a fresh provider session.
    """
    log(f"listening on ws://{host}:{port}/")
    async with websockets.serve(
        lambda ws: _handle_one_client(ws, provider_factory),
        host, port, max_size=None,
    ):
        await asyncio.Future()


# ────────────────────── env helpers ──────────────────────
def env_str(name: str, default: str) -> str:
    return os.environ.get(name, default)


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    return int(raw) if raw else default


def env_path(name: str, default_factory: Callable[[], Path]) -> Path:
    raw = os.environ.get(name)
    return Path(raw) if raw else default_factory()
