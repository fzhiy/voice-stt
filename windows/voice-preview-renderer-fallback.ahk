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
WIN_H            := 120    ; logical px

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
previewGui.MarginX := 0
previewGui.MarginY := 0

; Edit control options: NO '+' prefix on keyword options (trap: ahk-edit-options-no-plus-prefix).
; Plain keywords: Multi ReadOnly Wrap Background<hex> c<hex>
; Font: Microsoft YaHei Bold 15pt — matches caption look.
previewGui.SetFont("s15 Bold c" . "CDD6F4", "Microsoft YaHei")
editCtrl := previewGui.AddEdit(
    Format("w{1} h{2} Multi ReadOnly Wrap Background1E1E2E cCDD6F4", WIN_W, WIN_H), "")

previewGui.OnEvent("Close", (*) => ExitApp())

; Cold-start state determined by partial.txt content. Empty/missing → start
; offscreen so user never sees an empty dark band. Pre-filled → start onscreen
; so cold-start P0 passes within 1500ms.
initialText := ""
try initialText := FileRead(PARTIAL_FILE, "UTF-8")
catch
    initialText := ""

if initialText != "" {
    previewGui.Show(Format("w{1} h{2} x{3} y{4} NoActivate", WIN_W, WIN_H, ONSCREEN_X, ONSCREEN_Y))
    editCtrl.Value := initialText
    g_OnScreen := true
    g_LastText := initialText
} else {
    previewGui.Show(Format("w{1} h{2} x{3} y{4} NoActivate", WIN_W, WIN_H, OFFSCREEN_X, OFFSCREEN_Y))
    g_OnScreen := false
    g_LastText := ""
}

; Set constant alpha ONCE — applies regardless of window position.
WinSetTransparent(230, previewGui.Hwnd)
Trace(Format("gui shown hwnd={1} onScreen={2}", previewGui.Hwnd, g_OnScreen))

; ---------------- Polling ----------------

; g_LastText + g_OnScreen initialized above in cold-start block.

PollPartial() {
    global editCtrl, g_LastText, PARTIAL_FILE, previewGui,
           ONSCREEN_X, ONSCREEN_Y, OFFSCREEN_X, OFFSCREEN_Y, g_OnScreen

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
    } else if text == "" && g_OnScreen {
        WinMove OFFSCREEN_X, OFFSCREEN_Y, , , previewGui.Hwnd
        g_OnScreen := false
    }

    if text != "" {
        ; Scroll to end — EM_SETSEL (-1,-1) then EM_SCROLLCARET (0xB7).
        SendMessage(0x00B1, -1, -1, editCtrl.Hwnd)
        SendMessage(0x00B7,  0,  0, editCtrl.Hwnd)
    }
}

SetTimer PollPartial, POLL_INTERVAL_MS
Trace(Format("polling started interval={1}ms", POLL_INTERVAL_MS))

; ---------------- Cleanup ----------------

OnExit (*) => Trace("fallback exit")
