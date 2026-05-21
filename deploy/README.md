# 部署脚本

> **Maintainer-only / 仅维护者使用。** 普通最终用户无需阅读本目录 —— Windows
> 客户端的安装走根目录 `install.ps1`/`start.bat`（详见
> [docs/QUICKSTART.md](../docs/QUICKSTART.md)）。本目录的脚本用于把 `server/`
> 同步到一台你拥有 SSH 访问权限的 GPU 主机（`~/voice-stack/`），属于自托管
> 部署的运维工具。若你只是想 dictate 而不打算自建 ASR 服务端，可整目录跳过。

| 脚本 | 作用 | 是否破坏性 |
|---|---|---|
| `deploy-server.sh` | rsync `server/` → 远端 GPU 主机的 `~/voice-stack/`，可选启动容器 | 仅作用于 `~/voice-stack/` |
| `verify-stack.sh` | 远程跑 `test-pipeline.sh` | 只读 |
| `tailscale-status.sh` | 本机查 Tailnet + 测 Gateway 连通 | 只读 |

## 部署流程

```bash
# 1. 填配置
cp ../.env.example ../.env
# 编辑 GPU_HOST、GPU_TAILSCALE

# 2. 部署
bash deploy-server.sh

# 3. 验证
bash tailscale-status.sh
bash verify-stack.sh
```

## 安全承诺

- `deploy-server.sh` 在远端 GPU 主机上**只执行**：
  - `mkdir -p ~/voice-stack`
  - `rsync ... ~/voice-stack/`
  - `cd ~/voice-stack && docker compose up -d`（用户回车确认后）
  - `docker compose exec ollama ollama pull ...`
- **不**执行：`apt install`、`systemctl ...`、改 `/etc`、改 dotfiles
- 若远端缺 `docker` 或 `nvidia-container-toolkit`，**仅提示**，**不自动安装**
- 完全卸载只需远端 `cd ~/voice-stack && docker compose down -v && cd .. && rm -rf voice-stack`
