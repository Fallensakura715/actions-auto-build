#!/bin/sh
set -e

# =========================
# 环境变量（隐蔽名称）
# =========================
ARGO_DOMAIN=${DD_DM:-""}
ARGO_AUTH=${DD_DD:-""}

# =========================
# 日志函数
# =========================
log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_ok() { echo "[OK] $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_status() { echo "[STATUS] $(date '+%Y-%m-%d %H:%M:%S') $1"; }

# =========================
# 辅助函数
# =========================
wait_for_port() {
    local port=$1
    local timeout=$2
    for i in $(seq 1 $timeout); do
        if curl -s http://127.0.0.1:$port > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

CHECK_COUNT=0
WEBUI_RESTART_COUNT=0
MAX_RESTART=5
LAST_RESTART_TIME=0
RESTART_COOLDOWN=120  # 重启后等待120秒再检查

get_webui_status() {
    local status="UNKNOWN"
    local details=""
    if pgrep -f "uvicorn" >/dev/null 2>&1; then
        local pid=$(pgrep -f "uvicorn" | head -1)
        local mem=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f", $1/1024}')
        details="PID=$pid, MEM=${mem}MB"
        local http_result
        http_result=$(curl -s --connect-timeout 5 --max-time 10 \
                      -w "%{http_code}" http://127.0.0.1:8080/api/version 2>/dev/null || echo "000")
        local http_code="${http_result: -3}"
        local body="${http_result:0:${#http_result}-3}"
        if [ "$http_code" = "200" ]; then
            status="HEALTHY"
            local version
            version=$(echo "$body" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "N/A")
            details="$details, HTTP=$http_code, Ver=$version"
        elif [ "$http_code" = "000" ]; then
            status="NOT_RESPONDING"
            details="$details, HTTP=TIMEOUT"
        else
            status="HTTP_ERROR"
            details="$details, HTTP=$http_code"
        fi
    else
        status="NOT_RUNNING"
        details="uvicorn process not found"
    fi
    echo "$status|$details"
}

# 真正启动 WebUI 的函数
launch_webui() {
    cd /app/backend
    PORT=8080 HOST=0.0.0.0 ./start.sh > /tmp/webui.log 2>&1 &
    WEBUI_PID=$!
    log_info "OpenWebUI 已启动 (PID: $WEBUI_PID)"
}

# 重启 WebUI 的函数（带保护机制）
start_webui() {
    local now
    now=$(date +%s)

    # ---- 防护1: 冷却期内不重启 ----
    local elapsed=$((now - LAST_RESTART_TIME))
    if [ "$LAST_RESTART_TIME" -gt 0 ] && [ "$elapsed" -lt "$RESTART_COOLDOWN" ]; then
        local remaining=$((RESTART_COOLDOWN - elapsed))
        log_warn "冷却期中，${remaining}秒后才允许重启，跳过"
        return 1
    fi

    # ---- 防护2: 超过最大重启次数则放弃 ----
    if [ "$WEBUI_RESTART_COUNT" -ge "$MAX_RESTART" ]; then
        log_error "已连续重启 ${WEBUI_RESTART_COUNT} 次仍失败，停止自动重启"
        log_error "请手动排查日志: /tmp/webui.log"
        return 1
    fi

    # ---- 执行重启 ----
    WEBUI_RESTART_COUNT=$((WEBUI_RESTART_COUNT + 1))
    LAST_RESTART_TIME=$now
    log_warn "正在重启 OpenWebUI（第 ${WEBUI_RESTART_COUNT}/${MAX_RESTART} 次）..."

    pkill -f "uvicorn" 2>/dev/null || true
    sleep 3
    launch_webui
    log_info "重启命令已发送，等待 ${RESTART_COOLDOWN} 秒冷却期"
}

# 实时读取日志文件的后台进程（确保日志能显示在 HF 控制台）
tail_logs() {
    touch /tmp/webui.log
    tail -f /tmp/webui.log &
    TAIL_PID=$!
    log_info "日志监控进程 PID: $TAIL_PID"
}

echo "===== Application Startup at $(date '+%Y-%m-%d %H:%M:%S') ====="

# =========================
# 步骤 1: 启动 Nginx (健康检查)
# =========================
echo "=========================================="
echo " 步骤 1: 启动 Nginx (端口 7860)"
echo "=========================================="

mkdir -p /var/www/html
nginx

sleep 2

if curl -s http://127.0.0.1:7860/health > /dev/null 2>&1; then
    log_ok "Nginx 端口 7860 已就绪"
else
    log_error "Nginx 端口 7860 检查失败"
fi

# =========================
# 步骤 2: 启动 Open WebUI
# =========================
echo "=========================================="
echo " 步骤 2: 启动 Open WebUI"
echo "=========================================="

# 检查目录是否存在
if [ ! -d "/app/backend" ]; then
    log_error "/app/backend 目录不存在"
    exit 1
fi

cd /app/backend

# 检查启动脚本是否存在
if [ ! -f "./start.sh" ]; then
    log_error "start.sh 不存在"
    exit 1
fi

# 启动日志监控
tail_logs

# 首次启动 WebUI
launch_webui

# 等待服务启动
log_info "等待 Open WebUI 启动..."
sleep 10

# 健康检查
if wait_for_port 8080 60; then
    log_ok "Open WebUI 已成功启动并监听 8080 端口"
    # 额外的 HTTP 健康检查
    for i in $(seq 1 10); do
        if curl -sf http://localhost:8080/api/version > /dev/null 2>&1; then
            log_ok "Open WebUI API 健康检查通过！"
            break
        fi
        log_info "等待 API 响应... ($i/10)"
        sleep 2
    done
else
    log_error "Open WebUI 启动超时，最后 30 行日志："
    tail -n 30 /tmp/webui.log
    log_info "尽管启动检测失败，监控进程仍在运行并会自动重试"
fi

log_ok "Open WebUI 监控已启动，进程会在崩溃后自动重启"

# =========================
# 步骤 3: 生成 SSL 证书
# =========================
if [ -n "$ARGO_DOMAIN" ]; then
    echo "=========================================="
    echo " 步骤 3: 生成 SSL 证书"
    echo "=========================================="
    
    log_info "生成证书: $ARGO_DOMAIN"
    
    mkdir -p /app
    
    openssl genrsa -out /app/cert.key 2048 2>/dev/null
    openssl req -new -subj "/CN=$ARGO_DOMAIN" -key /app/cert.key -out /app/cert.csr 2>/dev/null
    openssl x509 -req -days 36500 -in /app/cert.csr -signkey /app/cert.key -out /app/cert.pem 2>/dev/null
    
    sed "s/ARGO_DOMAIN_PLACEHOLDER/$ARGO_DOMAIN/g" /etc/nginx/ssl.conf.template > /etc/nginx/conf.d/ssl.conf
    
    nginx -s reload
    sleep 1
    log_ok "证书生成完成，443 端口已启用"
fi

# =========================
# 步骤 4: 启动隧道（进程名伪装）
# =========================
if [ -n "$ARGO_AUTH" ]; then
    echo "=========================================="
    echo " 步骤 4: 启动辅助服务"
    echo "=========================================="
    
    # 使用重命名后的二进制
    /usr/local/bin/dd-dd tunnel --no-autoupdate run --protocol http2 --token "$ARGO_AUTH" > /tmp/tunnel.log 2>&1 &
    
    sleep 5
    
    if pgrep -f "dd-dd" >/dev/null; then
        log_ok "辅助服务启动成功"
    else
        log_error "辅助服务启动失败"
        cat /tmp/tunnel.log
    fi
fi

# =========================
# 完成
# =========================
echo "=========================================="
echo " 所有服务已启动"
echo "=========================================="
[ -n "$ARGO_DOMAIN" ] && log_ok "访问地址: https://$ARGO_DOMAIN"
log_info "HTTP: http://localhost:7860"
log_info "WebUI: http://localhost:8080"

# =========================
# 健康检查循环
# =========================
while true; do
    CHECK_COUNT=$((CHECK_COUNT + 1))
    echo ""
    echo "========== 健康检查 #$CHECK_COUNT [$(date '+%Y-%m-%d %H:%M:%S')] =========="

    # ---- 冷却期内跳过 WebUI 检查 ----
    NOW=$(date +%s)
    ELAPSED=$((NOW - LAST_RESTART_TIME))
    if [ "$LAST_RESTART_TIME" -gt 0 ] && [ "$ELAPSED" -lt "$RESTART_COOLDOWN" ]; then
        REMAINING=$((RESTART_COOLDOWN - ELAPSED))
        log_info "OpenWebUI: ⏳ 启动冷却中（还剩 ${REMAINING}秒），跳过检查"
    else
        # -------- OpenWebUI 状态检查 --------
        WEBUI_RESULT=$(get_webui_status)
        WEBUI_STATUS=$(echo "$WEBUI_RESULT" | cut -d'|' -f1)
        WEBUI_DETAILS=$(echo "$WEBUI_RESULT" | cut -d'|' -f2)

        case "$WEBUI_STATUS" in
            "HEALTHY")
                log_status "OpenWebUI: ✓ $WEBUI_STATUS ($WEBUI_DETAILS)"
                # 恢复正常后重置计数器
                if [ "$WEBUI_RESTART_COUNT" -gt 0 ]; then
                    log_ok "OpenWebUI 已恢复，重置重启计数器"
                    WEBUI_RESTART_COUNT=0
                fi
                ;;
            "NOT_RESPONDING"|"HTTP_ERROR")
                log_warn "OpenWebUI: ✗ $WEBUI_STATUS ($WEBUI_DETAILS)"
                log_warn "等待 15 秒后二次确认..."
                sleep 15
                WEBUI_RESULT2=$(get_webui_status)
                WEBUI_STATUS2=$(echo "$WEBUI_RESULT2" | cut -d'|' -f1)
                if [ "$WEBUI_STATUS2" != "HEALTHY" ]; then
                    log_warn "二次确认仍异常: $WEBUI_STATUS2"
                    start_webui
                else
                    log_ok "OpenWebUI 已自行恢复"
                fi
                ;;
            "NOT_RUNNING")
                log_error "OpenWebUI: ✗ $WEBUI_STATUS ($WEBUI_DETAILS)"
                start_webui
                ;;
            *)
                log_warn "OpenWebUI: ? $WEBUI_STATUS ($WEBUI_DETAILS)"
                ;;
        esac
    fi

    # -------- 隧道状态检查 --------
    if [ -n "$ARGO_AUTH" ]; then
        if pgrep -f "dd-dd" >/dev/null; then
            TUNNEL_PID=$(pgrep -f "dd-dd" | head -1)
            log_status "Tunnel: ✓ RUNNING (PID=$TUNNEL_PID)"
        else
            log_warn "Tunnel: ✗ NOT_RUNNING - 正在重启..."
            /usr/local/bin/dd-dd tunnel --no-autoupdate run \
                --protocol http2 --token "$ARGO_AUTH" > /tmp/tunnel.log 2>&1 &
        fi
    fi

    # -------- Nginx 状态检查 --------
    if pgrep -x "nginx" >/dev/null; then
        NGINX_PID=$(pgrep -x "nginx" | head -1)
        log_status "Nginx: ✓ RUNNING (PID=$NGINX_PID)"
    else
        log_warn "Nginx: ✗ NOT_RUNNING - 正在重启..."
        nginx
    fi

    echo "=================================================="
    sleep 30
done
