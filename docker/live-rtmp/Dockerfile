# Live media server: nginx + nginx-rtmp-module.
# Kaltura CE ships the full live ORCHESTRATION (LiveStreamService, delivery
# profiles, recording jobs) but no media server — the cloud uses Wowza/Kaltura's
# closed deployment. This follows Kaltura's official FOSS path
# (platform-install-packages doc/nginx-rtmp-live-streaming.md): RTMP in on the
# kLive application, HLS out, consumed by a "Manual Live Stream" entry.
FROM alpine:3.20

# Alpine packages nginx-mod-rtmp alongside nginx — no source build needed.
RUN apk add --no-cache nginx nginx-mod-rtmp

# The config is a template: the entrypoint substitutes @LIVE_CB_SECRET@ (the
# receiver-callback shared secret) and @LIVE_CORS_ORIGIN@ at boot.
COPY docker/live-rtmp/nginx.conf /etc/nginx/nginx.conf.template
COPY docker/live-rtmp/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# HLS segment dir (official doc layout: /var/tmp/hlsme) + recordings dir
# (named volume mounts here and inherits the nginx ownership on first use).
# Worker runs as nginx.
RUN mkdir -p /var/tmp/hlsme /opt/kaltura/live_recordings \
    && chown nginx:nginx /var/tmp/hlsme /opt/kaltura/live_recordings

EXPOSE 1935 8090
CMD ["/entrypoint.sh"]
