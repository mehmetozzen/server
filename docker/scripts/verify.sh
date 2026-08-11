#!/usr/bin/env bash
# End-to-end smoke test for the Kaltura Docker stack.
#
# Exercises the paths that actually break: upload → transcode → packaged
# playback → search → analytics ingest → live publish auth → mail plumbing.
# Every check here corresponds to a failure that was found by hand on a running
# install; the point of this script is that the next one is found in minutes
# instead of days.
#
# Usage:  make -C docker verify
# Env:
#   VERIFY_ANALYTICS=1  also query the Druid-backed report API (adds ~3 min)
#   VERIFY_MAIL=1       actually send a mail through the configured relay
#   KEEP=1              keep the entry/category/playlist it creates
#   TRANSCODE_TIMEOUT=n seconds to wait for flavors (default 420)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
CONF="${KALTURA_CONF:-$DOCKER_DIR/kaltura.conf}"
[ -f "$CONF" ] || { echo "verify: $CONF not found — run 'make -C docker config'"; exit 1; }
# shellcheck disable=SC1090
set -a; . "$CONF"; set +a

WWW_HOST="${WWW_HOST:-localhost}"
PROTOCOL="${PROTOCOL:-http}"
BASE="$PROTOCOL://$WWW_HOST"
API="$BASE/api_v3"
TRANSCODE_TIMEOUT="${TRANSCODE_TIMEOUT:-420}"
VERIFY_PARTNER_NAME="kaltura-verify"

