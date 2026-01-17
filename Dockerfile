FROM ghcr.io/open-webui/open-webui:main AS app

FROM nginx:alpine

USER root

# 使用 apk 而不是 apt-get (Alpine Linux)
RUN apk add --no-cache \
    openssl \
    curl \
    procps

# 复制 cloudflared 和 SSL 证书
COPY --from=cloudflare/cloudflared:latest /usr/local/bin/cloudflared /usr/local/bin/dd-dd
COPY --from=app /etc/ssl/certs /etc/ssl/certs

# Nginx - 清理所有默认配置和页面
RUN rm -rf /usr/share/nginx/html/* && \
    rm -f /etc/nginx/conf.d/default.conf

# 复制配置文件（注意：文件名不能有空格）
COPY main.conf /etc/nginx/conf.d/main.conf
COPY ssl.conf.template /etc/nginx/ssl.conf.template

# 复制自定义页面(在清理之后)
COPY index.html /usr/share/nginx/html/index.html

# 复制并设置入口脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 7860

ENV DD_DM="" \
    DD_DD=""

CMD ["/entrypoint.sh"]
