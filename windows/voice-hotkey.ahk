; Windows 全局语音输入热键
; Ctrl+Alt+V        → 录 15 秒（定时）→ Whisper 转写 → 自动粘贴
; Ctrl+Alt+Shift+V  → 录 45 秒（定时，长语音兜底）
; Shift+Alt+V       → 按住录音、松开停止（PTT，batch 模式）
; Shift+Alt+B       → 点按开始、再点按结束（toggle，不用一直按住）
; Shift+Alt+S       → 流式 PTT：按住边说边显示部分转写，松开出最终文本
; Shift+Alt+P       → SAPI 朗读选中文本（本地 TTS，零延迟，P for Pronounce）
; Shift+Alt+Q       → 关闭 mic daemon（开会让出 mic 给 Zoom/Teams 用）
; Shift+Alt+W       → 重启 mic daemon（关 daemon 后用 mic app 完事，再按一下恢复）
;
; mic warm-capture daemon: AHK 启动时自动拉起 voice-mic-daemon.ps1，常驻 ffmpeg
; dshow + 500ms 环形缓冲。Shift+Alt+S 按下时从 daemon named pipe 取 PCM，附带
; 按下之前 ~300ms pre-roll，解决"按下吞前 0.3s"问题。AHK 退出时 OnExit kill daemon。
; daemon 没起来时 voice-ptt-stream-ws.ps1 自动 fallback 到老 ffmpeg 路径（吞 0.3s 但可用）。
; See docs/dev/changes/2026-05-16-mic-warm-capture.md
;
; 要求：
;   - AutoHotkey v2
;   - 定时模式走 WSL helper；PTT 直接调 Windows powershell voice-ptt.ps1
;
; 使用：
;   1. 装 AutoHotkey v2
;   2. 双击 voice-hotkey.ahk 启动（自动起 mic daemon）
;   3. PTT：按住 Shift+Alt+V 说话，松开停止；定时：点按 Ctrl+Alt+V
;
; 开机自启：.ahk 快捷方式扔 shell:startup

#Requires AutoHotkey v2.0
#SingleInstance Force

