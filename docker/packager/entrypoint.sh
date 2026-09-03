#!/bin/sh
# nginx resolves `upstream kaltura_app` at config LOAD time and refuses to start
# if the name does not resolve. With `restart: unless-stopped` that makes a
# transient DNS gap permanent: the container crashes instantly, is restarted
# before its network endpoint is re-attached, and loops forever — even after the
# app is healthy. `depends_on: service_healthy` does NOT prevent it; observed on
# a real host with compose reporting "kaltura_app Healthy" immediately before
# packager entered a 12-restart loop.
#
# Waiting for the name here is the small fix. The alternative — a `resolver`
# plus a variable in proxy_pass — was tried and reverted: with a variable nginx
# stops forwarding the rewritten URI that nginx-vod-module depends on and every
# segment 404s.
set -e
wait_for_host() {
    _h="$1"; _n=0
    until getent hosts "$_h" >/dev/null 2>&1; do
        _n=$((_n + 1))
        [ $((_n % 10)) -eq 0 ] && echo "[packager] waiting for $_h to resolve (${_n}s)"
        if [ "$_n" -ge 120 ]; then
            echo "[packager] WARN: $_h still unresolved after ${_n}s — starting anyway"
            return 0
        fi
        sleep 1
    done
    [ "$_n" -gt 0 ] && echo "[packager] $_h resolved after ${_n}s"
    return 0
}
wait_for_host kaltura_app

exec "$@"
