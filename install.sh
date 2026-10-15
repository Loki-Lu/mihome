#!/bin/bash
# ============================================================
# mihomo(无GUI) + Codex CLI 一键安装脚本
# 适用: x86_64 Linux, root 权限, 需要 curl 和 python3
#
# 用法:
#   bash install.sh <clash订阅链接> [--watchdog]
#
# 可选环境变量:
#   MIHOMO_VERSION  mihomo 版本号, 默认 v1.19.30
#   GROUP_NAME      主选择分组名, 默认 "🔰 选择节点"
#   NODE_KEYWORD    自动选中的节点关键词, 默认 "日本" (OpenAI 不支持香港)
#   SKIP_CODEX=1    跳过 Codex CLI 安装
#
# 注意: 订阅链接含个人 token, 只通过参数传入, 不要写入文件/提交仓库
# ============================================================
set -uo pipefail

MIHOMO_DIR="/opt/mihomo"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.30}"
GEO_TAG="latest"
API="http://127.0.0.1:9090"
PROXY="http://127.0.0.1:7890"
CONFIG_NAME="config_ylink.yaml"
GROUP_NAME="${GROUP_NAME:-🔰 选择节点}"
NODE_KEYWORD="${NODE_KEYWORD:-日本}"
SKIP_CODEX="${SKIP_CODEX:-0}"
SUB_URL="${1:-}"
OPT_WATCHDOG="${2:-}"

MIRRORS=("https://gh-proxy.com" "https://ghproxy.net" "https://ghfast.top" "")