total=0; passed=0; failed=0; skipped=0
declare -a RESULTS
_row() { RESULTS+=("$1|$2|$3"); }
step()  { CURRENT="$1"; printf '  %-44s' "$1"; total=$((total+1)); }
pass()  { printf '\033[32mPASS\033[0m  %s\n' "${1:-}"; passed=$((passed+1)); _row PASS "$CURRENT" "${1:-}"; }
fail()  { printf '\033[31mFAIL\033[0m  %s\n' "${1:-}"; failed=$((failed+1)); _row FAIL "$CURRENT" "${1:-}"; }
skip()  { printf '\033[33mSKIP\033[0m  %s\n' "${1:-}"; skipped=$((skipped+1)); _row SKIP "$CURRENT" "${1:-}"; }
sect()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# JSON scalars from Kaltura's format=1 responses. Deliberately grep-based: no
# python/jq dependency on whatever host this runs on.
jstr() { grep -o "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }
jnum() { grep -o "\"$1\":[0-9-]*" | head -1 | cut -d: -f2; }

mysqlq() {
    docker exec kaltura_mysql sh -c \
        "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" kaltura -N -B -e '$1'" 2>/dev/null
}

cleanup() {
    [ "${KEEP:-0}" = "1" ] && { echo; echo "KEEP=1 — leaving test objects in place (partner $PID, entry ${ENTRY:-none})"; return; }
    [ -n "${KS:-}" ] || return
    [ -n "${ENTRY:-}" ]    && curl -sk -o /dev/null "$API/service/media/action/delete"    -d "ks=$KS&entryId=$ENTRY" 2>/dev/null
    [ -n "${PLAYLIST:-}" ] && curl -sk -o /dev/null "$API/service/playlist/action/delete" -d "ks=$KS&id=$PLAYLIST" 2>/dev/null
    [ -n "${CATEGORY:-}" ] && curl -sk -o /dev/null "$API/service/category/action/delete" -d "ks=$KS&id=$CATEGORY" 2>/dev/null
}
trap cleanup EXIT

echo "Kaltura stack verification — $BASE"

# ── Preconditions ─────────────────────────────────────────────────────────────
sect "Preconditions"
step "containers running"
missing=""
for c in kaltura_app kaltura_batch kaltura_mysql kaltura_sphinx kaltura_packager; do
    docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true || missing="$missing $c"
done
if [ -n "$missing" ]; then fail "down:$missing"; echo; echo "verify: cannot continue"; exit 1; fi
pass

DRUID_UP=no
docker inspect -f '{{.State.Running}}' kaltura_druid_broker 2>/dev/null | grep -q true && DRUID_UP=yes

step "API system.ping"
curl -sk --max-time 15 "$API/?service=system&action=ping" 2>/dev/null | grep -q '<result>1</result>' \
    && pass || { fail "no <result>1</result>"; exit 1; }

# ── Partner ───────────────────────────────────────────────────────────────────
# A dedicated partner keeps verification data out of real content and makes the
# run repeatable: reused when present, created once when not.
sect "Partner"
step "verify partner"
read -r PID SECRET <<<"$(mysqlq "SELECT id, admin_secret FROM partner WHERE name = '$VERIFY_PARTNER_NAME' LIMIT 1")"
if [ -n "${PID:-}" ]; then
    pass "reusing partner $PID"
else
    AC_SECRET=$(mysqlq "SELECT admin_secret FROM partner WHERE id = -2")
    AC_KS=$(curl -sk "$API/service/session/action/start" -d "secret=$AC_SECRET&partnerId=-2&type=2&format=1" | tr -d '"')
    # description and describeYourself are required by partner.register even
    # though the schema marks them optional.
    REG=$(curl -sk "$API/service/partner/action/register" -d "ks=$AC_KS&format=1&partner:objectType=KalturaPartner&partner:name=$VERIFY_PARTNER_NAME&partner:adminName=verify&partner:adminEmail=kaltura-verify@example.com&partner:description=automated verification partner&partner:describeYourself=other&partner:commercialUse=0&partner:type=1&cmsPassword=Verify_$(date +%s)")
    PID=$(jnum id <<<"$REG"); SECRET=$(jstr adminSecret <<<"$REG")
    [ -n "$PID" ] && pass "created partner $PID" || { fail "partner.register failed: $(head -c 120 <<<"$REG")"; exit 1; }
fi

step "admin session"
KS=$(curl -sk "$API/service/session/action/start" -d "secret=$SECRET&partnerId=$PID&type=2&format=1" | tr -d '"')
[ ${#KS} -gt 20 ] && pass || { fail "session.start returned: $KS"; exit 1; }

# ── Upload and transcode ──────────────────────────────────────────────────────
sect "Upload and transcode"
step "generate test media"
docker exec kaltura_batch sh -c 'ffmpeg-real -loglevel error -f lavfi -i testsrc=duration=20:size=1280x720:rate=25 -f lavfi -i sine=frequency=440:duration=20 -c:v libx264 -preset ultrafast -b:v 1200k -pix_fmt yuv420p -c:a aac -b:a 128k -shortest -y /tmp/verify.mp4' 2>/dev/null \
    && docker cp kaltura_batch:/tmp/verify.mp4 /tmp/kaltura_verify.mp4 >/dev/null 2>&1 \
    && pass "$(du -h /tmp/kaltura_verify.mp4 | cut -f1)" \
    || { fail "ffmpeg could not produce a test file — the encoder itself is broken"; exit 1; }

step "uploadToken + upload"
TOK=$(curl -sk "$API/service/uploadtoken/action/add" -d "ks=$KS&format=1" | jstr id)
UP=$(curl -sk "$API/service/uploadtoken/action/upload" -F "ks=$KS" -F "format=1" -F "uploadTokenId=$TOK" -F "fileData=@/tmp/kaltura_verify.mp4")
[ "$(jnum status <<<"$UP")" = "2" ] && pass || fail "upload status $(jnum status <<<"$UP")"

step "media.add + addContent"
ENTRY=$(curl -sk "$API/service/media/action/add" -d "ks=$KS&format=1&entry:objectType=KalturaMediaEntry&entry:mediaType=1&entry:name=verify-$(date +%s)&entry:tags=kaltura-verify" | jstr id)
curl -sk -o /dev/null "$API/service/media/action/addContent" -d "ks=$KS&format=1&entryId=$ENTRY&resource:objectType=KalturaUploadedFileTokenResource&resource:token=$TOK"
[ -n "$ENTRY" ] && pass "$ENTRY" || { fail "no entry id"; exit 1; }

step "transcode completes (<${TRANSCODE_TIMEOUT}s)"
deadline=$(( $(date +%s) + TRANSCODE_TIMEOUT )); status=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    status=$(mysqlq "SELECT status FROM entry WHERE id = \"$ENTRY\"")
    [ "$status" = "2" ] && break
    [ "$status" = "-1" ] && break
    sleep 10
done
READY=$(mysqlq "SELECT SUM(status=2) FROM flavor_asset WHERE entry_id = \"$ENTRY\"")
FAILEDF=$(mysqlq "SELECT COUNT(*) FROM batch_job WHERE entry_id = \"$ENTRY\" AND status = 6")
case "$status" in
    2)  [ "${READY:-0}" -ge 2 ] && pass "${READY} flavors ready" \
            || fail "entry ready but only ${READY:-0} flavor(s)" ;;
    -1) fail "entry in ERROR state (${FAILEDF:-0} failed jobs) — check docker logs kaltura_batch" ;;
    *)  fail "still status=$status after ${TRANSCODE_TIMEOUT}s (${READY:-0} flavors ready)" ;;
