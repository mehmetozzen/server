#!/bin/bash
set -e

APP_DIR=/opt/kaltura/app
LOG_DIR=/opt/kaltura/log
TMP_DIR=/opt/kaltura/tmp
DB_HOST="${DB1_HOST:-mysql}"
DB_PORT="${DB1_PORT:-3306}"
DB_USER="${DB1_USER:-kaltura}"
# Fail-closed credentials — same policy as the app entrypoint.
DB_PASS="${DB1_PASS:?DB1_PASS must be set in docker/kaltura.conf (run: make -C docker config)}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD must be set in docker/kaltura.conf (run: make -C docker config)}"
TIME_ZONE="${TIME_ZONE:-UTC}"
SERVICE_PROTOCOL="${PROTOCOL:-http}"
WWW_HOST="${WWW_HOST:-kaltura.example.com}"
SERVICE_URL="${SERVICE_URL:-${SERVICE_PROTOCOL}://${WWW_HOST}}"

# ── Outgoing mail: /etc/msmtprc from SMTP_* env (see docker/common/setup-msmtp.sh)
# The Mailer batch worker (KAsyncMailer → PHPMailer → mail() → sendmail_path)
# runs in THIS container, so the relay config is required here above all.
[ -f /opt/kaltura/setup-msmtp.sh ] && . /opt/kaltura/setup-msmtp.sh

# ── Install local CA into container trust store (mkcert HTTPS support) ────────
if [ -f /opt/kaltura/certs/rootCA.pem ]; then
    cp /opt/kaltura/certs/rootCA.pem /usr/local/share/ca-certificates/mkcert-rootCA.crt
    update-ca-certificates --fresh > /dev/null 2>&1
    echo "[batch] Installed mkcert root CA into container trust store."
fi

# ── Directories ────────────────────────────────────────────────────────────────
mkdir -p \
    "$LOG_DIR/batch" \
    "$TMP_DIR" \
    "$APP_DIR/configurations/batch" \
    "$APP_DIR/cache/batch" \
    "$APP_DIR/var/run"

# Remove stale PID files from a previous run. ALL of them, not just batch.pid:
# pidFileDir gets one file per worker, and the scheduler refuses to start when
# it finds a pid file whose process still exists — inside a container PID 1 is
# always alive, so a leftover "1" reads as "scheduler already running".
rm -f "$APP_DIR/var/run/"*.pid 2>/dev/null || true

# ── Wait for MySQL ─────────────────────────────────────────────────────────────
echo "[batch] Waiting for MySQL..."
until mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 -e "SELECT 1" > /dev/null 2>&1; do
    sleep 3
done
echo "[batch] MySQL ready."

# ── Wait for batch partner secret (app container may still be initializing) ───
echo "[batch] Waiting for Kaltura app initialization (partner -1)..."
until BATCH_SECRET=$(mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 kaltura \
    -se "SELECT admin_secret FROM partner WHERE id=-1;" 2>/dev/null) && [ -n "$BATCH_SECRET" ]; do
    echo "[batch] Partner -1 not ready yet, retrying in 5s..."
    sleep 5
done
echo "[batch] Batch partner secret found."

# ── Hostname resolution: map SERVICE_URL host → kaltura app container ──────────
# Done here (after MySQL wait) so Docker DNS has time to register the app container
until KALTURA_IP=$(getent hosts kaltura 2>/dev/null | awk '{print $1}' | head -1) && [ -n "$KALTURA_IP" ]; do
    sleep 2
done
grep -q "$WWW_HOST" /etc/hosts || echo "$KALTURA_IP $WWW_HOST" >> /etc/hosts

# ── Wait for Kaltura API ───────────────────────────────────────────────────────
echo "[batch] Waiting for Kaltura API at $SERVICE_URL..."
until curl -sf "$SERVICE_URL/api_v3/index.php?service=system&action=ping" | grep -q "<result>1</result>"; do
    echo "[batch] API not ready, retrying in 5s..."
    sleep 5
done
echo "[batch] Kaltura API ready."

# ── Generate batchBase.ini (used by kConf for API connection) ──────────────────
BATCHBASE_INI="$APP_DIR/configurations/batchBase.ini"
# Always regenerate so a fresh DB install doesn't leave a stale secret here
echo "[batch] Generating batchBase.ini..."
sed \
    -e "s|@LOG_DIR@|$LOG_DIR|g" \
    -e "s|@BASE_DIR@|$APP_DIR|g" \
    -e "s|@SERVICE_URL@|$SERVICE_URL|g" \
    -e "s|@BATCH_URL@|$SERVICE_URL|g" \
    -e "s|@BATCH_PARTNER_ADMIN_SECRET@|$BATCH_SECRET|g" \
    -e "s|@TIME_ZONE@|$TIME_ZONE|g" \
    "$APP_DIR/configurations/batchBase.template.ini" \
    > "$BATCHBASE_INI"