log() { echo "[install] $*"; }
die() { echo "[install][错误] $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"
[ -n "$SUB_URL" ] || die "用法: bash $0 <clash订阅链接> [--watchdog]"
command -v curl >/dev/null || die "缺少 curl"
command -v python3 >/dev/null || die "缺少 python3"

# GitHub 下载: 镜像加速 + 断点续传. dl_gh <仓库内路径> <输出文件> <最小字节数>
dl_gh() {
    local path="$1" out="$2" min="$3" base attempt sz
    if [ -f "$out" ] && [ "$(stat -c%s "$out" 2>/dev/null || echo 0)" -ge "$min" ]; then
        log "已存在, 跳过: $out"
        return 0
    fi
    for attempt in 1 2 3 4 5; do
        for base in "${MIRRORS[@]}"; do
            curl -fsL -C - --max-time 90 -o "$out" \
                "${base:+${base}/}https://github.com/$path" 2>/dev/null
            sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
            [ "$sz" -ge "$min" ] && return 0
        done
    done
    rm -f "$out"
    return 1
}

download_geo() {
    dl_gh "MetaCubeX/meta-rules-dat/releases/download/$GEO_TAG/geoip.metadb" \
        "$MIHOMO_DIR/geoip.metadb" 2000000 || return 1
    dl_gh "MetaCubeX/meta-rules-dat/releases/download/$GEO_TAG/geosite.dat" \
        "$MIHOMO_DIR/geosite.dat" 1000000 || return 1
}

mkdir -p "$MIHOMO_DIR"

# ---------- 1. mihomo 二进制 ----------
if [ -x "$MIHOMO_DIR/mihomo" ] && "$MIHOMO_DIR/mihomo" -v >/dev/null 2>&1; then
    log "mihomo 已安装: $("$MIHOMO_DIR/mihomo" -v | head -1)"
else
    log "下载 mihomo $MIHOMO_VERSION ..."
    ARCH_ASSET="compatible"
    grep -qm1 avx2 /proc/cpuinfo && ARCH_ASSET="v3"
    dl_gh "MetaCubeX/mihomo/releases/download/$MIHOMO_VERSION/mihomo-linux-amd64-$ARCH_ASSET-$MIHOMO_VERSION.gz" \
        /tmp/mihomo.gz 1000000 || die "mihomo 下载失败"
    gunzip -f /tmp/mihomo.gz && chmod +x /tmp/mihomo \
        && mv -f /tmp/mihomo "$MIHOMO_DIR/mihomo" || die "mihomo 解压失败"
    "$MIHOMO_DIR/mihomo" -v >/dev/null 2>&1 || die "mihomo 二进制无法运行"
    log "mihomo 安装完成: $("$MIHOMO_DIR/mihomo" -v | head -1)"
fi

# ---------- 2. GeoIP / GeoSite 数据库 ----------
log "下载 GeoIP/GeoSite 数据库 ..."
download_geo || die "geo 数据库下载失败"

# ---------- 3. 订阅配置 ----------
log "下载订阅配置 ..."
curl -fsSL --max-time 60 -A "clash.meta" \
    -o "$MIHOMO_DIR/$CONFIG_NAME" "$SUB_URL" || die "订阅下载失败, 检查链接是否有效"
grep -q "^proxies:" "$MIHOMO_DIR/$CONFIG_NAME" \
    || die "订阅返回的不是 Clash YAML (确认链接带 ?clash=3 参数)"
if ! grep -q "^external-controller:" "$MIHOMO_DIR/$CONFIG_NAME"; then
    echo "external-controller: 127.0.0.1:9090" >> "$MIHOMO_DIR/$CONFIG_NAME"
    log "已追加 external-controller 配置 (看门狗切节点依赖它)"
fi

# ---------- 4. 校验配置 (geo 文件损坏则重下一次) ----------
test_config() {
    "$MIHOMO_DIR/mihomo" -t -d "$MIHOMO_DIR" -f "$MIHOMO_DIR/$CONFIG_NAME" >/dev/null 2>&1
}
if ! test_config; then
    log "配置校验失败, 重下 geo 数据库后重试 ..."
    rm -f "$MIHOMO_DIR/geoip.metadb" "$MIHOMO_DIR/geosite.dat"
    download_geo || die "geo 数据库下载失败"
    test_config || die "配置仍校验失败, 手动排查: $MIHOMO_DIR/mihomo -t -d $MIHOMO_DIR -f $MIHOMO_DIR/$CONFIG_NAME"
fi
log "配置校验通过"

# ---------- 5. 启动 mihomo ----------
pkill -x mihomo 2>/dev/null; sleep 1
# setsid 双重脱离: 避免 mihomo 成为脚本子进程导致脚本退出时挂起
( cd "$MIHOMO_DIR"; setsid ./mihomo -d "$MIHOMO_DIR" -f "$MIHOMO_DIR/$CONFIG_NAME" \
    > "$MIHOMO_DIR/mihomo.log" 2>&1 < /dev/null & )
for _ in $(seq 1 15); do
    curl -s --max-time 2 "$API/version" >/dev/null 2>&1 && break
    sleep 1
done
curl -s --max-time 3 "$API/version" >/dev/null || die "API 未就绪, 查看日志: tail $MIHOMO_DIR/mihomo.log"
log "mihomo 已启动, API: $API"

# ---------- 6. 选中节点 (默认日本, OpenAI 不支持香港) ----------
genc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$GROUP_NAME")
node=$(curl -s --max-time 5 "$API/proxies/$genc" \
    | python3 -c "import sys,json;[print(n) for n in json.load(sys.stdin).get('all',[])]" 2>/dev/null \
    | grep -m1 "$NODE_KEYWORD" || true)
if [ -n "$node" ]; then
    curl -s -X PUT "$API/proxies/$genc" -H 'Content-Type: application/json' \
        -d "$(python3 -c "import json,sys;print(json.dumps({'name':sys.argv[1]}))" "$node")" >/dev/null
    log "已选中节点: $node"
else
    log "警告: 没有匹配 '$NODE_KEYWORD' 的节点, 保持订阅默认选择"
fi

# ---------- 7. 验证代理 ----------
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x "$PROXY" \
    https://www.google.com/generate_204)
[ "$code" = "204" ] || die "代理验证失败 (HTTP $code), 检查节点是否可用"
log "代理验证通过 (google generate_204 -> 204)"
curl -s --max-time 10 -x "$PROXY" https://api.ip.sb/geoip 2>/dev/null \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('[install] 出口:',d.get('country'),d.get('ip'))" 2>/dev/null || true

# ---------- 8. Codex CLI ----------
if [ "$SKIP_CODEX" = "1" ]; then
    log "跳过 Codex CLI (SKIP_CODEX=1)"
elif command -v codex >/dev/null 2>&1; then
    log "Codex CLI 已安装: $(codex --version)"
else
    log "安装 Codex CLI ..."
    export https_proxy="$PROXY" http_proxy="$PROXY"
    curl -fsSL --max-time 60 https://chatgpt.com/codex/install.sh -o /tmp/codex_install.sh \
        || die "Codex 安装脚本下载失败"
    CODEX_NON_INTERACTIVE=true sh /tmp/codex_install.sh || die "Codex 安装失败"
    command -v codex >/dev/null 2>&1 || die "codex 命令不可用"
    log "Codex 安装完成: $(codex --version)"
fi

# ---------- 9. 可选: 部署看门狗 ----------
if [ "$OPT_WATCHDOG" = "--watchdog" ]; then
    cat > "$MIHOMO_DIR/watchdog.sh" <<'WD'
#!/bin/bash
# mihomo 看门狗: 日志 i/o timeout 计数重启 + 周期健康检查切节点
MIHOMO_BIN="/opt/mihomo/mihomo"
MIHOMO_ARGS="-d /opt/mihomo -f /opt/mihomo/config_ylink.yaml"
API="${API:-http://127.0.0.1:9090}"
PROXY="${PROXY:-http://127.0.0.1:7890}"
CHECK_URL="${CHECK_URL:-https://www.google.com/generate_204}"
CHECK_INTERVAL="${CHECK_INTERVAL:-120}"
CHECK_FAIL_THRESHOLD=3
SWITCH_GROUPS=("🔰 选择节点" "🐟 漏网之鱼")   # 分组名含空格, 必须用数组遍历
TIMEOUT_THRESHOLD=3
TIMEOUT_WINDOW=60
RESTART_COOLDOWN=5

ts() { date '+%F %T'; }
urlenc() { python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }

cleanup() {
    echo "[watchdog][$(ts)] 退出"
    [ -n "${HEALTH_PID:-}" ] && kill "$HEALTH_PID" 2>/dev/null
    pkill -x mihomo 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

switch_group() {
    local group="$1" genc nodes n nenc delay
    genc=$(urlenc "$group")
    nodes=$(curl -s --max-time 5 "$API/proxies/$genc" \
        | python3 -c "import sys,json;[print(x) for x in json.load(sys.stdin).get('all',[])]" 2>/dev/null)
    [ -z "$nodes" ] && return 1
    while IFS= read -r n; do
        case "$n" in
            DIRECT|REJECT|GLOBAL|*"选择"*|*"漏网"*|*"直连"*|*"媒体"*|*"服务"*|*"信息"*|*"拦截"*|*"广告"*|*"流量"*|*"到期"*|*"重置"*|*"国内"*|*"Steam"*|*"学术"*) continue ;;
        esac
        nenc=$(urlenc "$n")
        delay=$(curl -s --max-time 8 "$API/proxies/$nenc/delay?url=${CHECK_URL}&timeout=6000" \
            | python3 -c "import sys,json;print(json.load(sys.stdin).get('delay',''))" 2>/dev/null)
        if [ -n "$delay" ]; then
            curl -s -X PUT "$API/proxies/$genc" -H 'Content-Type: application/json' \
                -d "$(python3 -c "import json,sys;print(json.dumps({'name':sys.argv[1]}))" "$n")" >/dev/null
            echo "[watchdog][$(ts)] 切换 $group -> $n (${delay}ms)"
            return 0
        fi
    done <<< "$nodes"
    return 1
}

health_loop() {
    local fails=0 code g
    sleep 20
    while true; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x "$PROXY" "$CHECK_URL" 2>/dev/null)
        if [ "$code" != "000" ] && [ "$code" != "403" ]; then
            [ "$fails" -gt 0 ] && echo "[watchdog][$(ts)] 健康检查恢复 (HTTP $code)"
            fails=0
            sleep "$CHECK_INTERVAL"
            continue
        fi
        fails=$((fails + 1))
        echo "[watchdog][$(ts)] 健康检查失败 ${fails}/${CHECK_FAIL_THRESHOLD} (HTTP $code)"
        if [ "$fails" -ge "$CHECK_FAIL_THRESHOLD" ]; then
            for g in "${SWITCH_GROUPS[@]}"; do
                if switch_group "$g"; then
                    sleep 2
                    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x "$PROXY" "$CHECK_URL" 2>/dev/null)
                    if [ "$code" != "000" ] && [ "$code" != "403" ]; then
                        echo "[watchdog][$(ts)] 切换后恢复 (HTTP $code)"
                        fails=0
                        break
                    fi
                fi
            done
            if [ "$fails" -ge "$CHECK_FAIL_THRESHOLD" ]; then
                echo "[watchdog][$(ts)] 无健康节点, 重启 mihomo"
                pkill -x mihomo 2>/dev/null
                fails=0
                sleep "$RESTART_COOLDOWN"
            fi
        fi
        sleep "$CHECK_INTERVAL"
    done
}

