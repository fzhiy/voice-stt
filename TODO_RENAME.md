# TODO — Phase 2 rename `voice-stt` → `asr-anywhere`

Phase 1 (2026-05-28) only touched **prose** in user-facing docs +
`pyproject.toml` package name. Everything below would change actual
identifiers / paths / running-system contracts and was deliberately deferred
so this session's rebrand commit can be pushed without breaking the
maintainer's running setup (Windows AHK + GPU server + iOS HappyCoder).

Pick this up in a future session with a dedicated time window of ~1.5–3h.

---

## Order of operations (safe sequence)

Each step is independently revertible. Run them top-to-bottom; **do not skip**.

### 1. GitHub repo URL rename (90s, low-risk — GitHub auto-redirects)

- `gh repo rename asr-anywhere` (from inside the working tree), OR
- GitHub web UI → Settings → Repository name → `asr-anywhere`.
- Local: `git remote set-url origin git@github.com:fzhiy/asr-anywhere.git`.
- Verify: `git ls-remote origin` succeeds.
- **Old URL `github.com/fzhiy/voice-stt` keeps working via GitHub's permanent redirect** —
  no rush to update existing links.

### 2. Local repo directory rename

```bash
cd /home/fy/projects
git -C voice-stt status   # ensure clean
mv voice-stt asr-anywhere
cd asr-anywhere
git status                # sanity
```

Side effects:
- **Claude memory dir** auto-changes from
  `~/.claude/projects/-home-fy-projects-voice-stt/memory/` to
  `~/.claude/projects/-home-fy-projects-asr-anywhere/memory/`. Either:
  (a) `mv ~/.claude/projects/-home-fy-projects-voice-stt ~/.claude/projects/-home-fy-projects-asr-anywhere` to migrate, OR
  (b) start fresh and re-pin key memories. (a) preferred.
- Update any worktree dirs under `.claude/worktrees/` if present (none currently
  per `git worktree list` at the time of this writing).
- VS Code / IDE workspace files: re-open in new location.

### 3. Update repo URL fields in `pyproject.toml`

After step 1:
```toml
Homepage   = "https://github.com/fzhiy/asr-anywhere"
Repository = "https://github.com/fzhiy/asr-anywhere"
Changelog  = "https://github.com/fzhiy/asr-anywhere/blob/main/CHANGELOG.md"
```

### 4. Windows install dir rename (the most invasive step)

**Pre-flight**: stop the running AHK + tunnel:
```powershell
Stop-ScheduledTask -TaskName 'voice-stt-hotkey'
Stop-ScheduledTask -TaskName 'voice-stt-tunnel'   # if still enabled
Get-Process AutoHotkey64 | Stop-Process -Force
```

Then:
```powershell
# Rename install dir
Move-Item "$env:LOCALAPPDATA\voice-stt" "$env:LOCALAPPDATA\asr-anywhere"
```

Now the painful part — find/replace these hardcoded path strings inside the
install dir:

- `voice-hotkey.ahk` — search for `voice-stt`; ~15 occurrences (install dir,
  partial.txt, stream-debug.log, sapi-tts.ps1 path, tts-readback.ps1 path,
  RENDERER_AHK_SCRIPT, mic-daemon log path, etc.)
- `voice-ptt-stream-ws.ps1`, `voice-ptt.ps1`, `voice-input.ps1`, `record.ps1`,
  `launch.ps1`, `voice-mic-daemon.ps1`, `voice-mic-daemon-client.ps1` —
  each has 2–8 occurrences of `voice-stt`
- `tunnel-wrapper.ps1` — log path
- `tts-readback.ps1` (Phase 1 prototype, added 2026-05-28) — `~/.venvs/tts/` path stays;
  the install-dir reference `/mnt/c/Users/fzhiy/AppData/Local/voice-stt/tts-readback.py`
  needs update
- `sapi-tts.ps1` — likely no path refs but verify
- `config.example.ps1`, `launch.ps1` — env file paths

**Scheduled Tasks rename**:
```powershell
# Re-register with new task names + new dir paths
Unregister-ScheduledTask -TaskName 'voice-stt-hotkey'  -Confirm:$false
Unregister-ScheduledTask -TaskName 'voice-stt-tunnel'  -Confirm:$false

# Then re-run the registration commands from earlier sessions with
# updated names: asr-anywhere-hotkey and asr-anywhere-tunnel,
# pointing to "$env:LOCALAPPDATA\asr-anywhere\voice-hotkey.ahk" /
# "$env:LOCALAPPDATA\asr-anywhere\tunnel-wrapper.ps1".
```

**Verify**: press `Shift+Alt+S`, get transcription → paste OK.

### 5. GPU host path rename (optional — it was never `voice-stt`)

