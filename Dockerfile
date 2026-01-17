FROM ghcr.io/open-webui/open-webui:main AS app

FROM nginx:alpine

USER root

# 安装依赖
RUN apk add --no-cache \
    bash \
    openssl \
    curl \
    procps \
    python3 \
    py3-pip \
    shadow \
    su-exec \
    git \
    build-base \
    python3-dev \
    libffi-dev \
    openssl-dev

# 复制 cloudflared（伪装名称）
COPY --from=cloudflare/cloudflared:latest /usr/local/bin/cloudflared /usr/local/bin/dd-dd

# 复制 Open WebUI 应用文件
COPY --from=app /app /app
COPY --from=app /etc/ssl/certs /etc/ssl/certs

# 设置工作目录
WORKDIR /app/backend

# Nginx 配置
COPY main.conf /etc/nginx/conf.d/main.conf
RUN rm -f /etc/nginx/conf.d/default.conf
COPY ssl.conf.template /etc/nginx/ssl.conf.template

# 复制自定义文件
COPY entrypoint.sh /entrypoint.sh
COPY index.html /usr/share/nginx/html/index.html

# 设置权限
RUN chmod +x /entrypoint.sh && \
    sed -i 's/\r$//' /entrypoint.sh && \
    chmod +x /app/backend/start.sh 2>/dev/null || true

EXPOSE 8080

ENV DD_DM="" \
    DD_DD=""

CMD ["/entrypoint.sh"]
