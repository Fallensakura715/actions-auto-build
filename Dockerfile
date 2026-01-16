FROM ghcr.io/open-webui/open-webui:main

USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=cloudflare/cloudflared:latest /usr/local/bin/cloudflared /usr/local/bin/cloudflared

ENV PORT=7860
ENV HOME=/tmp

EXPOSE 7860

CMD cloudflared tunnel --no-autoupdate run --token ${DD_DD} & bash start.sh
