#!/bin/sh
# Renders /etc/nginx/nginx.conf from the template with per-deployment values:
#   @LIVE_CB_SECRET@   shared secret appended to the on_publish callback URLs —
#                      the receiver rejects /live/* calls without it, so only
#                      this container can drive live entry state.
#   @LIVE_CORS_ORIGIN@ Access-Control-Allow-Origin for HLS output. Default "*"
#                      (external embeds work); set LIVE_CORS_ORIGIN to your site
#                      origin to stop third-party pages from playing your live
#                      HLS cross-origin.
set -e
sed \
    -e "s|@LIVE_CB_SECRET@|${LIVE_CB_SECRET:-}|g" \
    -e "s|@LIVE_CORS_ORIGIN@|${LIVE_CORS_ORIGIN:-*}|g" \
    /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
exec nginx -g "daemon off;"
