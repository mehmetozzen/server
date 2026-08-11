#!/usr/bin/env bash
# Health and configuration diagnostics for the Kaltura Docker stack.
#
# Read-only: it inspects, it never changes anything. Run it before reporting a
# problem, after an upgrade, or on a schedule. Every check that has ever bitten
# this stack in the field is represented here — see the notes on each section.
#
# Usage:  make -C docker doctor
# Exit:   0 = no problems, 1 = at least one FAIL
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
CONF="${KALTURA_CONF:-$DOCKER_DIR/kaltura.conf}"
COMPOSE=(docker compose --env-file "$CONF" -f "$DOCKER_DIR/docker-compose.yml")

pass=0; warn=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
wrn()  { printf '  \033[33m!\033[0m %s\n' "$*"; warn=$((warn+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
info() { printf '    %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ -f "$CONF" ] || { echo "doctor: $CONF not found — run 'make -C docker config' first"; exit 1; }
# shellcheck disable=SC1090
set -a; . "$CONF"; set +a

WWW_HOST="${WWW_HOST:-localhost}"
PROTOCOL="${PROTOCOL:-http}"
BASE="$PROTOCOL://$WWW_HOST"

# ── 1. Containers ─────────────────────────────────────────────────────────────
# The failure this catches: a container that died once and stayed dead. On a
# test host the batch worker exited at first boot and transcoding was silently
# broken for 27 hours because nothing reported it.
head_ "1. Containers"
CONTAINERS=()
while IFS= read -r _l; do [ -n "$_l" ] && CONTAINERS+=("$_l"); done < <(
    docker ps -a --filter "name=kaltura_" --format '{{.Names}}\t{{.State}}\t{{.Status}}' | sort)
if [ ${#CONTAINERS[@]} -eq 0 ]; then
    bad "no kaltura_* containers found — the stack has never been started here"
else
    for row in "${CONTAINERS[@]}"; do
        name=$(cut -f1 <<<"$row"); state=$(cut -f2 <<<"$row"); status=$(cut -f3 <<<"$row")
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null)
        restarts=$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo 0)
        case "$state" in
            running)
                if [ "$health" = unhealthy ]; then
                    bad "$name is running but UNHEALTHY"
                elif [ "${restarts:-0}" -gt 3 ]; then
                    wrn "$name is up but has restarted $restarts times — something is crashing"
                else
                    ok "$name ($status${health:+, $health})"
                fi ;;
            restarting) bad "$name is in a restart loop ($restarts restarts) — check: docker logs $name" ;;
            exited)     bad "$name is DOWN ($status) — check: docker logs $name" ;;
            *)          wrn "$name state=$state ($status)" ;;
        esac
    done
fi

DRUID_UP=no
docker inspect -f '{{.State.Running}}' kaltura_druid_broker 2>/dev/null | grep -q true && DRUID_UP=yes
info "analytics (Druid): $([ "$DRUID_UP" = yes ] && echo running || echo "not running — core-only mode")"

# ── 2. API reachability ───────────────────────────────────────────────────────
head_ "2. API"
PING=$(curl -sk --max-time 10 "$BASE/api_v3/?service=system&action=ping" 2>/dev/null)
if grep -q '<result>1</result>' <<<"$PING"; then
    ok "system.ping over $BASE"
    # Without -k: proves the certificate chain is complete and trusted, which is
    # what browsers and the batch worker's API client actually require.
    if [ "$PROTOCOL" = https ]; then
        curl -s --max-time 10 -o /dev/null "$BASE/api_v3/?service=system&action=ping" 2>/dev/null \
            && ok "TLS chain validates without -k" \
            || wrn "TLS chain does NOT validate (self-signed, or ca_bundle missing from server.crt)"
    fi
else
    bad "system.ping failed at $BASE — the app is not serving"
fi

