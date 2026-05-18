# shellcheck shell=bash
# 共用函数：加载 .env、调用 Windows PowerShell

# 定位项目根（不依赖 cwd）
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export PROJECT_DIR

# 加载 .env（不存在则只发警告）
load_env() {
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        set -a
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/.env"
        set +a
    elif [[ -f "$PROJECT_DIR/.env.example" ]]; then
        echo "[lib.sh] WARN: .env 不存在，使用默认值。请 cp .env.example .env 并填配置。" >&2
    fi
}

# Windows 端脚本目录（UNC 形式，PowerShell 可读）
get_win_script_dir() {
    wslpath -w "$PROJECT_DIR/windows"
}

# 探测 powershell.exe（兼容 appendWindowsPath=false）
find_powershell() {
    if [[ -n "${POWERSHELL_EXE:-}" && -x "$POWERSHELL_EXE" ]]; then
        echo "$POWERSHELL_EXE"; return 0
    fi
    if command -v powershell.exe >/dev/null 2>&1; then
        echo "powershell.exe"; return 0
    fi
    local candidates=(
        /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
        /mnt/c/Program\ Files/PowerShell/7/pwsh.exe
        /mnt/c/Program\ Files/PowerShell/6/pwsh.exe
    )
    for p in "${candidates[@]}"; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

# Gateway URL
# 优先级：
#   1. USE_TUNNEL=1 时强制走 127.0.0.1（前提 wsl/tunnel.sh 已起；v0.1 默认 OFF）
#   2. GPU_TAILSCALE
#   3. GPU_HOST 的 hostname 部分
#   4. localhost
gateway_url() {
    local host
    if [[ "${USE_TUNNEL:-0}" == "1" ]]; then
        host="127.0.0.1"
    elif [[ -n "${GPU_TAILSCALE:-}" ]]; then
        host="$GPU_TAILSCALE"
    elif [[ -n "${GPU_HOST:-}" ]]; then
        host="${GPU_HOST#*@}"
    else
        host="localhost"
    fi
    local port="${GATEWAY_PORT:-9080}"
    echo "http://${host}:${port}"
}

# 调 Windows 端录音并返回转写文本
# 用法：voice_transcribe [-d 秒数 | -i] [--keep]
voice_transcribe() {
    local duration=10
    local interactive=0
    local keep_wav=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--duration) duration="$2"; shift 2 ;;
            -i|--interactive) interactive=1; shift ;;
            --keep|--keep-wav) keep_wav=1; shift ;;
            *) shift ;;
        esac
    done

    local win_dir
    win_dir=$(get_win_script_dir)

    # 通过环境变量传 Gateway URL 给 PowerShell
    local url
    url=$(gateway_url)

    local ps_args=(
        '-NoProfile'
        '-ExecutionPolicy' 'Bypass'
        '-File' "${win_dir}\\voice-input.ps1"
        '-NoClipboard'
        '-GatewayUrl' "$url"
        '-Language' "${WHISPER_LANG:-zh}"
        '-Model' "${WHISPER_MODEL:-small}"
        '-DeviceId'  "${RECORD_DEVICE_ID:--1}"
        '-Rate'      "${RECORD_RATE:-16000}"
        '-Channels'  "${RECORD_CHANNELS:-1}"
        '-Bits'      "${RECORD_BITS:-16}"
        '-WarmupSec' "${RECORD_WARMUP_SEC:-0}"
        '-MicChannel' "${RECORD_MIC_CHANNEL:-left}"
    )
    if [[ -n "${RECORD_DEVICE_NAME:-}" ]]; then
        ps_args+=('-DeviceName' "$RECORD_DEVICE_NAME")
    fi
    if [[ "${USE_MCI:-0}" == "1" ]]; then
        ps_args+=('-UseMci')
    fi
    if [[ "${USE_WAVEIN:-0}" == "1" ]]; then
        ps_args+=('-UseWaveIn')
    fi
    if (( keep_wav )); then
        ps_args+=('-KeepWav')
    fi
    if (( interactive )); then
        ps_args+=('-Interactive')
    else
        ps_args+=('-Duration' "$duration")
    fi

    # 探测 powershell.exe（用户禁用了 appendWindowsPath，需要绝对路径）
    local ps_exe
    ps_exe=$(find_powershell) || {
        red "找不到 powershell.exe。请设 POWERSHELL_EXE=/mnt/c/...路径" >&2
        return 127
    }

    # PowerShell 输出含状态行（写到 stderr 已 OK，转写文本走 stdout）
    # voice-input.ps1 用 raw byte UTF-8 stdout 输出最终文本，状态走 Write-Host
    # stderr 重定向到固定 log，调试用 cat 看
    local err_log="${PROJECT_DIR}/wsl/.ps-stderr.log"
    "$ps_exe" "${ps_args[@]}" 2>"$err_log" | tr -d '\r'
    local rc=${PIPESTATUS[0]}
    if (( rc != 0 )); then
        red "PowerShell 退出码 $rc。stderr 日志：" >&2
        sed 's/^/    /' "$err_log" >&2
    elif [[ -s "$err_log" ]]; then
        # 即使 rc=0，PS 可能写过 stderr（如 Write-Host 状态行）；只在 VERBOSE=1 时显示
        if [[ "${VERBOSE:-0}" == "1" ]]; then
            yellow "PS stderr:" >&2
            sed 's/^/    /' "$err_log" >&2
        fi
    fi
    return $rc
}

# 检查 Gateway 健康
check_gateway() {
    local url
    url=$(gateway_url)
    if curl -fs --max-time 5 "${url}/health" >/dev/null 2>&1; then
        return 0
    fi
    curl -fs --max-time 5 "${url}/" >/dev/null 2>&1
}

# 红绿提示
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
