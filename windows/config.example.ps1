# 复制为 config.ps1 后修改。脚本不强依赖此文件，也可通过环境变量传参。
# 在 PowerShell 里 source：. .\config.ps1

$env:GATEWAY_URL   = 'http://YOUR_GPU_TAILSCALE_NAME:8080'
$env:WHISPER_LANG  = 'zh'
$env:WHISPER_MODEL = 'large-v3-turbo'