# ── 3. Permissions ────────────────────────────────────────────────────────────
# Root-run init steps writing into volumes shared with www-data processes is the
# single most productive bug source in this stack: a 0600 root-owned
# classMap.cache made every cron run rebuild the autoloader from scratch.
head_ "3. Shared-volume permissions"
if docker inspect -f '{{.State.Running}}' kaltura_app 2>/dev/null | grep -q true; then
    CM=/opt/kaltura/app/cache/scripts/classMap.cache
    if docker exec kaltura_app test -f "$CM" 2>/dev/null; then
        if docker exec kaltura_app su -s /bin/sh www-data -c "test -r $CM" 2>/dev/null; then
            ok "classMap.cache readable by www-data"
        else
            bad "classMap.cache NOT readable by www-data ($(docker exec kaltura_app stat -c '%U:%G %a' "$CM" 2>/dev/null)) — every PHP CLI run rebuilds the class map"
            info "fix: docker exec kaltura_app chown -R www-data:www-data /opt/kaltura/app/cache && docker exec kaltura_app chmod 644 $CM"
        fi
    else
        info "classMap.cache not created yet (normal on a very fresh install)"
    fi

    root_logs=$(docker exec kaltura_app find /opt/kaltura/log -maxdepth 1 -type f ! -user www-data 2>/dev/null | wc -l | tr -d ' ')
    [ "${root_logs:-0}" -eq 0 ] && ok "log volume fully owned by www-data" \
        || wrn "$root_logs log file(s) not owned by www-data — a www-data writer may fail to append"

    root_cache=$(docker exec kaltura_app find /opt/kaltura/app/cache -maxdepth 2 ! -user www-data 2>/dev/null | wc -l | tr -d ' ')
    [ "${root_cache:-0}" -eq 0 ] && ok "cache tree fully owned by www-data" \
        || wrn "$root_cache cache entr(ies) not owned by www-data"

    # batchBase.ini is regenerated on every app boot from a template whose
    # secret token used to be blanked, silently cutting the batch worker off
    # from the API. Cheap to check, invisible when it breaks.
    if docker exec kaltura_app test -f /opt/kaltura/app/configurations/batchBase.ini 2>/dev/null; then
        docker exec kaltura_app grep -qE '^secret[[:space:]]*=[[:space:]]*[A-Za-z0-9]+' \
            /opt/kaltura/app/configurations/batchBase.ini 2>/dev/null \
            && ok "batchBase.ini carries a batch API secret" \
            || bad "batchBase.ini has an EMPTY secret — batch workers cannot authenticate to the API"
    fi

    pids=$(docker exec kaltura_app sh -c 'ls /opt/kaltura/app/var/run/ 2>/dev/null' | grep -c '\.pid$')
    [ -z "$pids" ] && pids=0
    [ "${pids:-0}" -le 1 ] && ok "no stale worker pid files ($pids present)" \
        || wrn "$pids pid files in var/run — stale ones make the scheduler refuse to start"
else
    wrn "kaltura_app not running — skipped permission checks"
fi

# ── 3b. Generated client SDKs and the packager upstream ───────────────────────
# Two failures that present identically to the user (nothing plays) and leave
# nothing obvious in a log.
if docker inspect -f '{{.State.Running}}' kaltura_app 2>/dev/null | grep -q true; then
    if docker exec kaltura_app test -f /opt/kaltura/app/batch/client/KalturaClient.php 2>/dev/null; then
        ok "generated client SDK present"
    else
        bad "batch/client/KalturaClient.php missing — the batch worker exits 255 at bootstrap and nothing transcodes"
        info "the app container regenerates it on boot; check: docker logs kaltura_app | grep -i 'client sdk'"
    fi
fi
if docker inspect -f '{{.State.Running}}' kaltura_packager 2>/dev/null | grep -q true; then
    # nginx resolves the app hostname once, at config load. Recreating the app
    # container leaves the packager talking to an IP nobody answers on, and
    # every segment request fails while the container still looks healthy.
    stale=$(docker logs --since 15m kaltura_packager 2>&1 | grep -c "connect() failed" || true)
    [ -z "$stale" ] && stale=0
    [ "$stale" -eq 0 ] && ok "packager reaches the app upstream" \
        || bad "packager cannot reach the app ($stale connection failures in 15m) — its cached upstream IP is stale; fix: docker compose ... restart packager"
fi