echo "[watchdog][$(ts)] 看门狗启动"
while true; do
    timeout_count=0
    first_timeout_ts=0
    echo "[watchdog][$(ts)] 启动 mihomo..."
    health_loop &
    HEALTH_PID=$!
    $MIHOMO_BIN $MIHOMO_ARGS 2>&1 | while IFS= read -r line; do
        echo "$line"
        if echo "$line" | grep -q "i/o timeout"; then
            now=$(date +%s)
            if [ "$first_timeout_ts" -eq 0 ] || [ $((now - first_timeout_ts)) -gt "$TIMEOUT_WINDOW" ]; then
                timeout_count=0
                first_timeout_ts=$now
            fi
            timeout_count=$((timeout_count + 1))
            echo "[watchdog] timeout 计数: $timeout_count/$TIMEOUT_THRESHOLD"
            if [ "$timeout_count" -ge "$TIMEOUT_THRESHOLD" ]; then
                echo "[watchdog][$(ts)] 达到阈值, 执行重启"
                pkill -x mihomo 2>/dev/null
                break
            fi
        fi
    done
    kill "$HEALTH_PID" 2>/dev/null
    HEALTH_PID=""
    echo "[watchdog][$(ts)] mihomo 已停止, ${RESTART_COOLDOWN}s 后重启..."
    sleep "$RESTART_COOLDOWN"
done
WD
    chmod +x "$MIHOMO_DIR/watchdog.sh"
    log "看门狗已部署: $MIHOMO_DIR/watchdog.sh"
    log "启动看门狗: nohup bash $MIHOMO_DIR/watchdog.sh > $MIHOMO_DIR/watchdog.log 2>&1 &"
fi

echo
log "全部完成 ✅"
log "代理端口: $PROXY   管理 API: $API"
log "Codex 使用前执行: export https_proxy=$PROXY http_proxy=$PROXY"
