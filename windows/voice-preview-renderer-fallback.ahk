#Requires AutoHotkey v2.0
;
; voice-preview-renderer-fallback.ahk — B-mode caption renderer using a native
; Edit control. Used when WebView2 init fails (missing runtime / GPU issue).
;
; Same partial.txt polling protocol as the WebView2 renderer.
; Same window title, position, and dimensions for drop-in substitutability.
;
; Args:
;   1: parent AHK pid (watchdog)
;   2: partial.txt absolute path
;
; Known traps addressed:
;   - winsettransparent-breaks-layered: REMOVED. We never call WinSetTransparent
;     for visibility toggling. WS_EX_LAYERED is set ONCE at startup with constant
;     alpha 230 (set once after Show).
;   - ahk-edit-options-no-plus-prefix: Edit options use plain keywords (no '+' prefix)
;   - ahk-vs-powershell-dpi: SPI_GETWORKAREA for position (same as main renderer)
;   - first-show-must-be-visible-for-webview2-paint: N/A (no WebView2 here) but
;     we Show NoActivate on-screen for consistency
;
; Idle state: WinMove to (-32000, -32000) when partial.txt is empty, restore
; to on-screen position when partial.txt has content. This replaces the prior
; "stay visible at alpha 230 with empty Edit" pattern which left a 1000x120
; dark band visible during idle. WinMove does NOT touch WS_EX_LAYERED so the
; alpha 230 stays set and the layered-trap is avoided.
;

POLL_INTERVAL_MS := 100
WIN_W            := 1000   ; logical px
WIN_H            := 110    ; 3 行 + 上下 padding (跟之前 worktree 一致, 之前是 120 显得太高)
CORNER_RADIUS    := 18     ; SetWindowRgn 圆角半径. 不依赖 DWM, 直接窗口 region 裁剪, 跟 layered 兼容.

; Position: same SPI_GETWORKAREA logic as voice-preview-renderer.ahk
_wa := Buffer(16, 0)
DllCall("SystemParametersInfoW", "uint", 0x0030, "uint", 0, "ptr", _wa, "uint", 0)
_waL := NumGet(_wa, 0,  "int")
_waT := NumGet(_wa, 4,  "int")
_waR := NumGet(_wa, 8,  "int")
_waB := NumGet(_wa, 12, "int")
ONSCREEN_X := _waL + ((_waR - _waL) - WIN_W) // 2
ONSCREEN_Y := _waB - WIN_H - 60
OFFSCREEN_X := -32000   ; Windows convention for "off any monitor"
OFFSCREEN_Y := -32000

PARENT_PID  := A_Args.Length >= 1 ? Integer(A_Args[1]) : 0
PARTIAL_FILE := A_Args.Length >= 2 ? A_Args[2]
             : (EnvGet("LOCALAPPDATA") . "\voice-stt\partial.txt")

DEBUG_LOG := EnvGet("LOCALAPPDATA") . "\voice-stt\renderer-fallback.log"

Trace(msg) {
    global DEBUG_LOG
    line := Format("[{1}] {2}`n", FormatTime(, "HH:mm:ss"), msg)
    try {
        FileAppend(line, DEBUG_LOG, "UTF-8")
    } catch {
    }
}

Trace(Format("fallback start parent={1} partial={2}", PARENT_PID, PARTIAL_FILE))
Trace(Format("DPI={1} ONSCREEN_X={2} ONSCREEN_Y={3}", A_ScreenDPI, ONSCREEN_X, ONSCREEN_Y))

; ---------------- Watchdog ----------------

if PARENT_PID > 0 {
    SetTimer () => (ProcessExist(PARENT_PID) ? "" : ExitApp()), 2000
    Trace("watchdog active for parent pid " . PARENT_PID)
}

; ---------------- GUI ----------------

; WS_EX_NOACTIVATE + WS_EX_LAYERED set ONCE. Never toggled.
; Visibility is managed by WinMove offscreen/onscreen, NOT by
; WinSetTransparent — toggling alpha removes WS_EX_LAYERED and breaks the
; compositing layer (trap: winsettransparent-breaks-layered).
previewGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 +E0x00080000",
                  "voice-preview-fallback")
previewGui.BackColor := "1e1e2e"
; Margin = 0: 让 Edit 完全填满 client area, GUI bg 不会以"边框"形式露出.
; 之前试 12/8 padding 反而让 GUI bg 暗块经 alpha 230 看上去像浅色描边.
previewGui.MarginX := 0
previewGui.MarginY := 0

; Edit control options: NO '+' prefix on keyword options (trap: ahk-edit-options-no-plus-prefix).
; -VScroll / -HScroll: 关掉原生滚动条 (内容溢出时滑块跟着 partial 文本"滑动",难看;
;                      OLD WebView2 用 CSS overflow:hidden, 这里对齐).
; -Border: 杀 WS_BORDER (1px 黑线边).
; -E0x200: 杀 WS_EX_CLIENTEDGE (3D sunken edge — Edit 默认带的浅灰内陷感, 在 layered
;          + dark bg 上会看作浅色描边. 这才是用户感知的"白边框"主因).
; Font: Microsoft YaHei Bold 15pt — matches caption look.
previewGui.SetFont("s15 Bold c" . "CDD6F4", "Microsoft YaHei")
; +0x40 = ES_AUTOVSCROLL: 即便没 WS_VSCROLL 滚动条,内容超出可视区也允许 viewport
; 向下滚 (跟 EM_SCROLLCARET 配合工作). 没这个 flag, Edit 可能拒绝滚动,
; 老内容永远占着屏幕,新内容看不到 (用户实际观察到的现象).
editCtrl := previewGui.AddEdit(
    Format("w{1} h{2} Multi ReadOnly Wrap -VScroll -HScroll -Border -E0x200 +0x40 Background1E1E2E cCDD6F4",
           WIN_W, WIN_H), "")

