#!/bin/sh
set -e

# =========================
# 环境变量
# =========================
ARGO_DOMAIN=${DD_DM:-""}
ARGO_AUTH=${DD_DD:-""}

# 伪装进程名（与 proc_shim.py 中的 FAKE_NAME 保持一致）
FAKE_PROC_NAME="dbus-daemon"

# PID 持久化文件，用于准确追踪进程
APP_PID_FILE="/tmp/app.pid"

# =========================
# 日志函数
# =========================
log_info()   { echo "[INFO]   $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_ok()     { echo "[OK]     $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error()  { echo "[ERROR]  $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_warn()   { echo "[WARN]   $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_status() { echo "[STATUS] $(date '+%Y-%m-%d %H:%M:%S') $1"; }

# =========================
# 辅助函数
# =========================
wait_for_port() {
    port=$1
    timeout=$2
    for i in $(seq 1 $timeout); do
        if curl -s "http://127.0.0.1:$port" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

CHECK_COUNT=0
APP_RESTART_COUNT=0
MAX_RESTART=5
LAST_RESTART_TIME=0
RESTART_COOLDOWN=120

# ---------------------------------------------------------
# get_app_status
# 通过 PID 文件判断进程存活 + HTTP 健康检查
# 不依赖进程名（因为进程名已被伪装）
# ---------------------------------------------------------
get_app_status() {
    status="UNKNOWN"
    details=""

    pid=""
    if [ -f "$APP_PID_FILE" ]; then
        pid=$(cat "$APP_PID_FILE" 2>/dev/null || true)
    fi

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        mem=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f", $1/1024}' || echo "?")
        details="PID=$pid, MEM=${mem}MB"

        http_code=$(curl -s -o /dev/null \
            --connect-timeout 5 --max-time 10 \
            -w "%{http_code}" \
            "http://127.0.0.1:8080/" 2>/dev/null || echo "000")

        if [ "$http_code" = "000" ]; then
            status="NOT_RESPONDING"
            details="$details, HTTP=TIMEOUT"
        else
            status="HEALTHY"
            details="$details, HTTP=$http_code"
        fi
    else
        status="NOT_RUNNING"
        details="process not found (PID=${pid:-none})"
    fi

    printf '%s|%s' "$status" "$details"
}

# ---------------------------------------------------------
# launch_app
# 三层进程名伪装：
#   1. exec -a  → 内核 comm（ps COMMAND 列 / /proc/PID/comm）
#   2. proc_shim.py 内的 prctl PR_SET_NAME（同上，双保险）
#   3. proc_shim.py 内的 setproctitle（/proc/PID/cmdline）
# ---------------------------------------------------------
launch_app() {
    cd /app

    # 用子 shell 把真实 PID（python 进程）写入文件，
    # 再 exec -a 替换子 shell 自身，保证伪装名生效。
    # 2>&1 | tee 让日志同时出现在 Docker stdout（docker logs 可见）
    # 和 /tmp/aistudio.log（崩溃后 tail -n 30 诊断用）。
    ( echo $$ > "$APP_PID_FILE"
      exec -a "$FAKE_PROC_NAME" \
          python3 /usr/local/bin/proc_shim.py \
              server \
              --port 8080 \
              --browser-port "${AISTUDIO_BROWSER_PORT:-${AISTUDIO_CAMOUFOX_PORT:-9222}}"
    ) 2>&1 | tee /tmp/aistudio.log &

    # 等 PID 文件写入后读取
    sleep 0.3
    APP_PID=$(cat "$APP_PID_FILE" 2>/dev/null || true)
    log_info "AIStudioToAPI 已启动 (PID=$APP_PID, 伪装名=$FAKE_PROC_NAME)"
}

# ---------------------------------------------------------
# start_app — 带防护的重启（冷却 + 次数限制）
# ---------------------------------------------------------
start_app() {
    now=$(date +%s)

    # 防护1：冷却期
    elapsed=$((now - LAST_RESTART_TIME))
    if [ "$LAST_RESTART_TIME" -gt 0 ] && [ "$elapsed" -lt "$RESTART_COOLDOWN" ]; then
        remaining=$((RESTART_COOLDOWN - elapsed))
        log_warn "冷却期中，${remaining}秒后才允许重启，跳过"
        return 1
    fi

    # 防护2：最大重启次数
    if [ "$APP_RESTART_COUNT" -ge "$MAX_RESTART" ]; then
        log_error "已连续重启 ${APP_RESTART_COUNT} 次仍失败，停止自动重启"
        log_error "请手动排查日志: /tmp/aistudio.log"
        return 1
    fi

    APP_RESTART_COUNT=$((APP_RESTART_COUNT + 1))
    LAST_RESTART_TIME=$now
    log_warn "正在重启 AIStudioToAPI（第 ${APP_RESTART_COUNT}/${MAX_RESTART} 次）..."

    # 先按 PID 杀（精确），再兜底 pkill shim
    if [ -f "$APP_PID_FILE" ]; then
        old_pid=$(cat "$APP_PID_FILE" 2>/dev/null || true)
        if [ -n "$old_pid" ]; then
            kill "$old_pid" 2>/dev/null || true
        fi
    fi
    pkill -f "proc_shim.py" 2>/dev/null || true

    sleep 3
    launch_app
    log_info "重启命令已发送，等待 ${RESTART_COOLDOWN}秒 冷却期"
}

# ---------------------------------------------------------
# tail_logs — 已废弃（保留空函数避免调用报错）
# 日志现在直接打到 Docker stdout，无需 tail -f
# ---------------------------------------------------------
tail_logs() {
    touch /tmp/aistudio.log
}

# =========================
# 启动
# =========================
echo "===== Application Startup at $(date '+%Y-%m-%d %H:%M:%S') ====="

# ──────────────────────────────────────
# 步骤 1: Nginx
# ──────────────────────────────────────
echo "=========================================="
echo " 步骤 1: 启动 Nginx (端口 7860)"
echo "=========================================="

mkdir -p /var/www/html
nginx

sleep 2

if curl -s "http://127.0.0.1:7860/health" > /dev/null 2>&1; then
    log_ok "Nginx 端口 7860 已就绪"
else
    log_error "Nginx 端口 7860 检查失败（非致命，继续启动）"
fi

# ──────────────────────────────────────
# 步骤 2: AIStudioToAPI
# ──────────────────────────────────────
echo "=========================================="
echo " 步骤 2: 启动 AIStudioToAPI"
echo "=========================================="

[ ! -d "/app" ]      && log_error "/app 目录不存在" && exit 1
[ ! -f "/app/main.py" ] && log_error "main.py 不存在"  && exit 1

tail_logs
launch_app

log_info "等待 AIStudioToAPI 启动（最长 60 秒）..."
sleep 10

if wait_for_port 8080 60; then
    log_ok "AIStudioToAPI 已成功启动并监听 8080 端口"
else
    log_error "AIStudioToAPI 启动超时，最后 30 行日志："
    tail -n 30 /tmp/aistudio.log
    log_warn "监控进程仍在运行，后续会自动重试"
fi

# ──────────────────────────────────────
# 步骤 3: SSL 证书（可选）
# ──────────────────────────────────────
if [ -n "$ARGO_DOMAIN" ]; then
    echo "=========================================="
    echo " 步骤 3: 生成 SSL 证书"
    echo "=========================================="

    log_info "生成证书: $ARGO_DOMAIN"
    mkdir -p /app

    openssl genrsa  -out /app/cert.key 2048                                          2>/dev/null
    openssl req     -new -subj "/CN=$ARGO_DOMAIN" -key /app/cert.key -out /app/cert.csr 2>/dev/null
    openssl x509    -req -days 36500 -in /app/cert.csr -signkey /app/cert.key -out /app/cert.pem 2>/dev/null

    sed "s/ARGO_DOMAIN_PLACEHOLDER/$ARGO_DOMAIN/g" \
        /etc/nginx/ssl.conf.template > /etc/nginx/conf.d/ssl.conf

    nginx -s reload
    sleep 1
    log_ok "证书生成完成，443 端口已启用"
fi

# ──────────────────────────────────────
# 步骤 4: Tunnel（可选）
# ──────────────────────────────────────
if [ -n "$ARGO_AUTH" ]; then
    echo "=========================================="
    echo " 步骤 4: 启动辅助服务"
    echo "=========================================="

    /usr/local/bin/dd-dd tunnel \
        --no-autoupdate run \
        --protocol http2 \
        --token "$ARGO_AUTH" \
        > /tmp/tunnel.log 2>&1 &

    sleep 5

    if pgrep -f "dd-dd" >/dev/null; then
        log_ok "辅助服务启动成功"
    else
        log_error "辅助服务启动失败"
        cat /tmp/tunnel.log
    fi
fi

# ──────────────────────────────────────
# 完成
# ──────────────────────────────────────
echo "=========================================="
echo " 所有服务已启动"
echo "=========================================="
log_info "HTTP:         http://localhost:7860"
log_info "AIStudioToAPI: http://localhost:8080"
[ -n "$ARGO_DOMAIN" ] && log_ok "公网地址: https://$ARGO_DOMAIN"

# =========================
# 健康检查循环（每 30 秒）
# =========================
while true; do
    CHECK_COUNT=$((CHECK_COUNT + 1))
    echo ""
    echo "========== 健康检查 #$CHECK_COUNT [$(date '+%Y-%m-%d %H:%M:%S')] =========="

    # ── AIStudioToAPI ──────────────────────────────────────
    NOW=$(date +%s)
    ELAPSED=$((NOW - LAST_RESTART_TIME))

    if [ "$LAST_RESTART_TIME" -gt 0 ] && [ "$ELAPSED" -lt "$RESTART_COOLDOWN" ]; then
        REMAINING=$((RESTART_COOLDOWN - ELAPSED))
        log_info "AIStudioToAPI: ⏳ 启动冷却中（还剩 ${REMAINING}秒），跳过检查"
    else
        APP_RESULT=$(get_app_status)
        APP_STATUS=$(echo "$APP_RESULT" | cut -d'|' -f1)
        APP_DETAILS=$(echo "$APP_RESULT" | cut -d'|' -f2)

        case "$APP_STATUS" in
            HEALTHY)
                log_status "AIStudioToAPI: ✓ $APP_STATUS ($APP_DETAILS)"
                if [ "$APP_RESTART_COUNT" -gt 0 ]; then
                    log_ok "已恢复正常，重置重启计数器"
                    APP_RESTART_COUNT=0
                fi
                ;;
            NOT_RESPONDING|HTTP_ERROR)
                log_warn "AIStudioToAPI: ✗ $APP_STATUS ($APP_DETAILS)"
                log_warn "等待 15 秒后二次确认..."
                sleep 15
                APP_RESULT2=$(get_app_status)
                APP_STATUS2=$(echo "$APP_RESULT2" | cut -d'|' -f1)
                if [ "$APP_STATUS2" != "HEALTHY" ]; then
                    log_warn "二次确认仍异常: $APP_STATUS2，触发重启"
                    start_app
                else
                    log_ok "AIStudioToAPI 已自行恢复"
                fi
                ;;
            NOT_RUNNING)
                log_error "AIStudioToAPI: ✗ $APP_STATUS ($APP_DETAILS)"
                start_app
                ;;
            *)
                log_warn "AIStudioToAPI: ? $APP_STATUS ($APP_DETAILS)"
                ;;
        esac
    fi

    # ── Tunnel ─────────────────────────────────────────────
    if [ -n "$ARGO_AUTH" ]; then
        if pgrep -f "dd-dd" >/dev/null; then
            TUNNEL_PID=$(pgrep -f "dd-dd" | head -1)
            log_status "Tunnel: ✓ RUNNING (PID=$TUNNEL_PID)"
        else
            log_warn "Tunnel: ✗ NOT_RUNNING — 正在重启..."
            /usr/local/bin/dd-dd tunnel \
                --no-autoupdate run \
                --protocol http2 \
                --token "$ARGO_AUTH" \
                > /tmp/tunnel.log 2>&1 &
        fi
    fi

    # ── Nginx ──────────────────────────────────────────────
    if pgrep -x "nginx" >/dev/null; then
        NGINX_PID=$(pgrep -x "nginx" | head -1)
        log_status "Nginx: ✓ RUNNING (PID=$NGINX_PID)"
    else
        log_warn "Nginx: ✗ NOT_RUNNING — 正在重启..."
        nginx
    fi

    echo "=================================================="
    sleep 30
done