; 配置区
VOICE_DURATION_SHORT := 15
VOICE_DURATION_LONG  := 45
; AHK doesn't expand shell/PowerShell env syntax inside strings.
; Use AHK built-ins: A_ScriptDir (this script's dir), A_UserProfile (= %USERPROFILE%),
; EnvGet("LOCALAPPDATA"). All deployed scripts live alongside this one after install.ps1.
; WSL helper path defaults to a path RELATIVE to WSL $HOME (wsl.exe -e launches in
; $HOME, bash resolves the relative arg against that). Override absolute via env var.
wslHelperEnv := EnvGet("VOICE_STT_WSL_HELPER")
WSL_HELPER_SCRIPT := wslHelperEnv != "" ? wslHelperEnv : "voice-stt/wsl/voice-input-for-ahk.sh"
WIN_TMP_FILE      := A_Temp "\voice-ahk-out.txt"
WIN_ERR_FILE      := A_Temp "\voice-ahk-out.txt.err"
; PTT 用到的 Windows-侧脚本（部署到 voice-hotkey.ahk 同目录，通常是 C:\Users\<USERNAME>\）
PTT_PS_SCRIPT     := A_ScriptDir . "\voice-ptt.ps1"
; STREAM 走真流式 WebSocket（Paraformer-zh-streaming），不是 batch 轮询
STREAM_PS_SCRIPT  := A_ScriptDir . "\voice-ptt-stream-ws.ps1"
; 常驻 mic 守护：voice-ptt-stream-ws.ps1 优先连它的 named pipe 拿 pre-roll
DAEMON_PS_SCRIPT  := A_ScriptDir . "\voice-mic-daemon.ps1"

; Caption preview renderer (Edit-control fallback; v0.1 default — WebView2 is v0.2 scope).
STREAM_PARTIAL_FILE  := EnvGet("LOCALAPPDATA") . "\voice-stt\partial.txt"
RENDERER_AHK_SCRIPT  := A_ScriptDir . "\voice-preview-renderer-fallback.ahk"
AHK64_EXE_PATH       := EnvGet("LOCALAPPDATA") . "\Programs\AutoHotkey\v2\AutoHotkey64.exe"
g_RendererPid        := 0   ; renderer process pid; 0 = not yet started / died

; Paste-target 安全阈值. 录音 >= PASTE_CONFIRM_DURATION_SEC 秒, 或 press/release 焦点
; 漂了, 都必须走 3s 超时的 MsgBox 确认; 默认行为 (超时) = 不粘 (文本仍在 recovery log).
PASTE_CONFIRM_DURATION_SEC := 30
PASTE_CONFIRM_TIMEOUT_SEC  := 3

g_DaemonPid := 0   ; mic daemon PS 进程 pid; 0 表示未启动 / 已被 quit

; Ensure the voice-stt data directory exists (logs, partial preview file).
voiceSttDir := EnvGet("LOCALAPPDATA") . "\voice-stt"
if !DirExist(voiceSttDir)
    DirCreate(voiceSttDir)

; 启动时拉起 daemon；AHK 退出时 kill 之.
; 必须在第一个 hotkey 之前调用 (hotkey label 会结束 auto-execute 段).
StartDaemon()
OnExit(OnAhkExit)

^!v::DoVoiceInput(VOICE_DURATION_SHORT)
^!+v::DoVoiceInput(VOICE_DURATION_LONG)
+!v::DoVoicePTT()
+!b::DoVoiceToggle()
+!s::DoVoiceStream()
+!p::DoSapiTTS()
+!q::QuitDaemon()
+!w::StartDaemon()

; tap-toggle 模式状态（跨热键调用持久）
g_TogglingRecording := false
g_ToggleSig := ""
g_ToggleWav := ""
g_ToggleOut := ""
g_ToggleErr := ""
g_TogglePid := 0
g_ToggleHwnd := 0   ; 第一次按 Toggle 时记下焦点，粘贴时拉回去

; 判断窗口是不是"我们自己产生的杂窗"——AHK / 隐藏 cmd.exe helper / 浮窗 GUI
; paste 时若当前焦点是这些 spurious 窗口，说明焦点漂走了，应该回退到 capture 的 hwnd
IsSpuriousWindow(hwnd)
{
    if !hwnd
        return true
    try {
        proc := WinGetProcessName("ahk_id " hwnd)
        title := WinGetTitle("ahk_id " hwnd)
        if (proc = "AutoHotkey64.exe" || proc = "AutoHotkey.exe")
            return true
        ; 我们 Run("Hide") 起来的 cmd.exe + powershell helper
        if ((proc = "cmd.exe" || proc = "conhost.exe" || proc = "powershell.exe") && InStr(title, "voice-ptt"))
            return true
        if title = "语音输入"        ; 旧浮窗 GUI 标题
            return true
        if title = "voice-preview"   ; WebView2 renderer window
            return true
        if title = "voice-preview-fallback"   ; fallback Edit-control renderer
            return true
    } catch {
    }
    return false
}

; 粘贴 text 并恢复剪贴板。目标优先级（用户语义："松开瞬间停留的窗口"）：
;   1. release_hwnd：松开按键 / 第二次 toggle / 定时录音结束时的焦点。**主目标**。
;      这样用户松开后可以立刻去做别的事（点别的窗口），paste 也不追鼠标。
;   2. press_hwnd：热键按下瞬间的焦点。release_hwnd 失效或 spurious 时兜底。
;   3. 当前焦点：press/release 都失效时的最后兜底（带 spurious 过滤）。
PasteAndRestoreClipboard(text, release_hwnd := 0, press_hwnd := 0)
{
    target_hwnd := 0
    if release_hwnd && WinExist("ahk_id " release_hwnd) && !IsSpuriousWindow(release_hwnd)
        target_hwnd := release_hwnd
    else if press_hwnd && WinExist("ahk_id " press_hwnd) && !IsSpuriousWindow(press_hwnd)
        target_hwnd := press_hwnd
    else {
        cur := WinExist("A")
        if cur && !IsSpuriousWindow(cur)
            target_hwnd := cur
    }

    if target_hwnd && WinExist("ahk_id " target_hwnd) {
        try {
            WinActivate("ahk_id " target_hwnd)
            WinWaitActive("ahk_id " target_hwnd, , 1)  ; 最多等 1s 焦点真切过去
        } catch {
            ; 目标窗口可能已被用户主动关闭，让 Send "^v" 落到当前活动窗口
        }
    }
    saved := ClipboardAll()
    A_Clipboard := text
    ClipWait 1   ; 等剪贴板真的更新（最多 1s），比固定 Sleep 80 稳
    Send "^v"
    ; Windows Terminal / WSL / Claude Code 处理 paste 的速度不稳；
    ; 中文是多字节，IME 介入时更慢。给 600ms 比之前 250ms 更安全。
    Sleep 600
    A_Clipboard := saved
    return target_hwnd   ; 让调用方用真实 paste 目标做 TrayTip 标题
}

; 拿指定 hwnd 的可读标题；hwnd=0 表示当前活动窗口
GetWindowTitle(hwnd := 0)
{
    try {
        spec := hwnd ? "ahk_id " hwnd : "A"
        title := WinGetTitle(spec)
        if title = ""
            return "(无标题)"
        return SubStr(title, 1, 60)
    } catch {
        return "(无法获取)"
    }
}

; 容错删除：上游 PS/ffmpeg 可能还持有 partial.txt 句柄；硬 FileDelete 会抛 (32) 异常
; 把整个 paste 流程弹掉，结果是 transcribe 拿到了却没粘贴
SafeFileDelete(path)
{
    if FileExist(path) {
        try {
            FileDelete path
        } catch {
            ; 文件被某进程占用，放着，OS 会自己清 %TEMP%
        }
    }
}

; JSON 转义最小集. 用于本地转写恢复日志(纯结构化输出, 不消费外部输入).
JsonEscape(s)
{
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    return s
}

; 把 Map 拍成 JSON 单行. 保留 Map 插入顺序; 数字类型不加引号.
JsonStringify(m)
{
    parts := ""
    first := true
    for k, v in m {
        if !first
            parts .= ","
        first := false
        parts .= '"' k '":'
        t := Type(v)
        if (t = "Integer" || t = "Float") {
            parts .= v
        } else {
            parts .= '"' JsonEscape(v) '"'
        }
    }
    return "{" parts "}"
}

; 转写恢复日志: 每次 PTT 完成(成功 / 空 / 失败)都追加一行 JSONL 到
; %LOCALAPPDATA%\voice-stt\transcripts\YYYY-MM.jsonl. 月轮换. 纯本地, 不上传.
; 兜底场景: paste 投错窗口 / paste 失败时, 文本不丢, 可从这里 grep 回来.
WriteRecoveryRecord(text, started_tick, target_hwnd, release_hwnd, used_hwnd, paste_status)
{
    try {
        dir := EnvGet("LOCALAPPDATA") . "\voice-stt\transcripts"
        if !DirExist(dir)
            DirCreate(dir)
        path := dir . "\" . FormatTime(, "yyyy-MM") . ".jsonl"
        duration_sec := Round((A_TickCount - started_tick) / 1000, 2)
        rec := Map()
        rec["ts"] := FormatTime(, "yyyy-MM-ddTHH:mm:ss")
        rec["duration_sec"] := duration_sec
        rec["target_hwnd_press"] := target_hwnd
        rec["target_hwnd_release"] := release_hwnd
        rec["target_hwnd_used"] := used_hwnd
        rec["target_title_press"] := GetWindowTitle(target_hwnd)
        rec["target_title_release"] := GetWindowTitle(release_hwnd)
        rec["target_title_used"] := used_hwnd ? GetWindowTitle(used_hwnd) : ""
        rec["paste_status"] := paste_status
        rec["text"] := text
        FileAppend(JsonStringify(rec) . "`n", path, "UTF-8-RAW")
    } catch {
        ; 恢复日志写失败绝对不能影响主流程
    }
}

; 决定本次 paste 是否安全静默执行. 返回 "ok" / "user_aborted" / "timeout_aborted" / "hwnd_invalid".
; 触发确认的条件 (任一即弹 MsgBox):
;   - 录音时长 >= PASTE_CONFIRM_DURATION_SEC (长录音, 粘错代价大)
;   - press_hwnd != release_hwnd (焦点中途漂了, 意图不明)
;   - press_hwnd 已无效 / spurious (没有靠谱目标)
; 弹的 MsgBox 带 PASTE_CONFIRM_TIMEOUT_SEC 秒超时, 默认 = 不粘 (不点 Y 不算同意).
ConfirmPaste(duration_sec, press_hwnd, release_hwnd, text)
{
    if !press_hwnd || !WinExist("ahk_id " press_hwnd) || IsSpuriousWindow(press_hwnd)
        return "hwnd_invalid"
    needs_confirm := (duration_sec >= PASTE_CONFIRM_DURATION_SEC) || (release_hwnd && release_hwnd != press_hwnd)
    if !needs_confirm
        return "ok"
    title_p := GetWindowTitle(press_hwnd)
    if (release_hwnd && release_hwnd != press_hwnd && WinExist("ahk_id " release_hwnd)) {
        title_r := GetWindowTitle(release_hwnd)
        msg := Format("录音 {1}s, 焦点漂了:`n按下: {2}`n松开: {3}`n`n粘到 [按下] 目标?  (Y=粘 / N 或 {4}s 超时=不粘)`n`n文本已存 transcripts JSONL, 不会丢.", Round(duration_sec, 1), title_p, title_r, PASTE_CONFIRM_TIMEOUT_SEC)
    } else {
        msg := Format("长录音 {1}s.`n`n粘到 {2}?  (Y=粘 / N 或 {3}s 超时=不粘)`n`n文本已存 transcripts JSONL, 不会丢.", Round(duration_sec, 1), title_p, PASTE_CONFIRM_TIMEOUT_SEC)
    }
    result := MsgBox(msg, "voice-stt 确认 paste 目标", "YesNo IconWarning T" PASTE_CONFIRM_TIMEOUT_SEC)
    if result = "Yes"
        return "ok"
    if result = "No"
        return "user_aborted"
    return "timeout_aborted"
}

; 等转写完成：以"OutputText 文件出现"或"PS 进程死亡"为终止信号
; 跟录音/转写时长解耦；只在 PS 真挂（罕见）时靠 10 分钟硬上限兜底
; 返回值: 1=出文件了, 0=PS 死了但没出文件, -1=硬超时
WaitForTranscription(psPid, outPath)
{
    startMs := A_TickCount
    lastNotify := 0
    hardCapMs := 600000   ; 10 分钟
    loop {
        if FileExist(outPath)
            return 1
        if !ProcessExist(psPid)
            return FileExist(outPath) ? 1 : 0
        elapsedSec := (A_TickCount - startMs) // 1000
        ; 每 30s 提醒一次 "还在跑"
        if (elapsedSec >= 30 && elapsedSec - lastNotify >= 30) {
            TrayTip "转写中...", "已等待 " elapsedSec " 秒", 1
            lastNotify := elapsedSec
        }
        if (A_TickCount - startMs >= hardCapMs)
            return -1
        Sleep 200
    }
}

; === Preview renderer lifecycle ===

; Launch the preview renderer (RENDERER_AHK_SCRIPT — currently the
; Edit-control fallback for v0.1) if not already running. Passes our
; own PID as watchdog arg and STREAM_PARTIAL_FILE as the partial text path.
; Idempotent: if g_RendererPid is alive, does nothing.
StartRenderer()
{
    global g_RendererPid, RENDERER_AHK_SCRIPT, AHK64_EXE_PATH,
           STREAM_PARTIAL_FILE
    if g_RendererPid && ProcessExist(g_RendererPid)
        return   ; already running

    logFile := EnvGet("LOCALAPPDATA") . "\voice-stt\renderer.log"
    ts := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")

    if !FileExist(RENDERER_AHK_SCRIPT) {
        TrayTip "renderer 启动失败", "找不到 " RENDERER_AHK_SCRIPT, 3
        try FileAppend("[" ts "] [err] script-missing: " RENDERER_AHK_SCRIPT "`n", logFile, "UTF-8")
        g_RendererPid := 0
        return
    }

    try {
        ; Args: parent_pid  partial_file
        ; NB: AHK v2.0.26 没有 A_ProcessID built-in（v1 才有），读它会抛 UnsetError；
        ;     用 ProcessExist() 不带参数返回当前进程 PID。
        parentPid := ProcessExist()
        cmd := Format('"{1}" "{2}" {3} "{4}"',
            AHK64_EXE_PATH,
            RENDERER_AHK_SCRIPT,
            parentPid,
            STREAM_PARTIAL_FILE)
        Run(cmd, , "Hide", &outPid)
        g_RendererPid := outPid
        try FileAppend("[" ts "] [ok] spawn renderer pid=" outPid " parent=" parentPid "`n", logFile, "UTF-8")
    } catch as e {
        TrayTip "renderer 启动异常", e.Message, 3
        try FileAppend("[" ts "] [err] " e.Message " (file=" (HasProp(e, "File") ? e.File : "?") " line=" (HasProp(e, "Line") ? e.Line : "?") ")`n", logFile, "UTF-8")
        g_RendererPid := 0
    }
}

; Write empty string to partial file, causing the renderer's next poll to
; call clearText() on the preview window.
ClearPreviewWindow()
{
    global STREAM_PARTIAL_FILE
    logFile := EnvGet("LOCALAPPDATA") . "\voice-stt\renderer.log"
    ts := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")

    ; Primary path: open + write empty + close.
    try {
        f := FileOpen(STREAM_PARTIAL_FILE, "w", "UTF-8")
        f.Write("")
        f.Close()
        return
    } catch as e1 {
        try FileAppend("[" ts "] [clear-warn] FileOpen failed: " e1.Message ", retrying via FileDelete+FileAppend`n", logFile, "UTF-8")
    }

    ; Fallback: file may be held by renderer's poll mid-read; try delete + re-create
    ; (log + retry instead of silently swallowing the failure).
    try {
        FileDelete STREAM_PARTIAL_FILE
        FileAppend("", STREAM_PARTIAL_FILE, "UTF-8")
        try FileAppend("[" ts "] [clear-ok-fallback] cleared via delete+append`n", logFile, "UTF-8")
    } catch as e2 {
        try FileAppend("[" ts "] [clear-err] both paths failed: " e2.Message " — next poll cycle will retry`n", logFile, "UTF-8")
    }
}

DoVoiceInput(duration)
{
    global WSL_HELPER_SCRIPT, WIN_TMP_FILE, WIN_ERR_FILE

    ; 记下热键按下瞬间的焦点窗口；粘贴时强制激活它
    target_hwnd := WinExist("A")
    TrayTip "录音中", duration " 秒，对着麦说话...", 1

    wslOutPath := WinTempToWslPath(WIN_TMP_FILE)
    for f in [WIN_TMP_FILE, WIN_ERR_FILE]
        if FileExist(f)
            FileDelete f

    ; 调 wsl.exe 直接跑 helper sh，避免 -lc 嵌套引号被 Windows 命令行 mangling
    ; helper 内部把 stderr 写到 OUT.err
    cmd := 'wsl.exe -e bash ' WSL_HELPER_SCRIPT ' ' duration ' ' wslOutPath
    RunWait cmd, , "Hide"
    release_hwnd := WinExist("A")   ; 录音结束的瞬间焦点 = 用户的 paste 意图

    if !FileExist(WIN_TMP_FILE) {
        errMsg := FileExist(WIN_ERR_FILE) ? FileRead(WIN_ERR_FILE, "UTF-8") : "WSL 没生成 stdout 文件"
        TrayTip "录音失败", SubStr(errMsg, 1, 200), 3
        ; 同时打开 err 文件给用户看
        if FileExist(WIN_ERR_FILE)
            Run "notepad.exe " WIN_ERR_FILE
        return
    }

    text := FileRead(WIN_TMP_FILE, "UTF-8")
    text := Trim(text, " `t`r`n")
    FileDelete WIN_TMP_FILE

    if text = "" {
        errMsg := FileExist(WIN_ERR_FILE) ? FileRead(WIN_ERR_FILE, "UTF-8") : "stdout 文件为空"
        TrayTip "转写为空", SubStr(errMsg, 1, 200), 3
        if FileExist(WIN_ERR_FILE)
            Run "notepad.exe " WIN_ERR_FILE
        return
    }

    if FileExist(WIN_ERR_FILE)
        FileDelete WIN_ERR_FILE

    used_hwnd := PasteAndRestoreClipboard(text, release_hwnd, target_hwnd)
    TrayTip "已粘贴 → " GetWindowTitle(used_hwnd), text, 1
}

; === Tap-Toggle：按一次开始、再按一次结束（不用按住）===
; 跟 PTT 同样的后端流程，只是不靠 KeyWait，靠状态机
DoVoiceToggle()
{
    global g_TogglingRecording, g_ToggleSig, g_ToggleWav, g_ToggleOut, g_ToggleErr, g_TogglePid, g_ToggleHwnd, PTT_PS_SCRIPT

    if !g_TogglingRecording {
        ; ===== 开始录音 =====
        g_ToggleHwnd := WinExist("A")   ; 记下用户当前在哪
        tick := A_TickCount
        g_ToggleSig := A_Temp "\voice-tog-" tick ".signal"
        g_ToggleWav := A_Temp "\voice-tog-" tick ".wav"
        g_ToggleOut := A_Temp "\voice-tog-" tick ".txt"
        g_ToggleErr := A_Temp "\voice-tog-" tick ".err"

        for f in [g_ToggleSig, g_ToggleWav, g_ToggleOut, g_ToggleErr]
            if FileExist(f)
                FileDelete f

        psCmd := 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass'
            . ' -File "' PTT_PS_SCRIPT '"'
            . ' -StopSignalPath "' g_ToggleSig '"'
            . ' -OutputPath "' g_ToggleWav '"'
            . ' -OutputText "' g_ToggleOut '"'
        cmd := A_ComSpec ' /c ' psCmd ' 2> "' g_ToggleErr '"'

        Run cmd, , "Hide", &outPid
        g_TogglePid := outPid
        g_TogglingRecording := true
        TrayTip "录音中（toggle）", "再按 Shift+Alt+B 停止", 1
        return
    }

    ; ===== 停止录音 =====
    g_TogglingRecording := false   ; 立刻翻状态，避免快速双击重入
    release_hwnd := WinExist("A")  ; 第二次按 hotkey 瞬间的焦点 = paste 意图
    TrayTip "录音结束", "转写中...", 1

    try {
        FileOpen(g_ToggleSig, "w").Close()
    } catch as e {
        TrayTip "Toggle 失败", "信号文件写入失败: " e.Message, 3
        return
    }

    waitResult := WaitForTranscription(g_TogglePid, g_ToggleOut)

    if !FileExist(g_ToggleOut) {
        errText := FileExist(g_ToggleErr) ? FileRead(g_ToggleErr, "UTF-8") : "(无 stderr)"
        errText := SubStr(Trim(errText, " `t`r`n"), 1, 300)
        reason := (waitResult = -1) ? "硬超时(>10min)" : (waitResult = 0) ? "PS 进程已死但无输出" : "未知"
        TrayTip "Toggle 失败", reason "`nstderr: " errText, 5
        if FileExist(g_ToggleErr)
            Run "notepad.exe " g_ToggleErr
        return
    }

    text := Trim(FileRead(g_ToggleOut, "UTF-8"), " `t`r`n")

    if text = "" {
        for f in [g_ToggleOut, g_ToggleSig, g_ToggleErr]
            SafeFileDelete f
        TrayTip "转写为空", "无声音或太短", 3
        return
    }

    used_hwnd := PasteAndRestoreClipboard(text, release_hwnd, g_ToggleHwnd)
    TrayTip "已粘贴 → " GetWindowTitle(used_hwnd), text, 1
    for f in [g_ToggleOut, g_ToggleSig, g_ToggleErr]
        SafeFileDelete f
}

; === 流式 PTT：按住边说边显示部分转写 ===
; PS 脚本把部分转写写到 STREAM_PARTIAL_FILE；renderer 进程每 100ms 轮询它。
; 旧的 ShowStreamGui / UpdateStreamGui / DestroyStreamGui 已被 StartRenderer /
; ClearPreviewWindow 替代。PTT 逻辑（KeyWait、信号文件、粘贴）保持不变。
DoVoiceStream()
{
    global STREAM_PS_SCRIPT, STREAM_PARTIAL_FILE
    dbg := EnvGet("LOCALAPPDATA") . "\voice-stt\stream-debug.log"
    target_hwnd := WinExist("A")   ; 热键按下时焦点窗口；粘贴时拉回去
    try {
        FileAppend Format("[{1}] === DoVoiceStream entered === target_hwnd={2} title='{3}'`n", FormatTime(, "yyyy-MM-dd HH:mm:ss"), target_hwnd, GetWindowTitle(target_hwnd)), dbg
    } catch {
    }

    try {
        tick := A_TickCount
        sig := A_Temp "\voice-stream-" tick ".signal"
        out := A_Temp "\voice-stream-" tick ".txt"
        err := A_Temp "\voice-stream-" tick ".err"

        for f in [sig, out, err, STREAM_PARTIAL_FILE]
            if FileExist(f)
                SafeFileDelete f

        ; WS 流式版没有 -OutputPath（音频不写 WAV，直接流到 WS server）
        ; -PartialTextPath 指向 STREAM_PARTIAL_FILE（renderer 的固定轮询路径）
        psCmd := 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass'
            . ' -File "' STREAM_PS_SCRIPT '"'
            . ' -StopSignalPath "' sig '"'
            . ' -OutputText "' out '"'
            . ' -PartialTextPath "' STREAM_PARTIAL_FILE '"'
        cmd := A_ComSpec ' /c ' psCmd ' 2> "' err '"'
        FileAppend Format("[{1}] cmd: {2}`n", FormatTime(, "HH:mm:ss"), cmd), dbg

        Run cmd, , "Hide", &psPid
        FileAppend Format("[{1}] launched psPid={2}`n", FormatTime(, "HH:mm:ss"), psPid), dbg

        ; Launch (or reuse) the WebView2 renderer. It will pick up
        ; STREAM_PARTIAL_FILE on its next poll cycle automatically.
        StartRenderer()
        FileAppend Format("[{1}] renderer started/running`n", FormatTime(, "HH:mm:ss")), dbg

        KeyWait "s"
        release_hwnd := WinExist("A")  ; 松开瞬间焦点 = 用户的 paste 意图，不追后续点击
        FileAppend Format("[{1}] KeyWait S returned release_hwnd={2} title='{3}'`n", FormatTime(, "HH:mm:ss"), release_hwnd, GetWindowTitle(release_hwnd)), dbg

        try {
            FileOpen(sig, "w").Close()
        } catch as e {
            FileAppend Format("[{1}] FileOpen sig failed: {2}`n", FormatTime(, "HH:mm:ss"), e.Message), dbg
            ClearPreviewWindow()
            TrayTip "Stream 失败", "信号文件写入失败: " e.Message, 3
            return
        }

        result := WaitForTranscription(psPid, out)
        FileAppend Format("[{1}] WaitForTranscription returned: {2}`n", FormatTime(, "HH:mm:ss"), result), dbg

        ; Clear caption regardless of transcription success
        ClearPreviewWindow()

        if !FileExist(out) {
            errText := FileExist(err) ? FileRead(err, "UTF-8") : "(无 stderr)"
            FileAppend Format("[{1}] FAILED: no out file. err='{2}'`n", FormatTime(, "HH:mm:ss"), SubStr(errText,1,200)), dbg
            WriteRecoveryRecord("", tick, target_hwnd, release_hwnd, 0, "no_out")
            TrayTip "Stream 失败", SubStr(errText, 1, 300), 5
            if FileExist(err)
                Run "notepad.exe " err
            return
        }

        text := Trim(FileRead(out, "UTF-8"), " `t`r`n")
        FileAppend Format("[{1}] read out: '{2}' ({3} chars)`n", FormatTime(, "HH:mm:ss"), SubStr(text,1,80), StrLen(text)), dbg

        if text = "" {
            WriteRecoveryRecord("", tick, target_hwnd, release_hwnd, 0, "empty")
            for f in [out, sig, err]
                SafeFileDelete f
            TrayTip "转写为空", "无声音或太短", 3
            return
        }

        ; Paste-target 安全门: 录音 < 30s 且 press == release 静默走原路径;
        ; 否则 MsgBox 3s 倒计时确认, 超时不粘 (文本已落 recovery log).
        duration_sec := Round((A_TickCount - tick) / 1000, 2)
        paste_decision := ConfirmPaste(duration_sec, target_hwnd, release_hwnd, text)
        FileAppend Format("[{1}] paste-decision: status={2} duration={3}s press={4} release={5}`n", FormatTime(, "HH:mm:ss"), paste_decision, duration_sec, target_hwnd, release_hwnd), dbg
        if paste_decision = "ok" {
            ; press_hwnd 在新设计里是权威目标. PasteAndRestoreClipboard 两参相同 = 强制走 press.
            used_hwnd := PasteAndRestoreClipboard(text, target_hwnd, target_hwnd)
            WriteRecoveryRecord(text, tick, target_hwnd, release_hwnd, used_hwnd, "ok")
            TrayTip "已粘贴 → " GetWindowTitle(used_hwnd), text, 1
            FileAppend Format("[{1}] === pasted: press={2} release={3} used={4} title='{5}' ===`n`n", FormatTime(, "HH:mm:ss"), target_hwnd, release_hwnd, used_hwnd, GetWindowTitle(used_hwnd)), dbg
        } else {
            WriteRecoveryRecord(text, tick, target_hwnd, release_hwnd, 0, paste_decision)
            TrayTip "未粘贴 [" paste_decision "]", "文本已存 transcripts JSONL, 用 transcript-grep.sh 取回", 4
            FileAppend Format("[{1}] === skipped paste: status={2} ===`n`n", FormatTime(, "HH:mm:ss"), paste_decision), dbg
        }
        for f in [out, sig, err]
            SafeFileDelete f
    } catch as e {
        try {
            ClearPreviewWindow()
        } catch {
        }
        try {
            FileAppend Format("[{1}] EXCEPTION: {2}`n  at {3}:{4}`n", FormatTime(, "HH:mm:ss"), e.Message, e.File, e.Line), dbg
        } catch {
        }
        TrayTip "Stream 异常", e.Message, 5
    }
}

; 把 C:\Users\<USERNAME>\AppData\Local\Temp\file.txt 转成 /mnt/c/Users/<USERNAME>/AppData/Local/Temp/file.txt
WinTempToWslPath(winPath) {
    p := StrReplace(winPath, "\", "/")
    p := RegExReplace(p, "^([A-Za-z]):", "/mnt/$L1")
    return p
}

; === PTT：按住 Shift+Alt+V 录音，松开转写 ===
; 流程：
;   1. 按下 → 起 powershell voice-ptt.ps1（无 -Duration，等信号文件）
;   2. KeyWait "v" 阻塞，直到 V 松开
;   3. 创建信号文件 → voice-ptt.ps1 给 ffmpeg 写 'q' → ffmpeg 干净退出 → 上传转写 → 写文本文件
;   4. ProcessWaitClose 等 PS 结束 → 读文本 → 粘贴
DoVoicePTT()
{
    global PTT_PS_SCRIPT

    target_hwnd := WinExist("A")   ; 记下热键按下时的焦点窗口
    tick := A_TickCount
    sig := A_Temp "\voice-stt-" tick ".signal"
    wav := A_Temp "\voice-stt-" tick ".wav"
    out := A_Temp "\voice-stt-" tick ".txt"
    err := A_Temp "\voice-stt-" tick ".err"
    dbg := EnvGet("LOCALAPPDATA") . "\voice-stt\ptt-debug.log"

    ; 清理可能的残留
    for f in [sig, wav, out, err]
        if FileExist(f)
            FileDelete f

    TrayTip "PTT 录音中", "按住 V 说话，松开停止...", 1

    ; 用 cmd.exe 包一层让 PS 的 stderr 写到 err 文件（AHK Run 自身不支持 shell 重定向）
    ; -NonInteractive 让 PS 在缺参数时直接报错而不是阻塞 stdin prompt
    psCmd := 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass'
        . ' -File "' PTT_PS_SCRIPT '"'
        . ' -StopSignalPath "' sig '"'
        . ' -OutputPath "' wav '"'
        . ' -OutputText "' out '"'
    cmd := A_ComSpec ' /c ' psCmd ' 2> "' err '"'

    ; 写 debug 日志：记录每次调用的 cmd 跟时间戳
    try {
        FileAppend Format("[{1}] PTT cmd: {2}`n", FormatTime(, "yyyy-MM-dd HH:mm:ss"), cmd), dbg
    } catch {
    }

    runStart := A_TickCount
    Run cmd, , "Hide", &psPid
    try {
        FileAppend Format("[{1}] launched psPid={2}`n", FormatTime(, "HH:mm:ss"), psPid), dbg
    } catch {
    }

    ; 阻塞等 V 键松开
    KeyWait "v"
    release_hwnd := WinExist("A")  ; 松开瞬间焦点 = paste 目标
    holdMs := A_TickCount - runStart

    ; 立刻反馈"已停止录音"
    TrayTip "录音结束", "转写中...", 1

    ; 触发停止
    ; 注意：AHK v2 FileAppend "" 空 Text 不会创建文件！必须写实际内容或用 FileOpen("w")
    sigOk := false
    try {
        FileOpen(sig, "w").Close()
        sigOk := FileExist(sig) ? true : false
    } catch as e {
        try {
            FileAppend Format("[{1}] FileOpen sig 失败: {2}`n", FormatTime(, "HH:mm:ss"), e.Message), dbg
        } catch {
        }
        TrayTip "PTT 失败", "信号文件写入失败: " e.Message, 3
        return
    }
    try {
        FileAppend Format("[{1}] held={2}ms, sig 写入={3}, path={4}`n", FormatTime(, "HH:mm:ss"), holdMs, (sigOk ? "OK" : "FILE NOT FOUND"), sig), dbg
    } catch {
    }

    ; 等转写完成（解耦时长，看到 OutputText 文件就算成）
    waitStart := A_TickCount
    waitResult := WaitForTranscription(psPid, out)
    waitMs := A_TickCount - waitStart
    try {
        FileAppend Format("[{1}] WaitForTranscription: result={2}, wait={3}ms`n", FormatTime(, "HH:mm:ss"), waitResult, waitMs), dbg
    } catch {
    }

    if !FileExist(out) {
        errText := FileExist(err) ? FileRead(err, "UTF-8") : "(无 stderr 文件)"
        errText := SubStr(Trim(errText, " `t`r`n"), 1, 500)
        reason := (waitResult = -1) ? "硬超时(>10min)" : (waitResult = 0) ? "PS 进程已死但无输出" : "未知"
        diag := Format("psPid={1} held={2}ms wait={3}ms 原因={4}", psPid, holdMs, waitMs, reason)
        try {
            FileAppend Format("[{1}] FAILED: {2}`n--- stderr ---`n{3}`n", FormatTime(, "HH:mm:ss"), diag, errText), dbg
        } catch {
        }
        TrayTip "PTT 失败", diag "`nstderr: " SubStr(errText, 1, 150), 5
        if FileExist(err)
            Run "notepad.exe " err
        return
    }

    text := Trim(FileRead(out, "UTF-8"), " `t`r`n")

    if text = "" {
        for f in [out, sig, err]
            SafeFileDelete f
        TrayTip "转写为空", "按得太短或无声音", 3
        return
    }

    used_hwnd := PasteAndRestoreClipboard(text, release_hwnd, target_hwnd)
    TrayTip "已粘贴 → " GetWindowTitle(used_hwnd), text, 1
    for f in [out, sig, err]
        SafeFileDelete f
}

DoSapiTTS()
{
    saved := A_Clipboard
    A_Clipboard := ""
    Send "^c"
    if !ClipWait(0.3) {
        A_Clipboard := saved
        TrayTip "没选中文本", "选中要读的词后再按 Shift+Alt+P", 1
        return
    }
    text := A_Clipboard
    A_Clipboard := saved
    if StrLen(text) > 500 {
        TrayTip "文本太长", "限制 500 字以内", 1
        return
    }
    tmpFile := A_Temp "\sapi-tts-" A_TickCount ".txt"
    FileAppend(text, tmpFile, "UTF-8")
    sapiPath := A_ScriptDir . "\sapi-tts.ps1"
    Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' sapiPath '" -TextFile "' tmpFile '"', , "Hide")
    ; tmpFile 不立刻删——PS 还要读；2s 后单次 timer 清理
    SetTimer(() => FileExist(tmpFile) ? FileDelete(tmpFile) : 0, -2000)
}

; === mic warm-capture daemon control ===

; Run voice-mic-daemon.ps1 hidden, stash PID in g_DaemonPid. Idempotent.
; +!w 手动重启 / AHK 启动时自动调用.
StartDaemon()
{
    global g_DaemonPid, DAEMON_PS_SCRIPT
    if g_DaemonPid && ProcessExist(g_DaemonPid) {
        TrayTip "mic daemon 已在跑", "pid=" g_DaemonPid, 1
        return
    }
    if !FileExist(DAEMON_PS_SCRIPT) {
        TrayTip "mic daemon 启动失败", "找不到 " DAEMON_PS_SCRIPT, 3
        g_DaemonPid := 0
        return
    }
    cmd := 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' DAEMON_PS_SCRIPT '"'
    try {
        Run cmd, , "Hide", &outPid
        g_DaemonPid := outPid
        TrayTip "mic daemon 启动", "pid=" outPid " · Shift+Alt+Q 临时停掉让出 mic", 2
    } catch as e {
        TrayTip "mic daemon 启动异常", e.Message, 3
        g_DaemonPid := 0
    }
}

; Kill daemon (PS + 子 ffmpeg 树). 给 Zoom/Teams 让出 mic 时用 +!q.
QuitDaemon()
{
    global g_DaemonPid
    if g_DaemonPid && ProcessExist(g_DaemonPid) {
        ; taskkill /T 杀整棵进程树, ffmpeg 子进程一起带走
        RunWait('taskkill /F /T /PID ' g_DaemonPid, , "Hide")
        TrayTip "mic daemon 已停止", "pid=" g_DaemonPid " · Shift+Alt+W 重启", 2
    } else {
        TrayTip "mic daemon 已经不在跑", "Shift+Alt+W 启动它", 1
    }
    g_DaemonPid := 0
}

; OnExit 回调: AHK 自身退出 (用户 Reload Script / 任务管理器结束 / 关机) 时:
;   1. kill mic daemon (防止 ffmpeg 残留独占 mic)
;   2. kill renderer (防止孤儿 WebView2 进程残留)
; 签名: (ExitReason, ExitCode).
OnAhkExit(ExitReason, ExitCode)
{
    global g_DaemonPid, g_RendererPid
    if g_DaemonPid && ProcessExist(g_DaemonPid) {
        try {
            RunWait('taskkill /F /T /PID ' g_DaemonPid, , "Hide")
        } catch {
        }
    }
    if g_RendererPid && ProcessExist(g_RendererPid) {
        try {
            ProcessClose(g_RendererPid)
        } catch {
        }
    }
}