Current path: `/home/fy274/voice-stack/` (already differs from repo name).
You can either:
- (a) Leave as-is — `voice-stack` is no more wrong than before. Lowest disruption.
- (b) Rename to `/home/fy274/asr-anywhere/` for consistency:
  ```bash
  ssh fy274@144.173.65.243 "
    cd ~
    # stop server first
    pkill -f funasr-stream-server
    pkill -f EngineCore
    sleep 3
    mv voice-stack asr-anywhere
    # update start-stream-vllm.sh's VOICE_STACK_DIR default
    sed -i 's|VOICE_STACK_DIR:-\$HOME/voice-stack|VOICE_STACK_DIR:-\$HOME/asr-anywhere|' \
        asr-anywhere/start-stream-vllm.sh
    cd asr-anywhere && bash start-stream-vllm.sh
  "
  ```
  Recommend (a) unless you want a uniform name everywhere.

### 6. Env variable rename `VOICE_STT_*` → `ASR_ANYWHERE_*`

Current users (must update in lockstep — server + .env file):
- `VOICE_STT_RESEARCH_LOG` (kill-switch for `_research_emit`, documented in
  CONTRIBUTING.md as the only intentional gating exception)

Strategy: keep both names valid in code for one minor version (read either),
deprecate `VOICE_STT_*` in the version after. Backward-compat helper:

```python
research_log_enabled = os.getenv(
    "ASR_ANYWHERE_RESEARCH_LOG",
    os.getenv("VOICE_STT_RESEARCH_LOG", "1")
) != "0"
```

Update affected files:
- `server/funasr-stream-server.py` (research log gate)
- `server/.env.server.example` (commented sample)
- `.env.example` (top-level Windows-side env)
- `CONTRIBUTING.md` (privacy / maintainer-telemetry doc)

### 7. systemd unit names `voice-stt-<provider>.service` → `asr-anywhere-<provider>.service`

User-side migration (per provider in use):
```bash
systemctl --user stop voice-stt-volcano.service     # or tencent/xfyun/openai-compat
systemctl --user disable voice-stt-volcano.service

# Copy unit to new name
mv ~/.config/systemd/user/voice-stt-volcano.service \
   ~/.config/systemd/user/asr-anywhere-volcano.service

# Edit Description if it embeds the old name; ExecStart paths if you also
# moved ~/.config/voice-stt/secrets/ → ~/.config/asr-anywhere/secrets/
systemctl --user daemon-reload
systemctl --user enable --now asr-anywhere-volcano.service
```

Also update docs/PROVIDERS.md examples that recommend `voice-stt-<name>.service`
naming.

### 8. Secrets dir rename `~/.config/voice-stt/` → `~/.config/asr-anywhere/`

```bash
mv ~/.config/voice-stt ~/.config/asr-anywhere
# Then update any systemd unit EnvironmentFile= path references.
```

### 9. Docker service / volume names

`server/docker-compose.yml` has:
- `voice-stt-hf-cache` volume
- `voice-stt-sherpa-models` volume
- `voice-stt-sherpa-onnx:dev` image tag
- Service names like `voice-stt-funasr` if present

Renaming requires `docker compose down -v` (volume data discarded!) **OR**
manual `docker volume create asr-anywhere-hf-cache` + `cp` from old volume.
**This step is only worth doing for users who actively run the docker
compose path** — the maintainer's setup doesn't use it (WSL has no docker
engine, the GPU host runs the server directly).

### 10. Code identifier sweep (low-priority polish)

After all of the above, repeat:
```bash
git grep -n 'voice-stt\|voice_stt' | grep -v -E "TODO_RENAME|CHANGELOG.*v0\.1\."
```

Remaining hits should be:
- WAV temp file naming (`%TEMP%\voice-stt-*.wav` in code) — rename code + matching
  shell-side cleanup logic
- `voice-stt protocol` mentions in `server/asr_common.py` docstrings
- `[voice-stt config error]` log prefix in `server/config_validation.py`
- `voice-stt.zip` release asset name in `scripts/build-portable.ps1` and CI workflow
- GitHub Actions workflow names (cosmetic but visible in Actions tab)

Each is safe to update once steps 1–9 are done, but they're not blocking.

### 11. Memory files

`~/.claude/projects/-home-fy-projects-asr-anywhere/memory/` (after step 2):
- File slug renames optional (`project_voice_stt_*` → `project_asr_anywhere_*`).
  Internal anchors only — no external dependency. **Defer until you happen to
  edit each memory.** When you do, update the `name:` frontmatter to match.
- `MEMORY.md` index entries — text labels can be updated as you touch them.

### 12. Final release

Tag `v0.1.4` (or `v0.2.0` if this rename is bundled with the v0.1.4 backlog
items: secret-redaction, hotword coverage gap, λ tuning, mapping auto-promote).

---

## Estimated total effort

| Step | Time | Risk |
|---|---|---|
| 1. GitHub rename | 90s | low |
| 2. Local dir rename | 5m | low |
| 3. pyproject URLs | 2m | none |
| 4. **Windows install dir** | **30–60m** | **medium** (path-typo risk) |
| 5. GPU host (optional) | 10m | low |
| 6. Env var rename | 15m | low |
| 7. systemd unit names | 10m / provider | low |
| 8. Secrets dir | 5m | low |
| 9. Docker rename (optional) | 10m | low (you don't use it) |
| 10. Code sweep | 30m | low |
| 11. Memory files | as-touched | none |
| 12. v0.1.4 / v0.2.0 tag | 5m | none |

**Total**: ~1.5–3h depending on which optional steps are included.