esac

# ── Playback ──────────────────────────────────────────────────────────────────
sect "Playback"
SP=$((PID * 100))
step "HLS master manifest"
M=$(curl -sk --max-time 20 "$BASE/p/$PID/sp/$SP/playManifest/entryId/$ENTRY/protocol/${PROTOCOL}/format/applehttp/a.m3u8")
VARIANTS=$(grep -c '^http' <<<"$M" || true)
[ "${VARIANTS:-0}" -ge 1 ] && pass "$VARIANTS variant(s)" || fail "no variants in master playlist"

step "HLS variant playlist (packager)"
VAR=$(grep -m1 '^http' <<<"$M")
if [ -n "$VAR" ]; then
    V=$(curl -sk --max-time 20 "$VAR")
    grep -q '#EXTINF' <<<"$V" && pass "$(grep -c '\.ts' <<<"$V") segments" || fail "packager returned no segments"
else
    fail "no variant URL to fetch"; V=""
fi

step "HLS media segment"
SEG=$(grep -m1 '\.ts' <<<"${V:-}")
if [ -n "$SEG" ]; then
    code=$(curl -sk -o /dev/null -w '%{http_code}:%{size_download}' --max-time 30 "${VAR%/index.m3u8}/$SEG")
    [ "${code%%:*}" = "200" ] && [ "${code##*:}" -gt 10000 ] && pass "${code##*:} bytes" || fail "segment fetch $code"
else
    fail "no segment listed"
fi

step "DASH manifest"
D=$(curl -skL --max-time 20 "$BASE/p/$PID/sp/$SP/playManifest/entryId/$ENTRY/protocol/${PROTOCOL}/format/mpegdash/a.mpd")
grep -q '<MPD' <<<"$D" && pass || fail "no MPD returned (packager /dash/ location missing?)"

step "thumbnail"
code=$(curl -sk -o /dev/null -w '%{http_code}:%{size_download}' --max-time 30 "$BASE/p/$PID/sp/$SP/thumbnail/entry_id/$ENTRY/width/320/height/180")
[ "${code%%:*}" = "200" ] && [ "${code##*:}" -gt 1000 ] && pass "${code##*:} bytes" || fail "thumbnail $code"

step "flavor download"
code=$(curl -skL -o /dev/null -w '%{http_code}:%{size_download}' --max-time 60 "$BASE/p/$PID/sp/$SP/playManifest/entryId/$ENTRY/format/download/protocol/${PROTOCOL}/a.mp4")
[ "${code%%:*}" = "200" ] && [ "${code##*:}" -gt 10000 ] && pass "${code##*:} bytes" || fail "download $code"

# ── Metadata, search ──────────────────────────────────────────────────────────
sect "Metadata and search"
step "category create + assign"
CATEGORY=$(curl -sk "$API/service/category/action/add" -d "ks=$KS&format=1&category:objectType=KalturaCategory&category:name=verify-$(date +%s)" | jnum id)
if [ -n "$CATEGORY" ]; then
    curl -sk -o /dev/null "$API/service/categoryentry/action/add" -d "ks=$KS&format=1&categoryEntry:objectType=KalturaCategoryEntry&categoryEntry:categoryId=$CATEGORY&categoryEntry:entryId=$ENTRY"
    pass "category $CATEGORY"
else
    fail "category.add returned no id"
fi

step "playlist create + execute"
PLAYLIST=$(curl -sk "$API/service/playlist/action/add" -d "ks=$KS&format=1&playlist:objectType=KalturaPlaylist&playlist:name=verify-$(date +%s)&playlist:playlistType=3&playlist:playlistContent=$ENTRY" | jstr id)
if [ -n "$PLAYLIST" ]; then
    n=$(curl -sk "$API/service/playlist/action/execute" -d "ks=$KS&format=1&id=$PLAYLIST" | grep -c '"objectType":"KalturaMediaEntry"' || true)
    [ "${n:-0}" -ge 1 ] && pass "$n entry returned" || fail "playlist executed but returned nothing"
else
    fail "playlist.add returned no id"
fi

step "Sphinx search by tag"
sleep 3
n=$(curl -sk "$API/service/media/action/list" -d "ks=$KS&format=1&filter:objectType=KalturaMediaEntryFilter&filter:tagsLike=kaltura-verify" | jnum totalCount)
[ "${n:-0}" -ge 1 ] && pass "$n hit(s)" || fail "tag search returned $n — Sphinx index not updated"

