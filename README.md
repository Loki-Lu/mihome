# mihomo + Codex CLI 一键部署
<!-- export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export HTTP_PROXY=http://127.0.0.1:7890
export HTTPS_PROXY=http://127.0.0.1:7890 -->

在全新的 x86_64 Linux 服务器上，一键完成代理环境搭建：

- **mihomo**（无 GUI 版 Clash 内核）→ `/opt/mihomo/`
- **GeoIP / GeoSite 数据库** → `/opt/mihomo/`
- **机场订阅配置** → `/opt/mihomo/config_ylink.yaml`（链接通过参数传入，不落盘到脚本）
- **Codex CLI** → `~/.local/bin/codex`
- 可选 **看门狗** → `/opt/mihomo/watchdog.sh`（日志超时检测 + 健康检查自动切节点/重启）

GitHub 下载内置三个镜像加速 + 断点续传，国内服务器可直接运行。

## 前置要求

- x86_64 Linux，root 权限
- 已安装 `curl`、`python3`
- 一条 Clash 订阅链接（形如 `https://xxx/link/XXXX?clash=3&extend=1`）

## 快速开始

```bash
bash install.sh "https://你的订阅链接?clash=3&extend=1"          # 基础安装
bash install.sh "https://你的订阅链接?clash=3&extend=1" --watchdog  # 附带看门狗
```

脚本幂等，可重复执行（已装的部分自动跳过）；更新订阅节点列表也靠重跑它。

### 可选参数（环境变量）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `MIHOMO_VERSION` | `v1.19.30` | mihomo 版本 |
| `GROUP_NAME` | `🔰 选择节点` | 主选择分组名（需与订阅中一致） |
| `NODE_KEYWORD` | `日本` | 装完自动选中的节点关键词 |
| `SKIP_CODEX` | `0` | 设为 `1` 跳过 Codex 安装 |

## 安装后的文件

| 路径 | 说明 |
|---|---|
| `/opt/mihomo/mihomo` | mihomo 二进制 |
| `/opt/mihomo/config_ylink.yaml` | 订阅配置 |
| `/opt/mihomo/geoip.metadb` / `geosite.dat` | 分流数据库 |
| `/opt/mihomo/mihomo.log` | 运行日志 |
| `/opt/mihomo/watchdog.sh` | 看门狗（`--watchdog` 时生成） |
| `~/.local/bin/codex` | Codex CLI |

默认端口：代理 `7890`（HTTP/SOCKS 混合入口为订阅决定）、管理 API `9090`（仅监听 127.0.0.1）。

## 日常运维

```bash
# 状态
pgrep -ax mihomo
curl -s http://127.0.0.1:9090/version

# 停止 / 启动
pkill -x mihomo
cd /opt/mihomo && nohup ./mihomo -d /opt/mihomo -f config_ylink.yaml >> mihomo.log 2>&1 &

# 查看分组下的节点及当前选中
G=$(python3 -c "import urllib.parse;print(urllib.parse.quote('🔰 选择节点',safe=''))")
curl -s http://127.0.0.1:9090/proxies/$G | python3 -m json.tool

# 手动切节点
curl -s -X PUT http://127.0.0.1:9090/proxies/$G -H 'Content-Type: application/json' \
     -d '{"name":"🇯🇵 日本A01 | IEPL"}'

# 测某节点延迟
N=$(python3 -c "import urllib.parse;print(urllib.parse.quote('🇯🇵 日本A01 | IEPL',safe=''))")
curl -s "http://127.0.0.1:9090/proxies/$N/delay?url=https://www.google.com/generate_204&timeout=5000"

# 更新订阅节点（重跑安装脚本即可）
bash install.sh "https://你的订阅链接?clash=3&extend=1"
```

### 看门狗

```bash
# 启动（装完手动执行一次，建议配合 systemd 或 crontab @reboot 保活）
nohup bash /opt/mihomo/watchdog.sh > /opt/mihomo/watchdog.log 2>&1 &

# 停止（会连带停掉 mihomo）
pkill -f watchdog.sh
```

行为：60 秒窗口内日志出现 3 次 `i/o timeout` → 重启；每 120 秒走代理访问 `google/generate_204`，连续 3 次失败 → 依次在 `🔰 选择节点`、`🐟 漏网之鱼` 分组里找健康节点切换，找不到才重启。可用环境变量覆盖 `CHECK_URL`、`CHECK_INTERVAL` 等。

## Codex CLI 使用

```bash
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890   # 必须走代理
codex        # 首次使用按提示在浏览器完成登录
```

建议把 export 写进 `~/.bashrc`。

## 卸载

```bash
pkill -f watchdog.sh 2>/dev/null; pkill -x mihomo
rm -rf /opt/mihomo
rm -f ~/.local/bin/codex && rm -rf ~/.codex
```

## 注意事项

- **订阅链接含个人 token，等同于密码**：只放在命令参数里，不要写进脚本、文档或提交到任何仓库。
- OpenAI 不对香港地区提供服务，用 ChatGPT/Codex 请选日本、美国、新加坡、台湾等节点（脚本默认选日本）。
- 4090 端口 API 只监听本机；若要让局域网其他设备用此代理，需在配置中开启 `allow-lan: true` 并注意防火墙。
- curl 直接访问 chatgpt.com 会收到 403（Cloudflare 人机验证），属正常现象，不代表代理不可用。
- 自行搭建/使用代理需遵守当地法律法规。