; Timer pill (右上角的录音秒数). 跟 OLD preview.html 的 .timer 对齐:
; - 空 → 非空首次有 partial: 重置 g_RecordingStartMs, 开始 100ms 刷新
; - 非空 → 空 (idle): 清空文字 + 停 timer
; Static AddText 加在 Edit 之后, z-order 在上层; BackgroundTrans 让背景透出 Edit.
; 颜色 A6E3A1 是 Catppuccin Mocha Green, 跟 OLD HTML 的 .timer .dot 一致.
previewGui.SetFont("s10 Bold cA6E3A1", "Microsoft YaHei")
timerCtrl := previewGui.AddText(
    Format("x{1} y{2} w{3} h{4} Right BackgroundTrans",
           WIN_W - 78, 6, 70, 18), "")

g_RecordingStartMs := 0
g_TimerActive := false

; NOTE: Win11 圆角 (DWMWA_WINDOW_CORNER_PREFERENCE) 跟 WS_EX_LAYERED 互斥 — layered
; window 走旧 GDI compositing 路径, DWM 不画圆角. 想要圆角就得放弃 alpha 透明,
; 用 UpdateLayeredWindow + 预乘 alpha 自绘. 当前优先透明, 圆角直角妥协.

previewGui.OnEvent("Close", (*) => ExitApp())

; 不读 partial.txt 初始内容: 上次 session 残留可能让用户看到"上次的英文/中文短串".
; PS1 启动会删 partial.txt, 但 renderer poll 跟它有 race. 干脆 cold-start 一律 offscreen,
; 等首次新 partial 触发 empty→non-empty 转场再 onscreen.
previewGui.Show(Format("w{1} h{2} x{3} y{4} NoActivate", WIN_W, WIN_H, OFFSCREEN_X, OFFSCREEN_Y))
g_OnScreen := false
g_LastText := ""

; 真圆角: CreateRoundRectRgn + SetWindowRgn 直接裁剪窗口 region. 不依赖 DWM
; (DWMWA_WINDOW_CORNER_PREFERENCE 跟 layered 互斥, 这条路绕开), 在 WS_EX_LAYERED
; 窗口上也工作. 跟之前 worktree 一致.
hRgn := DllCall("CreateRoundRectRgn", "int", 0, "int", 0,
                "int", WIN_W + 1, "int", WIN_H + 1,
                "int", CORNER_RADIUS * 2, "int", CORNER_RADIUS * 2, "ptr")
DllCall("SetWindowRgn", "ptr", previewGui.Hwnd, "ptr", hRgn, "int", 1)

; Set constant alpha ONCE — applies regardless of window position.
WinSetTransparent(230, previewGui.Hwnd)
Trace(Format("gui shown hwnd={1} onScreen={2}", previewGui.Hwnd, g_OnScreen))

; ---------------- Polling ----------------

; g_LastText + g_OnScreen initialized above in cold-start block.

PollPartial() {
    global editCtrl, g_LastText, PARTIAL_FILE, previewGui,
           ONSCREEN_X, ONSCREEN_Y, OFFSCREEN_X, OFFSCREEN_Y, g_OnScreen,
           timerCtrl, g_RecordingStartMs, g_TimerActive

    if !FileExist(PARTIAL_FILE)
        return

    try text := FileRead(PARTIAL_FILE, "UTF-8")
    catch
        return

    if text == g_LastText
        return   ; coalesce

    g_LastText := text
    editCtrl.Value := text

    ; Visibility transition: empty <-> non-empty toggles WinMove offscreen.
    ; No WinSetTransparent — keeps WS_EX_LAYERED stable.
    if text != "" && !g_OnScreen {
        WinMove ONSCREEN_X, ONSCREEN_Y, , , previewGui.Hwnd
        g_OnScreen := true
        ; 录音 timer 启动: 首次有 partial 那一刻 = 录音开始 (跟 OLD preview.html 一致).
        g_RecordingStartMs := A_TickCount
        g_TimerActive := true
        SetTimer RefreshTimer, 100
    } else if text == "" && g_OnScreen {
        WinMove OFFSCREEN_X, OFFSCREEN_Y, , , previewGui.Hwnd
        g_OnScreen := false
        ; idle: 停 timer + 清显示.
        g_TimerActive := false
        SetTimer RefreshTimer, 0
        timerCtrl.Value := ""
    }

    if text != "" {
        ; Scroll to end — EM_SETSEL (-1,-1) then EM_SCROLLCARET (0xB7).
        SendMessage(0x00B1, -1, -1, editCtrl.Hwnd)
        SendMessage(0x00B7,  0,  0, editCtrl.Hwnd)
    }
}

; Timer pill 刷新: A_TickCount 取毫秒, 除 1000 转秒, 一位小数. 100ms 调一次.
RefreshTimer() {
    global timerCtrl, g_RecordingStartMs, g_TimerActive
    if !g_TimerActive {
        timerCtrl.Value := ""
        return
    }
    elapsed := (A_TickCount - g_RecordingStartMs) / 1000
    timerCtrl.Value := Format("{:.1f}s", elapsed)
}

SetTimer PollPartial, POLL_INTERVAL_MS
Trace(Format("polling started interval={1}ms", POLL_INTERVAL_MS))

; ---------------- Cleanup ----------------

OnExit (*) => Trace("fallback exit")