step "Sphinx filter by category"
if [ -n "${CATEGORY:-}" ]; then
    n=$(curl -sk "$API/service/media/action/list" -d "ks=$KS&format=1&filter:objectType=KalturaMediaEntryFilter&filter:categoriesIdsMatchOr=$CATEGORY" | jnum totalCount)
    [ "${n:-0}" -ge 1 ] && pass "$n hit(s)" || fail "category filter returned $n"
else
    skip "no category created"
fi

# ── Analytics ─────────────────────────────────────────────────────────────────
sect "Analytics"
step "beacon endpoint accepts events"
codes=""
for i in 1 2 3 4 5; do
    codes="$codes$(curl -sk -o /dev/null -w '%{http_code} ' -A 'Mozilla/5.0 (Macintosh) Chrome/120' \
        "$BASE/api_v3/index.php?service=analytics&action=trackEvent&eventType=$([ $i -le 2 ] && echo 1 || echo 3)&partnerId=$PID&entryId=$ENTRY&sessionId=verify$$&eventIndex=$i&position=0&playTimeSum=0&clientTag=verify")"
done
[ "$(tr ' ' '\n' <<<"$codes" | grep -c '^200$')" = "5" ] && pass "5/5 accepted" || fail "responses: $codes"

step "cross-partner beacon rejected"
# The endpoint is unauthenticated by design; the receiver must at least refuse
# events whose partnerId does not own the entry, or any tenant can poison any
# other tenant's reports.
before=$(docker logs kaltura_analytics_receiver 2>&1 | grep -c 'ingested' || true)
curl -sk -o /dev/null "$BASE/api_v3/index.php?service=analytics&action=trackEvent&eventType=3&partnerId=999999&entryId=$ENTRY&sessionId=evil$$&eventIndex=1"
sleep 1
if [ "$DRUID_UP" = yes ]; then
    sleep 20
    got=$(curl -s -X POST http://127.0.0.1:8082/druid/v2/ -H 'Content-Type: application/json' \
        -d '{"queryType":"groupBy","dataSource":"player-events-historical","intervals":["2000-01-01/2100-01-01"],"granularity":"all","dimensions":["partnerId"],"aggregations":[{"type":"longSum","name":"c","fieldName":"count"}]}' 2>/dev/null | grep -c '"partnerId":"999999"' || true)
    [ "${got:-0}" -eq 0 ] && pass "forged partnerId not ingested" || fail "forged partnerId 999999 reached Druid"
else
    skip "needs Druid to confirm non-ingestion"
fi

step "receiver ingests into Druid"
if [ "$DRUID_UP" = no ]; then
    skip "analytics stack not running (core-only mode)"
else
    deadline=$(( $(date +%s) + 90 )); seen=no
    while [ "$(date +%s)" -lt "$deadline" ]; do
        docker logs --since 5m kaltura_analytics_receiver 2>&1 | grep -q 'ingested [0-9]* events' && { seen=yes; break; }
        sleep 5
    done
    [ "$seen" = yes ] && pass || fail "receiver never reported an ingest in 90s"
fi

step "report API returns data"
if [ "$DRUID_UP" = no ]; then
    skip "analytics stack not running"
elif [ "${VERIFY_ANALYTICS:-0}" != "1" ]; then
    skip "set VERIFY_ANALYTICS=1 (adds ~3 min for segment publish)"
else
    FROM=$(date -u -v-1d +%Y%m%d 2>/dev/null || date -u -d yesterday +%Y%m%d)
    TO=$(date -u -v+1d +%Y%m%d 2>/dev/null || date -u -d tomorrow +%Y%m%d)
    deadline=$(( $(date +%s) + 240 )); got=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        got=$(curl -sk "$API/service/report/action/getTable" -d "ks=$KS&format=1&reportType=1&reportInputFilter:objectType=KalturaReportInputFilter&reportInputFilter:fromDay=$FROM&reportInputFilter:toDay=$TO&pager:objectType=KalturaFilterPager&pager:pageSize=5" | jstr data)
        [ -n "$got" ] && break
        sleep 20
    done
    [ -n "$got" ] && pass "$(cut -c1-40 <<<"$got")" || fail "report API returned no rows after 240s"
fi

