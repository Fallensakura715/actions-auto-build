FROM ghcr.io/open-webui/open-webui:main

USER root

# 安装 Nginx 和其他工具
RUN apt-get update && apt-get install -y \
    nginx \
    openssl \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/*

# 复制 cloudflared（伪装名称）
COPY --from=cloudflare/cloudflared:latest /usr/local/bin/cloudflared /usr/local/bin/dd-dd

# Nginx 配置
COPY main.conf /etc/nginx/conf.d/main.conf
RUN rm -f /etc/nginx/conf.d/default.conf && \
    rm -rf /etc/nginx/sites-enabled/* && \
    rm -rf /etc/nginx/sites-available/*
COPY ssl.conf.template /etc/nginx/ssl.conf.template

# 复制自定义文件
COPY entrypoint.sh /entrypoint.sh
COPY index.html /usr/share/nginx/html/index.html

# 设置权限
RUN chmod +x /entrypoint.sh && \
    sed -i 's/\r$//' /entrypoint.sh

EXPOSE 8080

ENV DD_DM="" \
    DD_DD="" \
    PORT=8080 \
    HOST=0.0.0.0

CMD ["/entrypoint.sh"]
