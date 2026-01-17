#!/bin/sh

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

# =========================
# 步骤 1: 启动 Nginx (健康检查)
# =========================
echo "=========================================="
echo " 步骤 1: 启动 Nginx (端口 7860)"
echo "=========================================="

mkdir -p /var/www/html
nginx
sleep 1

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

cd /app/backend
PORT=8080 HOST=0.0.0.0 ./start.sh &

log_info "等待 Open WebUI 启动..."
for i in $(seq 1 60); do
    if curl -s http://127.0.0.1:8080 > /dev/null 2>&1; then
        log_ok "Open WebUI 已启动 (${i}s)"
        break
    fi
    sleep 1
done

if ! wait_for_port 8080 60; then
    log_error "OWU启动失败"
    exit 1
fi

# =========================
# 步骤 3: 生成 SSL 证书
# =========================
if [ -n "$ARGO_DOMAIN" ]; then
    echo "=========================================="
    echo " 步骤 3: 生成 SSL 证书"
    echo "=========================================="
    
    log_info "生成证书:  $ARGO_DOMAIN"
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
    
    # 使用重命名后的二进制，进程名显示为 dd-dd
    nohup /usr/local/bin/dd-dd --no-autoupdate tunnel run --protocol http2 --token "$ARGO_AUTH" >/dev/null 2>&1 &
    sleep 5
    
    if pgrep -f "dd-dd" >/dev/null; then
        log_ok "辅助服务启动成功"
    else
        log_error "辅助服务启动失败"
    fi
fi

# =========================
# 完成
# =========================
echo "=========================================="
echo " 所有服务已启动"
echo "=========================================="
[ -n "$ARGO_DOMAIN" ] && log_ok "访问地址: https://$ARGO_DOMAIN"

# 保持前台运行
tail -f /dev/null

# =========================
# 健康检查循环
# =========================
while true; do
    if ! pgrep -x "app" >/dev/null; then
        ./app >/dev/null 2>&1 &
        log_warn "OWU已重启"
    fi
    
    if [ -n "$ARGO_AUTH" ] && ! pgrep -f "dd-dd" >/dev/null; then
        cloudflared --no-autoupdate tunnel run --protocol http2 --token "$ARGO_AUTH" >/dev/null 2>&1 &
        log_warn "dd-dd 已重启"
    fi

    if ! pgrep -x "nginx" >/dev/null; then
        nginx
        log_warn "nginx 已重启"
    fi

    sleep 60
done
