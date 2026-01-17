#!/bin/sh

# =========================
# 环境变量
# =========================
ARGO_DOMAIN=${DD_DM:-""}
ARGO_AUTH=${DD_DD:-""}
DATA_DIR="/app/data"

# =========================
# 日志函数
# =========================
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_ok() {
    echo "[OK] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# =========================
# 步骤 1: 启动 Nginx (健康检查端口 7860)
# =========================
echo "=========================================="
echo " 步骤 1: 启动 Nginx (端口 7860)"
echo "=========================================="

rm -f /etc/nginx/conf.d/default.conf
nginx
sleep 1

if curl -s http://127.0.0.1:7860 > /dev/null 2>&1; then
    log_ok "Nginx 端口 7860 已就绪"
else
    log_error "Nginx 端口 7860 检查失败"
fi

# =========================
# 步骤 2: 创建数据目录
# =========================
echo "=========================================="
echo " 步骤 2: 创建数据目录"
echo "=========================================="

mkdir -p "$DATA_DIR"
log_ok "数据目录已创建:  $DATA_DIR"

# =========================
# 步骤 3: 启动 Open WebUI
# =========================
echo "=========================================="
echo " 步骤 3: 启动 Open WebUI"
echo "=========================================="

# 使用 pip 安装 open-webui
pip install open-webui --quiet

# 后台启动 Open WebUI
export WEBUI_SECRET_KEY="$WEBUI_SECRET_KEY"
export OPENAI_API_KEY="$OPENAI_API_KEY"
export OPENAI_API_BASE_URL="$OPENAI_API_BASE_URL"
export DATA_DIR="$DATA_DIR"

open-webui serve --port 8080 --host 0.0.0.0 &

# 等待 Open WebUI 启动
sleep 10
if curl -s http://127.0.0.1:8080 > /dev/null 2>&1; then
    log_ok "Open WebUI 已启动"
else
    log_error "Open WebUI 启动失败，等待更长时间..."
    sleep 20
fi

# =========================
# 步骤 4: 生成 SSL 证书
# =========================
if [ -n "$ARGO_DOMAIN" ]; then
    echo "=========================================="
    echo " 步骤 4: 生成 SSL 证书"
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
# 步骤 5: 启动 cloudflared
# =========================
if [ -n "$ARGO_AUTH" ]; then
    echo "=========================================="
    echo " 步骤 5: 启动 dd"
    echo "=========================================="
    
    cloudflared --no-autoupdate tunnel run --protocol http2 --token "$ARGO_AUTH" >/dev/null 2>&1 &
    sleep 5
    
    if pgrep -f "cloudflared" >/dev/null; then
        log_ok "dd 启动成功"
    else
        log_error "dd 启动失败"
    fi
fi

# =========================
# 保持容器运行
# =========================
echo "=========================================="
echo " 所有服务已启动"
echo "=========================================="

log_ok "Open WebUI 访问地址: https://$ARGO_DOMAIN"

# 保持前台运行
tail -f /dev/null
