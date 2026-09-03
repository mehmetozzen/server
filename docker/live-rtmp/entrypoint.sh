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

# nginx resolves every hostname in its config at LOAD time and refuses to start
# when one does not resolve yet — here the on_publish callback to
# analytics-receiver. Combined with `restart: unless-stopped` that turns a
# moment of DNS unreadiness into a PERMANENT crash loop: the container restarts
# faster than its network endpoint is re-attached, so each attempt fails the
# same way and it never recovers even after the dependency is healthy. Observed
# on a real host: 13 restarts and still climbing, while analytics-receiver had
# been up and healthy for two hours. Waiting costs a few seconds on a cold boot
# and removes the loop.
wait_for_host() {
    _h="$1"; _n=0
    until getent hosts "$_h" >/dev/null 2>&1; do
        _n=$((_n + 1))
        [ $((_n % 10)) -eq 0 ] && echo "[live-rtmp] waiting for $_h to resolve (${_n}s)"
        if [ "$_n" -ge 120 ]; then
            echo "[live-rtmp] WARN: $_h still unresolved after ${_n}s — starting anyway"
            return 0
        fi
        sleep 1
    done
    [ "$_n" -gt 0 ] && echo "[live-rtmp] $_h resolved after ${_n}s"
    return 0
}
wait_for_host analytics-receiver

sed \
    -e "s|@LIVE_CB_SECRET@|${LIVE_CB_SECRET:-}|g" \
    -e "s|@LIVE_CORS_ORIGIN@|${LIVE_CORS_ORIGIN:-*}|g" \
    /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
exec nginx -g "daemon off;"