# ── 3c. Log growth ────────────────────────────────────────────────────────────
# The disk filler on this stack. Kaltura ships with DEBUG logging enabled and
# rotation was daily-only: kaltura_api_v3.log grew 36 MB in 35 minutes on an
# idle install. Both are fixed, so a large file now means the fix is not in
# effect on this host (old image, LOG_LEVEL raised, scheduler not running).
if docker inspect -f '{{.State.Running}}' kaltura_app 2>/dev/null | grep -q true; then
    big=$(docker exec kaltura_app sh -c \
        'find /opt/kaltura/log -maxdepth 2 -type f -name "*.log" -size +250M 2>/dev/null' | wc -l | tr -d ' ')
    [ "${big:-0}" -eq 0 ] && ok "no runaway log files (>250MB)" \
        || { bad "$big log file(s) over 250MB — rotation is not keeping up"
             docker exec kaltura_app sh -c 'find /opt/kaltura/log -maxdepth 2 -type f -name "*.log" -size +250M -exec ls -lh {} \;' 2>/dev/null | awk '{print "      "$5, $9}'; }
    lvl=$(docker exec kaltura_app sh -c \
        "grep -oE '^writers\\.stream\\.filters\\.priority\\.priority *= *[0-9]+' /opt/kaltura/app/configurations/logger.ini 2>/dev/null | grep -oE '[0-9]+\$'" | head -1)
    if [ -z "$lvl" ]; then
        wrn "log priority filter not active — Kaltura is writing every DEBUG line (set LOG_LEVEL in kaltura.conf and restart the app)"
    elif [ "$lvl" -ge 7 ]; then
        wrn "LOG_LEVEL=$lvl (DEBUG) — fine while troubleshooting, very chatty for day-to-day"
    else
        ok "log level $lvl (DEBUG suppressed)"
    fi
    docker exec kaltura_scheduler grep -q 'maxsize' /etc/logrotate.d/kaltura 2>/dev/null \
        && ok "logrotate has a size cap" \
        || wrn "logrotate is time-based only — a busy day can fill the disk before it runs"
fi

# ── 4. Transcoding toolchain ──────────────────────────────────────────────────
# ffmpeg 8.x SIGILLs on libx264 under Apple Virtualization, which failed every
# transcode while leaving entries stuck at "source only". Verify the binary can
# actually encode rather than merely exist.
head_ "4. Transcoding"
if docker inspect -f '{{.State.Running}}' kaltura_batch 2>/dev/null | grep -q true; then
    ver=$(docker exec kaltura_batch ffmpeg-real -version 2>/dev/null | head -1 | awk '{print $3}')
    if docker exec kaltura_batch ffmpeg-real -loglevel error -f lavfi -i testsrc=duration=1:size=160x120:rate=5 \
            -c:v libx264 -f null - >/dev/null 2>&1; then
        ok "ffmpeg $ver encodes H.264"
    else
        bad "ffmpeg $ver CANNOT encode H.264 (SIGILL/exit != 0) — all transcodes will fail"
    fi
    docker exec kaltura_batch sh -c 'ffmpeg -f lavfi -i sine=d=1 -c:a libfdk_aac -f null - >/dev/null 2>&1' \
        && ok "ffmpeg wrapper rewrites libfdk_aac → aac" \
        || wrn "libfdk_aac wrapper check failed — audio-bearing flavors may fail"
else
    bad "kaltura_batch is not running — nothing will transcode"
fi

