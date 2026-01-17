FROM ghcr.io/open-webui/open-webui:main AS app

FROM nginx:alpine

USER root

# 安装依赖
RUN apk add --no-cache \
    openssl \
    curl \
    procps

# 复制 cloudflared 和 SSL 证书
COPY --from=cloudflare/cloudflared:latest /usr/local/bin/cloudflared /usr/local/bin/dd-dd
COPY --from=app /etc/ssl/certs /etc/ssl/certs

# Nginx 配置
COPY main.conf /etc/nginx/conf.d/main.conf
RUN rm -f /etc/nginx/conf.d/default.conf
COPY ssl.conf.template /etc/nginx/ssl.conf.template

EXPOSE 8080

ENV DD_DM="" \
    DD_DD=""
    
# 复制
COPY entrypoint.sh /entrypoint.sh
COPY index.html /usr/share/nginx/html/index.html

RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