# ── Live streaming ────────────────────────────────────────────────────────────
sect "Live streaming"
LIVE_STREAM="verify$$"
rtmp_push() {  # $1 = full rtmp url; success = ffmpeg exit 0
    docker exec kaltura_batch sh -c \
        "ffmpeg-real -loglevel error -re -f lavfi -i testsrc=duration=3:size=320x240:rate=10 -c:v libx264 -preset ultrafast -f flv '$1' >/dev/null 2>&1"
}
step "publish WITHOUT token is refused"
if [ -z "${LIVE_PUBLISH_TOKEN:-}" ] && [ "${LIVE_ALLOW_ANON_PUBLISH:-}" = "1" ]; then
    skip "LIVE_ALLOW_ANON_PUBLISH=1 — auth intentionally disabled"
elif ! docker inspect -f '{{.State.Running}}' kaltura_live_rtmp 2>/dev/null | grep -q true; then
    skip "live-rtmp not running"
else
    rtmp_push "rtmp://live-rtmp:1935/kLive/$LIVE_STREAM" \
        && fail "publish succeeded with NO token — auth is open" \
        || pass "refused"
fi

step "publish WITH token is accepted"
if [ -z "${LIVE_PUBLISH_TOKEN:-}" ]; then
    skip "no LIVE_PUBLISH_TOKEN configured"
elif ! docker inspect -f '{{.State.Running}}' kaltura_live_rtmp 2>/dev/null | grep -q true; then
    skip "live-rtmp not running"
else
    rtmp_push "rtmp://live-rtmp:1935/kLive/$LIVE_STREAM?t=$LIVE_PUBLISH_TOKEN" \
        && pass "accepted" || fail "valid token was refused — encoders cannot publish"
fi

step "HLS produced for the published stream"
if docker exec kaltura_live_rtmp ls "/var/tmp/hlsme/$LIVE_STREAM.m3u8" >/dev/null 2>&1; then
    pass; docker exec kaltura_live_rtmp sh -c "rm -f /var/tmp/hlsme/${LIVE_STREAM}* /opt/kaltura/live_recordings/${LIVE_STREAM}*" 2>/dev/null
else
    skip "no stream was published"
fi

# ── Mail ──────────────────────────────────────────────────────────────────────
sect "Mail"
step "msmtp relay configured"
if [ -z "${SMTP_HOST:-}" ]; then
    skip "SMTP_HOST unset — outgoing mail disabled by configuration"
else
    docker exec kaltura_batch test -f /etc/msmtprc 2>/dev/null && pass "$SMTP_HOST" || fail "/etc/msmtprc missing in the batch container"
fi

step "mail templates rendered"
# The bug this guards: emails_en.ini was never generated, so Kaltura's mails
# went out with an empty subject and body.
if docker exec kaltura_batch test -s /opt/kaltura/app/batch/batches/Mailer/emails_en.ini 2>/dev/null; then
    # No `|| echo 0` here: grep -c already prints 0, and exits 1 while doing so,
    # which would append a second line and break the integer test.
    left=$(docker exec kaltura_batch sh -c "grep -c '@[A-Z_]*@' /opt/kaltura/app/batch/batches/Mailer/emails_en.ini 2>/dev/null")
    [ -z "$left" ] && left=0
    [ "$left" -eq 0 ] && pass "no unsubstituted tokens" || fail "$left unsubstituted @TOKEN@ left"
else
    fail "emails_en.ini missing or empty — mails would have empty subject/body"
fi

step "delivery through the relay"
if [ -z "${SMTP_HOST:-}" ]; then
    skip "SMTP_HOST unset"
elif [ "${VERIFY_MAIL:-0}" != "1" ]; then
    skip "set VERIFY_MAIL=1 to send a real message"
else
    docker exec kaltura_batch php -r 'exit(mail("verify@localhost","Kaltura verify","body","From: '"${SMTP_FROM:-no-reply@$WWW_HOST}"'") ? 0 : 1);' 2>/dev/null \
        && pass "accepted by $SMTP_HOST" || fail "mail() returned false — see /opt/kaltura/log/msmtp.log"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n\033[1m%s\033[0m\n' "Summary"
for r in "${RESULTS[@]}"; do
    st=${r%%|*}; rest=${r#*|}; name=${rest%%|*}; note=${rest#*|}
    case $st in
        PASS) c='\033[32m' ;; FAIL) c='\033[31m' ;; *) c='\033[33m' ;;
    esac
    [ "$st" = PASS ] && continue
    printf "  ${c}%-5s\033[0m %-44s %s\n" "$st" "$name" "$note"
done
printf '\n  %d checks: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m, \033[33m%d skipped\033[0m\n' \
    "$total" "$passed" "$failed" "$skipped"
[ "$failed" -gt 0 ] && exit 1
exit 0
