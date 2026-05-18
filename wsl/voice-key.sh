#!/usr/bin/env bash
# Shell keymap integration: press Ctrl-X V at a bash / zsh prompt to record
# and insert the transcript at the cursor position.
#
# Enable (assuming your repo is at ~/voice-stt; adjust if you cloned elsewhere):
#   bash:  echo 'source ~/voice-stt/wsl/voice-key.sh' >> ~/.bashrc && source ~/.bashrc
#   zsh:   echo 'source ~/voice-stt/wsl/voice-key.sh' >> ~/.zshrc  && source ~/.zshrc
#
# Usage: at a bash/zsh prompt, Ctrl-X then V -> records VOICE_DURATION seconds
# -> transcript inserted at cursor (review before pressing Enter).
#
# Configurable env vars:
#   VOICE_INPUT_SCRIPT  path to voice-input.sh (default: alongside this script)
#   VOICE_DURATION      seconds to record (default 6)
#   VOICE_KEY           keybinding (default ^Xv = Ctrl-X V)

# Resolve voice-input.sh relative to this script (no repo path hardcoded).
_VOICE_KEY_SH_DIR="${BASH_SOURCE[0]:-${(%):-%x}}"
_VOICE_KEY_SH_DIR="$(cd "$(dirname "$_VOICE_KEY_SH_DIR")" 2>/dev/null && pwd)"
_VOICE_INPUT_SCRIPT="${VOICE_INPUT_SCRIPT:-$_VOICE_KEY_SH_DIR/voice-input.sh}"

_voice_input_run() {
    bash "$_VOICE_INPUT_SCRIPT" -d "${VOICE_DURATION:-6}" 2>/dev/null
}

if [[ -n "${ZSH_VERSION:-}" ]]; then
    _voice_input_widget() {
        local text
        text=$(_voice_input_run)
        if [[ -n "$text" ]]; then
            LBUFFER="${LBUFFER}${text}"
        fi
        zle redisplay
    }
    zle -N _voice_input_widget
    bindkey "${VOICE_KEY:-^Xv}" _voice_input_widget
elif [[ -n "${BASH_VERSION:-}" ]]; then
    _voice_input_widget() {
        local text
        text=$(_voice_input_run)
        if [[ -n "$text" ]]; then
            # 把转写文本插入当前光标位置
            READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}${text}${READLINE_LINE:$READLINE_POINT}"
            READLINE_POINT=$(( READLINE_POINT + ${#text} ))
        fi
    }
    bind -x '"\C-xv": _voice_input_widget'
fi
