#!/bin/bash
set -e

APP_DIR=/opt/kaltura/app
LOG_DIR=/opt/kaltura/log
TMP_DIR=/opt/kaltura/tmp
DB_HOST="${DB1_HOST:-mysql}"
DB_PORT="${DB1_PORT:-3306}"
DB_USER="${DB1_USER:-kaltura}"
DB_PASS="${DB1_PASS:-kaltura123}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-kaltura_root}"
TIME_ZONE="${TIME_ZONE:-UTC}"
SERVICE_PROTOCOL="${PROTOCOL:-http}"
WWW_HOST="${WWW_HOST:-kaltura.example.com}"
SERVICE_URL="${SERVICE_URL:-${SERVICE_PROTOCOL}://${WWW_HOST}}"

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

# Remove stale PID file from previous run
rm -f "$APP_DIR/var/run/batch.pid"

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
    /opt/kaltura/docker/batch/batch.ini.template \
    > "$BATCH_INI"
# Also clear the derived config cache so workers pick up the fresh secret
rm -f "$APP_DIR/cache/batch/config.ini" "$APP_DIR/cache/batch/config.log"

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

# ── Start batch manager as www-data ───────────────────────────────────────────
# Running as www-data ensures batch-created temp files are www-data-owned,
# so the app container (also www-data) can rename/delete them without AGPL source changes.
echo "[batch] Starting KGenericBatchMgr..."
echo "[batch] PHP version: $(php -r 'echo PHP_VERSION;')"
echo "[batch] Config dir: $(ls $APP_DIR/configurations/batch/)"
echo "[batch] batchBase.ini: $(test -f $APP_DIR/configurations/batchBase.ini && echo YES || echo NO)"

PHP_BIN=$(which php)
echo "[batch] PHP binary: $PHP_BIN"

exec gosu www-data php "$APP_DIR/batch/KGenericBatchMgr.class.php" \
    "$PHP_BIN" \
    "$APP_DIR/configurations/batch"