# ── Generate configurations/batch/batch.ini (worker config) ───────────────────
BATCH_INI="$APP_DIR/configurations/batch/batch.ini"
# Always regenerate so a fresh DB install doesn't leave a stale secret here
echo "[batch] Generating batch/batch.ini..."
BATCH_SCHEDULER_ID=$(shuf -i 10000-99999 -n 1)
BATCH_HOSTNAME=$(hostname)
sed \
    -e "s|@LOG_DIR@|$LOG_DIR|g" \
    -e "s|@BASE_DIR@|$APP_DIR|g" \
    -e "s|@WEB_DIR@|/opt/kaltura/web|g" \
    -e "s|@SERVICE_URL@|$SERVICE_URL|g" \
    -e "s|@BATCH_URL@|$SERVICE_URL|g" \
    -e "s|@BATCH_PARTNER_ADMIN_SECRET@|$BATCH_SECRET|g" \
    -e "s|@TIME_ZONE@|$TIME_ZONE|g" \
    -e "s|@TMP_DIR@|$TMP_DIR|g" \
    -e "s|@INSTALLED_HOSNAME@|$BATCH_HOSTNAME|g" \
    -e "s|@BATCH_SCHEDULER_ID@|$BATCH_SCHEDULER_ID|g" \
    -e "s|@BIN_DIR@|/usr/bin|g" \
    -e "s|@IMAGE_MAGICK_BIN_DIR@|/usr/bin|g" \
    -e "s|@FORUMS_URLS@|${FORUMS_URL:-https://forum.kaltura.org}|g" \
    -e "s|@UNSUBSCRIBE_EMAIL_URL@|${SERVICE_URL}/index.php/extwidget/unsubscribe|g" \
    /opt/kaltura/docker/batch/batch.ini.template \
    > "$BATCH_INI"
# Also clear the derived config cache so workers pick up the fresh secret
rm -f "$APP_DIR/cache/batch/config.ini" "$APP_DIR/cache/batch/config.log"

# ── Render emails_en.ini (mail subject/body texts) ────────────────────────────
# Bare metal generates this from emails_en.template.ini at install time; nothing
# in the containers did, so KAsyncMailer's texts_array stayed null and every
# outgoing mail had an empty subject and body. Regenerated on each boot (cheap,
# and picks up SERVICE_URL changes).
EMAILS_TMPL="$APP_DIR/batch/batches/Mailer/emails_en.template.ini"
EMAILS_INI="$APP_DIR/batch/batches/Mailer/emails_en.ini"
if [ -f "$EMAILS_TMPL" ]; then
    sed \
        -e "s|@SERVICE_URL@|$SERVICE_URL|g" \
        -e "s|@FORUMS_URLS@|${FORUMS_URL:-https://forum.kaltura.org}|g" \
        "$EMAILS_TMPL" > "$EMAILS_INI"
    echo "[batch] Generated emails_en.ini (mail texts)."
else
    echo "[batch] WARN: emails_en.template.ini not found — outgoing mails will have empty bodies" >&2
fi

# ── Sync plugin enums (idempotent) ─────────────────────────────────────────────
echo "[batch] Syncing plugin enums..."
cd "$APP_DIR/deployment/base/scripts"
php installPlugins.php >> "$LOG_DIR/batch/installPlugins.log" 2>&1 || true

# ── Fix ownership so batch PHP workers (www-data) can write to their dirs ──────
chown -R www-data:www-data \
    "$LOG_DIR" \
    "$TMP_DIR" \
    "$APP_DIR/configurations/batch" \
    "$APP_DIR/cache/batch" \
    "$APP_DIR/var/run" \
    2>/dev/null || true

# ── PHP 8.1 fix: KAsyncMailer::reset() on null texts_array ───────────────────
# PHP 8.1 reset() requires array; $this->texts_array is null until initConfig()
# runs — getSubjectByType and getBodyByType both fall through to reset() when
# the requested language is missing. Guard with is_array() before calling reset().
# NOTE: $APP_DIR is bind-mounted from the host repo; the patch modifies that file.
# It is idempotent (marker check) and must not be git-committed as a source change.
ASYNC_MAILER="$APP_DIR/batch/batches/Mailer/KAsyncMailer.class.php"
if [ -f "$ASYNC_MAILER" ] && ! grep -q 'is_array.*texts_array' "$ASYNC_MAILER" 2>/dev/null; then
    sed -i 's|: reset(\$this->texts_array)|: (/* PHP81 */is_array($this->texts_array) ? reset($this->texts_array) : array())|g' \
        "$ASYNC_MAILER" \
        && echo "[batch] KAsyncMailer.class.php: patched reset() for PHP 8.1 null texts_array" \
        || echo "[batch] WARN: KAsyncMailer.class.php reset() patch did not apply"
