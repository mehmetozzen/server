#!/bin/bash
# Scheduler sidecar: runs the periodic maintenance the bare-metal installer
# wires into the host cron (configurations/cron/*.template) and logrotate
# (configurations/logrotate/*.template). Containers have no host cron, so
# without this service logs grow unbounded (the #1 disk filler) and API cache
# and deleted-content files are never cleaned up.
#
# Reuses the batch image (same PHP runtime Kaltura scripts need) with this
# entrypoint overriding the batch one via docker-compose.
set -e

APP_DIR=/opt/kaltura/app
LOG_DIR=/opt/kaltura/log
TMP_DIR=/opt/kaltura/tmp
MARKER="$APP_DIR/.kaltura_installed"

log() { echo "[scheduler] $*"; }

# ── Wait until the app container has finished first-time initialization ───────
# The cron jobs bootstrap the Kaltura PHP stack and need the generated
# configurations/*.ini files plus a seeded database.
log "Waiting for Kaltura initialization marker..."
until [ -f "$MARKER" ]; do sleep 10; done
log "Kaltura initialized ($(cat "$MARKER"))."

# ── Hostname resolution: WWW_HOST → kaltura app container ─────────────────────
# Same as the batch entrypoint: the recording-upload job calls the Kaltura API
# at https://$WWW_HOST; without this mapping the name may resolve to the host
# machine (or 127.0.0.1) instead of the app container.
if [ -n "${WWW_HOST:-}" ]; then
    until KALTURA_IP=$(getent hosts kaltura 2>/dev/null | awk '{print $1}' | head -1) && [ -n "$KALTURA_IP" ]; do
        sleep 2
    done
    grep -q " $WWW_HOST" /etc/hosts || echo "$KALTURA_IP $WWW_HOST" >> /etc/hosts
    log "Mapped $WWW_HOST -> $KALTURA_IP (kaltura app)."
fi

# ── /etc/kaltura.d/system.ini ──────────────────────────────────────────────────
# The official cron scripts (alpha/crond/kaltura/clear_cache.sh) source this
# env file; on bare metal the RPM installer creates it. Mirror it here.
mkdir -p /etc/kaltura.d
cat > /etc/kaltura.d/system.ini <<EOF
BASE_DIR=/opt/kaltura
APP_DIR=$APP_DIR
WEB_DIR=/opt/kaltura/web
LOG_DIR=$LOG_DIR
TMP_DIR=$TMP_DIR
PHP_BIN=/usr/local/bin/php
EOF

# ── Secrets for cron jobs ─────────────────────────────────────────────────────
# /etc/cron.d files are world-readable; DB credentials must not be inlined
# there. Root-only env file, sourced explicitly by the jobs that need it.
umask 077
cat > /etc/kaltura.d/docker.env <<EOF
export DB1_HOST=${DB1_HOST:-mysql}
export DB1_PORT=${DB1_PORT:-3306}
export DB1_NAME=${DB1_NAME:-kaltura}
export DB1_USER=${DB1_USER:-kaltura}
export DB1_PASS=${DB1_PASS:-}
export LIVE_PARTNER_ID=${LIVE_PARTNER_ID:-}
export WWW_HOST=${WWW_HOST:-localhost}
export PROTOCOL=${PROTOCOL:-https}
EOF
umask 022

# ── logrotate config ───────────────────────────────────────────────────────────
# Derived from configurations/logrotate/*.template with one container
# adaptation: apache and the batch daemon hold their log files open and we
# cannot reload them from this container (the templates assume `service ...
# reload`), so those logs use copytruncate instead of rename.
cat > /etc/logrotate.d/kaltura <<EOF
# PHP request-scoped logs — every request reopens the file, rename is safe.
# (configurations/logrotate/kaltura_api.template + kaltura_base.template)
$LOG_DIR/kaltura_api_v3.log
$LOG_DIR/kaltura_api_v3_analytics.log
$LOG_DIR/kaltura_api_v3_tests.log
$LOG_DIR/kaltura_prod.log
$LOG_DIR/kaltura_admin.log
$LOG_DIR/kaltura_scripts.log
$LOG_DIR/cron.log
$LOG_DIR/clear_cache.log
$LOG_DIR/kaltura_cleanup.log
$LOG_DIR/live_recordings.log
{
    daily
    rotate 5
    compress
    dateext
    missingok
    notifempty
    su www-data www-data
}

