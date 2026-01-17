FROM ghcr.io/open-webui/open-webui:main
FROM nginx:alpine

USER root

RUN apt-get update && apt-get install -y \
    openssl \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/*

COPY --from=cloudflare/cloudflared:latest /usr/local/bin/cloudflared /usr/local/bin/dd-dd

COPY --from=app /etc/ssl/certs /etc/ssl/certs

# Nginx - 清理所有默认配置和页面
COPY main.conf /etc/nginx/conf.d/main.conf
COPY ssl. conf.template /etc/nginx/ssl.conf.template
RUN rm -f /etc/nginx/sites-enabled/default && \
    rm -f /etc/nginx/sites-available/default && \
    rm -rf /usr/share/nginx/html/* && \
    rm -f /etc/nginx/conf.d/default.conf

# 复制自定义页面（在清理之后）
COPY index.html /usr/share/nginx/html/index.html

COPY entrypoint.sh /entrypoint. sh
RUN chmod +x /entrypoint.sh

EXPOSE 7860

ENV DD_DM="" \
    DD_DD=""

CMD ["/entrypoint.sh"]