fi

# ── PHP 8 fix: KScheduleHelperManager::loadStatuses() TypeError on empty file ──
# loadStatuses() computes time() - file_get_contents(cache/update.log). If the
# file is ever left empty (e.g. a write cut short by a restart), PHP 8 throws a
# fatal TypeError for int - "" (PHP 7 only warned). display_errors is off, so
# KScheduleHelper dies silently every cycle BEFORE batchcontrol->reportStatus —
# queue sizes never reach KGenericScheduler, shouldExecute() never passes, and
# no on-demand worker (KAsyncConvert, KAsyncExtractMedia, ...) is ever spawned:
# every transcode job sits in PENDING forever. Cast to (int) so an empty/corrupt
# file degrades to 0 (i.e. "stale, refresh now") instead of killing the helper.
# NOTE: $APP_DIR is bind-mounted from the host repo; the patch modifies that file.
# It is idempotent (marker check) and must not be git-committed as a source change.
SCHED_HELPER_MGR="$APP_DIR/batch/scheduler/KScheduleHelperManager.class.php"
if [ -f "$SCHED_HELPER_MGR" ] && ! grep -qF '(int)file_get_contents($lastFileUpdateTimeStampPath)' "$SCHED_HELPER_MGR" 2>/dev/null; then
    sed -i 's|= file_get_contents($lastFileUpdateTimeStampPath);|= /* PHP8 */(int)file_get_contents($lastFileUpdateTimeStampPath);|' \
        "$SCHED_HELPER_MGR" \
        && echo "[batch] KScheduleHelperManager.class.php: patched loadStatuses() int cast for PHP 8 empty update.log" \
        || echo "[batch] WARN: KScheduleHelperManager.class.php loadStatuses() patch did not apply"
fi

# Defense in depth for the same bug: make sure cache/update.log holds a numeric
# timestamp before the batch manager starts (covers a file corrupted while the
# container was down, without waiting for the next loadStatuses() write).
UPDATE_LOG="$APP_DIR/cache/update.log"
[ -d "$UPDATE_LOG" ] && rm -rf "$UPDATE_LOG"   # kFile::fullMkdir can leave a dir here
if ! grep -qE '^[0-9]+$' "$UPDATE_LOG" 2>/dev/null; then
    date +%s > "$UPDATE_LOG"
    chown www-data:www-data "$UPDATE_LOG" 2>/dev/null || true
    echo "[batch] cache/update.log: seeded with current timestamp (was missing/empty/non-numeric)"
fi

# ── Start batch manager as www-data ───────────────────────────────────────────
# Running as www-data ensures batch-created temp files are www-data-owned,
# so the app container (also www-data) can rename/delete them without AGPL source changes.
echo "[batch] Starting KGenericBatchMgr..."
echo "[batch] PHP version: $(php -r 'echo PHP_VERSION;')"
echo "[batch] Config dir: $(ls $APP_DIR/configurations/batch/)"
echo "[batch] batchBase.ini: $(test -f $APP_DIR/configurations/batchBase.ini && echo YES || echo NO)"

PHP_BIN=$(which php)
echo "[batch] PHP binary: $PHP_BIN"

# ── Wait for the generated client SDK ─────────────────────────────────────────
# bootstrap.php requires batch/client/KalturaClient.php, which is generated by
# the app container from the live API schema. Starting without it is an
# immediate fatal in PHP's bootstrap — before the logger exists, so the
# container just exits 255 with an empty log and restarts forever. Waiting here
# turns that into a legible message and lets a first boot settle on its own.
CLIENT="$APP_DIR/batch/client/KalturaClient.php"
if [ ! -f "$CLIENT" ]; then
    echo "[batch] Waiting for the generated client SDK ($CLIENT)..."
    for _i in $(seq 1 60); do
        [ -f "$CLIENT" ] && break
        sleep 5
    done
fi
[ -f "$CLIENT" ] \
    || echo "[batch] WARN: $CLIENT still missing after 5 minutes — the app container generates it; check 'docker logs kaltura_app' for client SDK errors" >&2

# ── Last-moment ownership re-assert (race with the app container) ─────────────
# The app container runs installPlugins.php and other init steps as ROOT, on
# every one of its boots, writing into the log volume and the shared cache/
# tree. Our chown above can therefore be undone between then and now: on a
# first boot the app is still initialising while we get here. Re-assert
# immediately before exec so the manager always starts against files it can
# write. Cheap (a few dozen entries) and idempotent.
chown -R www-data:www-data "$LOG_DIR" "$APP_DIR/cache" 2>/dev/null || true
chmod 644 "$APP_DIR/cache/scripts/classMap.cache" 2>/dev/null || true

exec gosu www-data php "$APP_DIR/batch/KGenericBatchMgr.class.php" \
    "$PHP_BIN" \
    "$APP_DIR/configurations/batch"
