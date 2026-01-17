FROM ghcr.io/open-webui/open-webui:main

USER root

RUN apt-get update && apt-get install -y \
    nginx \
    openssl \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/*

COPY --from=cloudflare/cloudflared: latest /usr/local/bin/cloudflared /usr/local/bin/dd-dd

# Nginx
COPY main.conf /etc/nginx/conf.d/main.conf
COPY ssl.conf.template /etc/nginx/ssl.conf.template
RUN rm -f /etc/nginx/sites-enabled/default

COPY index.html /var/www/html/index.html

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 7860

ENV DD_DM="" \
    DD_DD=""

CMD ["/entrypoint.sh"]
