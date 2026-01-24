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

start_webui() {
    log_info "正在启动 Open WebUI..."
    cd /app/backend
    
    # 使用 while 循环实现自动重启
    while true; do
        log_info "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Open WebUI..."
        
        # 使用 stdbuf 减少缓冲，实时输出日志
        stdbuf -oL ./start.sh 2>&1 | tee -a /tmp/webui.log
        
        EXIT_CODE=$?
        log_error "[$(date '+%Y-%m-%d %H:%M:%S')] Open WebUI exited with code $EXIT_CODE"
        log_info "自动重启中，等待 5 秒..."
        sleep 5
    done &
    
    WEBUI_PID=$!
    log_info "Open WebUI 监控进程 PID: $WEBUI_PID"
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

# 启动 Open WebUI

tail_logs

# 启动 WebUI
PORT=8080 HOST=0.0.0.0 start_webui

# 等待服务启动
log_info "等待 Open WebUI 启动..."
sleep 10

# 健康检查
if wait_for_port 8080 60; then
    log_ok "Open WebUI 已成功启动并监听 8080 端口"
    
    # 额外的 HTTP 健康检查
    for i in {1..10}; do
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
    # 不退出，让监控循环继续尝试
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
    
    # 检查隧道
    if [ -n "$ARGO_AUTH" ] && ! pgrep -f "dd-dd" >/dev/null; then
        log_warn "隧道进程丢失，正在重启..."
        /usr/local/bin/dd-dd tunnel --no-autoupdate run --protocol http2 --token "$ARGO_AUTH" > /tmp/tunnel.log 2>&1 &
    fi
    
    # 检查 Nginx
    if ! pgrep -x "nginx" >/dev/null; then
        log_warn "Nginx 进程丢失，正在重启..."
        nginx
    fi

    if ! curl -s http://127.0.0.1:8080/health > /dev/null 2>&1; then
        sleep 5
        if ! curl -s http://127.0.0.1:8080/health > /dev/null 2>&1; then
             log_warn "OWU (端口 8080) 无响应，尝试重启..."
             pkill -f "uvicorn" || true
             pkill -f "start.sh" || true
             
             # 重启
             PORT=8080 HOST=0.0.0.0 start_webui
        fi
    fi
    
    sleep 60
done