# ── 5. Configuration lint ─────────────────────────────────────────────────────
head_ "5. Configuration"
for v in DB1_PASS MYSQL_ROOT_PASSWORD ADMIN_CONSOLE_PASSWORD; do
    val="${!v:-}"
    case "$val" in
        "")                 bad "$v is empty — containers refuse to start" ;;
        *CHANGEME*)         bad "$v still contains the CHANGEME placeholder" ;;
        kaltura123|kaltura_root|Admin1234!|changeme|changeme_root)
                            bad "$v uses a publicly-known default value" ;;
        *) [ ${#val} -lt 12 ] && wrn "$v is short (${#val} chars)" || ok "$v set" ;;
    esac
done
[ "${ADMIN_CONSOLE_ADMIN_MAIL:-}" = "admin@example.com" ] \
    && wrn "ADMIN_CONSOLE_ADMIN_MAIL is still admin@example.com — it is the admin login id and is baked in at first boot" \
    || ok "admin e-mail configured (${ADMIN_CONSOLE_ADMIN_MAIL:-unset})"
[ -n "${SMTP_HOST:-}" ] && ok "SMTP relay: $SMTP_HOST:${SMTP_PORT:-587}" \
    || wrn "SMTP_HOST unset — password reset, invitations and bulk-upload result mails are disabled"
if [ "$DRUID_UP" = no ] && [ "${LOAD_DWH:-true}" = "true" ]; then
    wrn "LOAD_DWH is not false while running without analytics — the DWH schema is loaded but nothing ever reads it"
fi
if [ -z "${LIVE_PUBLISH_TOKEN:-}" ] && [ "${LIVE_ALLOW_ANON_PUBLISH:-}" != "1" ]; then
    wrn "LIVE_PUBLISH_TOKEN empty — manual live stream publishing is refused (fail-closed)"
elif [ "${LIVE_ALLOW_ANON_PUBLISH:-}" = "1" ]; then
    bad "LIVE_ALLOW_ANON_PUBLISH=1 — anyone who can reach port 1935 can publish"
else
    ok "live publish token configured"
fi
[ -n "${LIVE_CB_SECRET:-}" ] && ok "live callback secret configured" \
    || wrn "LIVE_CB_SECRET empty — any container on the network can drive live entry state"

# ── 6. TLS certificate ────────────────────────────────────────────────────────
head_ "6. TLS certificate"
CRT="$DOCKER_DIR/certs/server.crt"
if [ "$PROTOCOL" != https ]; then
    info "PROTOCOL=http — TLS not in use"
elif [ ! -f "$CRT" ]; then
    bad "PROTOCOL=https but $CRT is missing"
else
    end=$(openssl x509 -in "$CRT" -noout -enddate 2>/dev/null | cut -d= -f2)
    days=$(( ( $(date -j -f "%b %d %T %Y %Z" "$end" +%s 2>/dev/null || date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if openssl x509 -in "$CRT" -noout -ext subjectAltName 2>/dev/null | grep -q "$WWW_HOST"; then
        ok "certificate covers $WWW_HOST"
    else
        bad "certificate does NOT list $WWW_HOST in its SAN"
    fi
    if [ "$days" -lt 0 ]; then       bad "certificate EXPIRED ($end)"
    elif [ "$days" -lt 21 ]; then    wrn "certificate expires in $days days ($end)"
    else                             ok "certificate valid for $days more days"; fi
    n=$(grep -c 'BEGIN CERTIFICATE' "$CRT")
    if [ "$n" -ge 2 ]; then
        ok "full chain present ($n certificates)"
    elif curl -s --max-time 10 -o /dev/null "$BASE/api_v3/?service=system&action=ping" 2>/dev/null; then
        ok "single certificate, but the chain validates (locally-trusted root, e.g. mkcert)"
    else
        wrn "server.crt holds one certificate and the chain does not validate — intermediates missing (cat certificate.crt ca_bundle.crt > server.crt)"
    fi
fi

# ── 7. Host resources ─────────────────────────────────────────────────────────
head_ "7. Host resources"
if docker info --format '{{.MemTotal}}' >/dev/null 2>&1; then
    memgb=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
    if [ "$DRUID_UP" = yes ] && [ "$memgb" -lt 7 ]; then
        bad "Docker has ${memgb}GB but analytics is running — Druid needs ~8GB total"
    elif [ "$memgb" -lt 3 ]; then
        bad "Docker has only ${memgb}GB — the core stack needs ~2GB plus transcoding headroom"
    else
        ok "Docker memory: ${memgb}GB"
    fi
fi
avail=$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print int($4/1048576)}')
[ -z "$avail" ] && avail=$(df -Pk / | awk 'NR==2{print int($4/1048576)}')
[ "${avail:-99}" -lt 5 ] && bad "only ${avail}GB free on the Docker filesystem" || ok "${avail}GB free for images and volumes"

# ── 8. Port exposure ──────────────────────────────────────────────────────────
# Only the web ports and RTMP ingest belong on 0.0.0.0. Everything else — MySQL,
# memcached, the Druid overlord (task submission is remote code execution) —
# must stay on loopback.
head_ "8. Port exposure"
while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
        80|443|1935) ok "port $p public (expected)" ;;
        *)           bad "port $p is exposed on 0.0.0.0 — should be bound to 127.0.0.1" ;;
    esac
done < <(docker ps --filter "name=kaltura_" --format '{{.Ports}}' \
    | grep -oE '0\.0\.0\.0:[0-9]+' | cut -d: -f2 | sort -un)

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n\033[1mSummary:\033[0m %d ok, %d warning(s), %d problem(s)\n' "$pass" "$warn" "$fail"
[ "$fail" -gt 0 ] && exit 1
exit 0