# Daemon-held logs — apache / KGenericBatchMgr keep the fd open; copytruncate
# rotates without needing a service reload from another container.
# (kaltura_apache.template + kaltura_batch.template equivalents)
$LOG_DIR/apache_access.log
$LOG_DIR/apache_error.log
$LOG_DIR/php_error.log
$LOG_DIR/kaltura_batch.log
$LOG_DIR/batch/*.log
{
    daily
    rotate 5
    compress
    copytruncate
    missingok
    notifempty
    su www-data www-data
}

# One-shot install/deploy logs — cap by size, keep one compressed copy.
$LOG_DIR/insertPermissions.log
$LOG_DIR/insertContent.log
$LOG_DIR/insertDefaults.log
$LOG_DIR/installPlugins.log
$LOG_DIR/generate.log
$LOG_DIR/dwh_load.log
$LOG_DIR/uiconf_deploy.log
$LOG_DIR/uiconf_fix.log
{
    size 50M
    rotate 1
    compress
    copytruncate
    missingok
    notifempty
    su www-data www-data
}
EOF

# ── cron jobs ──────────────────────────────────────────────────────────────────
# Mirrors configurations/cron/api.template and cleanup.template (the dwh
# template is Pentaho ETL we replace with Druid; kava sync needs a feeder we
# don't run yet). User field: bare metal uses `apache`/`root`; here everything
# that touches app/web files runs as www-data to keep ownership consistent.
cat > /etc/cron.d/kaltura <<EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# No MTA in this container; without this cron tries to mail every job's output
# and logs a delivery failure per run.
MAILTO=""
# Non-secret env only — DB credentials live in root-only /etc/kaltura.d/docker.env
WWW_HOST=${WWW_HOST:-localhost}
PROTOCOL=${PROTOCOL:-https}

# API cache cleanup (configurations/cron/api.template).
# Invoked via `bash <script>`, not directly: the script is mode 0644 in git and
# the tree is bind-mounted, so it has no exec bit here (bare metal gets it from
# the RPM installer). Executing it directly fails every run with
# "bad interpreter: Permission denied" and the API cache is never cleaned.
*/15 * * * * www-data /bin/bash $APP_DIR/alpha/crond/kaltura/clear_cache.sh >> $LOG_DIR/cron.log 2>&1

# Deleted/old content file cleanup (configurations/cron/cleanup.template)
*/15 * * * * www-data /usr/local/bin/php $APP_DIR/alpha/scripts/batch/deleteOldContent.php --real-run --old-versions --files >> $LOG_DIR/kaltura_cleanup.log 2>&1

# Live recordings → VOD entries (root: the files are written by the nginx
# user of the live-rtmp container; no-op until LIVE_PARTNER_ID is set).
# Sources the root-only env file for DB credentials.
* * * * * root . /etc/kaltura.d/docker.env && /usr/local/bin/php $APP_DIR/docker/scheduler/upload_recordings.php >> $LOG_DIR/live_recordings.log 2>&1

# Log rotation (state lives on the log volume so it survives recreates)
17 * * * * root /usr/sbin/logrotate -s $LOG_DIR/.logrotate.state /etc/logrotate.d/kaltura >> $LOG_DIR/cron.log 2>&1

# Shared tmp janitor: convert/upload leftovers older than 7 days
30 3 * * * www-data find $TMP_DIR -type f -mtime +7 -delete >> $LOG_DIR/cron.log 2>&1
EOF
chmod 0644 /etc/cron.d/kaltura

# ── First boot: force one rotation so already-bloated logs shrink immediately ──
if [ ! -f "$LOG_DIR/.logrotate.state" ]; then
    log "First run — forcing initial log rotation..."
    /usr/sbin/logrotate -f -s "$LOG_DIR/.logrotate.state" /etc/logrotate.d/kaltura \
        >> "$LOG_DIR/cron.log" 2>&1 || true
fi

log "Cron jobs installed:"
grep -vE '^(SHELL|PATH|#|$)' /etc/cron.d/kaltura | sed 's/^/[scheduler]   /'
log "Starting cron..."
exec cron -f
