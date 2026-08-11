#!/bin/bash
set -e

APP_DIR=/opt/kaltura/app
WEB_DIR=/opt/kaltura/web
LOG_DIR=/opt/kaltura/log
TMP_DIR=/opt/kaltura/tmp
DB_HOST="${DB1_HOST:-mysql}"
DB_PORT="${DB1_PORT:-3306}"
DB_USER="${DB1_USER:-kaltura}"
# Credentials are fail-CLOSED: no silent fallbacks. A stack that boots with
# publicly-known defaults on ports 80/443 is worse than one that refuses to
# boot — `make config` generates strong values into docker/kaltura.conf.
DB_PASS="${DB1_PASS:?DB1_PASS must be set in docker/kaltura.conf (run: make -C docker config)}"
DB_NAME="${DB1_NAME:-kaltura}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD must be set in docker/kaltura.conf (run: make -C docker config)}"
TIME_ZONE="${TIME_ZONE:-UTC}"
SERVICE_PROTOCOL="${PROTOCOL:-http}"
SERVICE_PORT=$( [ "$SERVICE_PROTOCOL" = "https" ] && echo 443 || echo 80 )
WWW_HOST="${WWW_HOST:-kaltura.example.com}"
SERVICE_URL="${SERVICE_URL:-${SERVICE_PROTOCOL}://${WWW_HOST}}"
ADMIN_EMAIL="${ADMIN_CONSOLE_ADMIN_MAIL:-admin@kaltura.local}"
ADMIN_PASS="${ADMIN_CONSOLE_PASSWORD:?ADMIN_CONSOLE_PASSWORD must be set in docker/kaltura.conf (run: make -C docker config)}"
MARKER="$APP_DIR/.kaltura_installed"

# Refuse un-edited placeholders outright; warn on the old known-weak defaults so
# existing dev setups keep booting but the operator is told, every boot.
for _cred in DB_PASS MYSQL_ROOT_PASS ADMIN_PASS; do
    case "${!_cred}" in
        *CHANGEME*) echo "[kaltura] FATAL: $_cred still contains the CHANGEME placeholder — edit docker/kaltura.conf" >&2; exit 1 ;;
        kaltura123|kaltura_root|Admin1234!)
            echo "[kaltura] WARN: $_cred uses a publicly-known default value — change it before exposing this host" >&2 ;;
    esac
done

# Vendored-app versions. Sourced from the image ENV (set in the Dockerfile from
# the matching build ARG); the fallbacks keep the script self-contained. Every
# version-specific path/patch below references these — never hardcode a version.
HTML5LIB_VERSION="${HTML5LIB_VERSION:-v2.7.4}"
STUDIO_VERSION="${STUDIO_VERSION:-v2.2.3}"

# ── Logging helpers ──────────────────────────────────────────────────────────
# One consistent prefix; warnings go to stderr so `... 2>&1 | grep WARN` works.
log()  { echo "[kaltura] $*"; }
warn() { echo "[kaltura] WARN: $*" >&2; }

# ── Dependency connectivity probe ────────────────────────────────────────────
# Probe a backing service and print a clear reachable/unreachable line, so a
# missing dependency is visible at boot instead of failing silently at request
# time. Retries briefly (required services are already gated healthy by compose;
# the optional Druid boots independently and may still be coming up).
#   probe <label> <required|optional> <command...>
probe() {
    local label="$1" mode="$2"; shift 2
    local i=0 reachable=1
    while [ "$i" -lt 8 ]; do
        if "$@" >/dev/null 2>&1; then reachable=0; break; fi
        i=$(( i + 1 )); sleep 2
    done
    if [ "$reachable" -eq 0 ]; then
        log "  $(printf '%-26s' "$label") reachable"
    elif [ "$mode" = optional ]; then
        log "  $(printf '%-26s' "$label") not up yet (optional — boots independently)"
    else
        warn "$(printf '%-26s' "$label") UNREACHABLE"
    fi
}

# ── Outgoing mail: /etc/msmtprc from SMTP_* env (see docker/common/setup-msmtp.sh)
[ -f /opt/kaltura/setup-msmtp.sh ] && . /opt/kaltura/setup-msmtp.sh

# ── Install local CA into container trust store (mkcert HTTPS support) ────────
if [ -f /opt/kaltura/certs/rootCA.pem ]; then
    cp /opt/kaltura/certs/rootCA.pem /usr/local/share/ca-certificates/mkcert-rootCA.crt
    update-ca-certificates --fresh > /dev/null 2>&1
    echo "[kaltura] Installed mkcert root CA into container trust store."
fi

# ── Configure Apache VirtualHost from template ─────────────────────────────────
# Must run before any apache2ctl start so the temp init Apache has Kaltura routes.
setup_apache() {
    local BODY_TMPL="/etc/apache2/kaltura-vhost-body.template"
    local CONF_OUT="/etc/apache2/sites-enabled/000-default.conf"
    local BODY
    BODY=$(sed "s|@WWW_HOST@|$WWW_HOST|g" "$BODY_TMPL")
    # Media proxy rules must live in whichever vhost serves traffic. With
    # PROTOCOL=http the :80 vhost is the ONLY one — without these rules all
    # packaged VOD (/hls/, /dash/) and live (/hlsme/, /dc-0/live/) playback
    # 404s, because delivery_profile URLs are rewritten to route via Apache.
    # X-Forwarded-Proto carries the real scheme so the packager's vod_base_url
    # generates correct absolute segment URLs in both modes.
    emit_media_proxy() {
        printf '    ProxyPreserveHost On\n'
        printf '    RequestHeader set X-Forwarded-Proto "%s"\n' "$SERVICE_PROTOCOL"
        printf '    ProxyPass /hls/ http://packager:88/hls/\n'
        printf '    ProxyPassReverse /hls/ http://packager:88/hls/\n'
        printf '    ProxyPass /dash/ http://packager:88/dash/\n'
        printf '    ProxyPassReverse /dash/ http://packager:88/dash/\n'
        printf '    ProxyPass /hlsme/ http://live-rtmp:8090/hlsme/\n'
        printf '    ProxyPassReverse /hlsme/ http://live-rtmp:8090/hlsme/\n'
        printf '    ProxyPass /dc-0/live/ http://live-rtmp:8090/dc-0/live/\n'
        printf '    ProxyPassReverse /dc-0/live/ http://live-rtmp:8090/dc-0/live/\n'
    }
    {
        printf '<VirtualHost *:80>\n'
        printf '    ServerName %s\n' "$WWW_HOST"
        if [ "$SERVICE_PROTOCOL" = "https" ]; then
            printf '    Redirect permanent / https://%s/\n' "$WWW_HOST"
        else
            printf '%s\n' "$BODY"
            emit_media_proxy
        fi
        printf '</VirtualHost>\n'
        if [ "$SERVICE_PROTOCOL" = "https" ]; then
            a2enmod ssl > /dev/null 2>&1 || true
            printf '\n<VirtualHost *:443>\n'
            printf '    ServerName %s\n' "$WWW_HOST"
            printf '    SSLEngine on\n'
            printf '    SSLCertificateFile %s\n' "${SSL_CRT_FILE:-/opt/kaltura/certs/server.crt}"
            printf '    SSLCertificateKeyFile %s\n' "${SSL_KEY_FILE:-/opt/kaltura/certs/server.key}"
            [ -n "${SSL_CA_FILE:-}" ] && printf '    SSLCertificateChainFile %s\n' "$SSL_CA_FILE"
            printf '%s\n' "$BODY"
            emit_media_proxy
            printf '</VirtualHost>\n'
        fi
    } > "$CONF_OUT"
    echo "[kaltura] Apache config generated for $SERVICE_PROTOCOL://$WWW_HOST"
}
setup_apache

# ── Directories & permissions ──────────────────────────────────────────────────
mkdir -p \
    "$WEB_DIR/cache" \
    "$WEB_DIR/content" \
    "$WEB_DIR/tmp/convert" \
    "$WEB_DIR/tmp/bulkupload" \
    "$WEB_DIR/tmp/thumb" \
    "$WEB_DIR/tmp/imports" \
    "$WEB_DIR/flash" \
    "$LOG_DIR" \
    "$TMP_DIR" \
    "$APP_DIR/cache"

chown -R www-data:www-data "$WEB_DIR" "$LOG_DIR" "$TMP_DIR" "$APP_DIR/cache" 2>/dev/null || true

# ── Link /opt/kaltura/apps (KMC NG, studio, etc.) into BASE_DIR ───────────────
[ ! -e "$APP_DIR/apps" ] && ln -sf /opt/kaltura/apps "$APP_DIR/apps"

# ── api_v3 symlink: Apache routes /api_v3/ → alpha/web/api_v3/ ────────────────
# Without this symlink insertContent.php (admin user creation) and all API
# calls return 404, causing "Invalid credentials" on the admin console.
mkdir -p "$APP_DIR/alpha/web"
[ ! -e "$APP_DIR/alpha/web/api_v3" ] && \
    ln -sf "$APP_DIR/api_v3/web" "$APP_DIR/alpha/web/api_v3"

# ── Hostname resolution for API self-calls ─────────────────────────────────────
grep -q "$WWW_HOST" /etc/hosts || echo "127.0.0.1 $WWW_HOST" >> /etc/hosts

# ── Wait for MySQL ─────────────────────────────────────────────────────────────
echo "[kaltura] Waiting for MySQL at $DB_HOST:$DB_PORT..."
until mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 -e "SELECT 1" > /dev/null 2>&1; do
    echo "[kaltura] MySQL not ready, retrying in 3s..."
    sleep 3
done
echo "[kaltura] MySQL is ready."

# ── Dependency connectivity ────────────────────────────────────────────────────
# MySQL is confirmed above; report the rest so any missing backend is obvious.
log "Checking service connectivity..."
probe "MySQL    ($DB_HOST:$DB_PORT)"  required mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 -e "SELECT 1"
probe "Sphinx   (sphinx:9312)"        required mysql -h sphinx -P 9312 --ssl=0 -e "SHOW TABLES"
probe "Memcache (memcache:11211)"     required bash -c 'exec 3<>/dev/tcp/memcache/11211'
probe "Bundler  (bundler:8080)"       required curl -sf http://bundler:8080/health
probe "Druid    (druid-broker:8082)"  optional curl -sf http://druid-broker:8082/status/health

# ── Per-deployment secrets (preserved across container restarts) ───────────────
# These are random values referenced as @TOKEN@, @POLL_SECRET@, etc. in templates.
# Persisted to disk so .ini files stay consistent if regenerated.
SECRETS_FILE="$APP_DIR/configurations/.docker_secrets.env"
if [ ! -f "$SECRETS_FILE" ]; then
    umask 077
    cat > "$SECRETS_FILE" <<EOF
DC0_SECRET=$(openssl rand -hex 20)
APP_REMOTE_ADDR_HEADER_SALT=$(openssl rand -hex 20)
DEFAULT_IV_16B=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
TOKEN=$(openssl rand -hex 20)
TOKEN_IV=$(openssl rand -hex 8)
POLL_SECRET=$(openssl rand -hex 20)
RTC_TOKEN_SECRET=$(openssl rand -hex 20)
ANALYTICS_SYNC_SECRET=$(openssl rand -hex 20)
AUTHENTICATION_SECRET=$(openssl rand -hex 20)
INSTALLATION_UID=$(cat /proc/sys/kernel/random/uuid)
EOF
    umask 022
fi
chmod 600 "$SECRETS_FILE" 2>/dev/null || true
. "$SECRETS_FILE"

# Migrate away from the old derived salt: earlier builds set
# APP_REMOTE_ADDR_HEADER_SALT to base64(SERVICE_URL), which anyone who knows
# the public hostname can compute — and it authenticates the client-IP
# override header. If the persisted value matches that derivation, replace it.
_derived_salt=$(printf '%s' "$SERVICE_URL" | base64 | tr -d '\n=')
if [ "${APP_REMOTE_ADDR_HEADER_SALT:-}" = "$_derived_salt" ]; then
    APP_REMOTE_ADDR_HEADER_SALT=$(openssl rand -hex 20)
    sed -i "s|^APP_REMOTE_ADDR_HEADER_SALT=.*|APP_REMOTE_ADDR_HEADER_SALT=$APP_REMOTE_ADDR_HEADER_SALT|" "$SECRETS_FILE"
    warn "APP_REMOTE_ADDR_HEADER_SALT was derived from the public URL — regenerated as a random secret"
fi

# ── Generate Kaltura .ini files from templates ─────────────────────────────────
# Mirrors what the official RPM installer (kaltura-base-config.sh) does:
# every *.template.ini in configurations/ is copied to *.ini with tokens substituted.
INSTALLED_HOSTNAME=$(hostname)
generate_ini_from_template() {
    local TMPL="$1"
    local DEST
    case "$TMPL" in
        *.template.ini)  DEST="${TMPL%.template.ini}.ini" ;;
        *.ini.template)  DEST="${TMPL%.ini.template}.ini" ;;
        *)               return 0 ;;
    esac
    echo "[kaltura] Generating $(basename "$DEST")..."
    sed \
        -e "s|@ENVIRONMENT_PROTOCOL@|$SERVICE_PROTOCOL|g" \
        -e "s|@PROTOCOL@|$SERVICE_PROTOCOL|g" \
        -e "s|@SERVICE_URL@|$SERVICE_URL|g" \
        -e "s|@WWW_HOST@|$WWW_HOST|g" \
        -e "s|@CDN_HOST@|$WWW_HOST|g" \
        -e "s|@IIS_HOST@|$WWW_HOST|g" \
        -e "s|@KALTURA_FULL_VIRTUAL_HOST_NAME@|$WWW_HOST|g" \
        -e "s|@KALTURA_VIRTUAL_HOST_NAME@|$WWW_HOST|g" \
        -e "s|@KALTURA_VIRTUAL_HOST_PORT@|$SERVICE_PORT|g" \
        -e "s|@DB1_HOST@|$DB_HOST|g" \
        -e "s|@DB1_NAME@|$DB_NAME|g" \
        -e "s|@DB1_USER@|$DB_USER|g" \
        -e "s|@DB1_PASS@|$DB_PASS|g" \
        -e "s|@DB1_PORT@|$DB_PORT|g" \
        -e "s|@DB2_HOST@|$DB_HOST|g" \
        -e "s|@DB2_PORT@|$DB_PORT|g" \
        -e "s|@DB2_NAME@|$DB_NAME|g" \
        -e "s|@DB2_USER@|$DB_USER|g" \
        -e "s|@DB2_PASS@|$DB_PASS|g" \
        -e "s|@DB3_HOST@|$DB_HOST|g" \
        -e "s|@DB3_PORT@|$DB_PORT|g" \
        -e "s|@DB3_NAME@|$DB_NAME|g" \
        -e "s|@DB3_USER@|$DB_USER|g" \
        -e "s|@DB3_PASS@|$DB_PASS|g" \
        -e "s|@BATCH_URL@|$SERVICE_URL|g" \
        -e "s|@SPHINX_DB_NAME@|kaltura_sphinx_log|g" \
        -e "s|@SPHINX_DB_HOST@|$DB_HOST|g" \
        -e "s|@SPHINX_DB_PORT@|$DB_PORT|g" \
        -e "s|@SPHINX_SERVER1@|sphinx|g" \
        -e "s|@SPHINX_SERVER2@|sphinx|g" \
        -e "s|@SPHINX_SERVER@|sphinx|g" \
        -e "s|@SPHINX_PORT@|9312|g" \
        -e "s|@DWH_HOST@|$DB_HOST|g" \
        -e "s|@DWH_PORT@|$DB_PORT|g" \
        -e "s|@DWH_USER@|etl|g" \
        -e "s|@DWH_PASS@|$DB_PASS|g" \
        -e "s|@DWH_DATABASE_NAME@|kalturadw|g" \
        -e "s|@DWH_DIR@|/opt/kaltura/dwh|g" \
        -e "s|@KAVA_DB_HOST@|$DB_HOST|g" \
        -e "s|@KAVA_DB_PORT@|$DB_PORT|g" \
        -e "s|@KAVA_DB_USER@|$DB_USER|g" \
        -e "s|@KAVA_DB_PASS@|$DB_PASS|g" \
        -e "s|@KAVA_DB_NAME@|$DB_NAME|g" \
        -e "s|@ADMIN_CONSOLE_ADMIN_MAIL@|$ADMIN_EMAIL|g" \
        -e "s|@REPORT_ADMIN_EMAIL@|$ADMIN_EMAIL|g" \
        -e "s|@BASE_DIR@|/opt/kaltura|g" \
        -e "s|@APP_DIR@|$APP_DIR|g" \
        -e "s|@WEB_DIR@|$WEB_DIR|g" \
        -e "s|@LOG_DIR@|$LOG_DIR|g" \
        -e "s|@TMP_DIR@|$TMP_DIR|g" \
        -e "s|@BIN_DIR@|/usr/bin|g" \
        -e "s|@PHP_BIN@|/usr/local/bin/php|g" \
        -e "s|@OS_KALTURA_USER@|www-data|g" \
        -e "s|@APACHE_SERVICE@|apache2|g" \
        -e "s|@IMAGE_MAGICK_BIN_DIR@|/usr/bin|g" \
        -e "s|@CURL_BIN_DIR@|/usr/bin|g" \
        -e "s|@INSTALLED_HOSTNAME@|$INSTALLED_HOSTNAME|g" \
        -e "s|@INSTALLED_HOSNAME@|$INSTALLED_HOSTNAME|g" \
        -e "s|@TIME_ZONE@|$TIME_ZONE|g" \
        -e "s|@KALTURA_VERSION@|22.20.0|g" \
        -e "s|@KALTURA_VERSION_TYPE@|CE|g" \
        -e "s|@ENVIRONMENT_NAME@|docker|g" \
        -e "s|@IP_RANGE@|0.0.0.0-255.255.255.255|g" \
        -e "s|@APP_REMOTE_ADDR_HEADER_SALT@|$APP_REMOTE_ADDR_HEADER_SALT|g" \
        -e "s|@DEFAULT_IV_16B@|$DEFAULT_IV_16B|g" \
        -e "s|@DC0_SECRET@|$DC0_SECRET|g" \
        -e "s|@TOKEN@|$TOKEN|g" \
        -e "s|@TOKEN_IV@|$TOKEN_IV|g" \
        -e "s|@POLL_SECRET@|$POLL_SECRET|g" \
        -e "s|@RTC_TOKEN_SECRET@|$RTC_TOKEN_SECRET|g" \
        -e "s|@ANALYTICS_SYNC_SECRET@|$ANALYTICS_SYNC_SECRET|g" \
        -e "s|@AUTHENTICATION_SECRET@|$AUTHENTICATION_SECRET|g" \
        -e "s|@INSTALLATION_UID@|$INSTALLATION_UID|g" \
        -e "s|@REPLACE_PASSWORDS@|true|g" \
        -e "s|@USAGE_TRACKING_OPTIN@|false|g" \
        -e "s|@TRACK_KDPWRAPPER@|false|g" \
        -e "s|@EXPIRY_IN_SECONDS@|60|g" \
        -e "s|@EXCHANGE_NAME@|kaltura|g" \
        -e "s|@RTMP_URL@|rtmp://$WWW_HOST|g" \
        -e "s|@PRIMARY_MEDIA_SERVER_HOST@|$WWW_HOST|g" \
        -e "s|@PRIMARY_MEDIA_SERVER_PORT@|1935|g" \
        -e "s|@SECONDARY_MEDIA_SERVER_HOST@|$WWW_HOST|g" \
        -e "s|@SECONDARY_MEDIA_SERVER_PORT@|1935|g" \
        -e "s|@VOD_PACKAGER_HOST@|$WWW_HOST|g" \
        -e "s|@VOD_PACKAGER_PORT@|$SERVICE_PORT|g" \
        -e "s|@VOD_PACKAGER_URL@|$WWW_HOST|g" \
        -e "s|@LIVE_PACKAGER_HOST@|$WWW_HOST|g" \
        -e "s|@LIVE_PACKAGER_PORT@|$SERVICE_PORT|g" \
        -e "s|@LIVE_PACKAGER_URL@|$WWW_HOST|g" \
        -e "s|@LIVE_PACKAGER_TOKEN@||g" \
        -e "s|@STORAGE_BASE_DIR@|$WEB_DIR|g" \
        -e "s|@KMCNG_VERSION@|v7.20.0|g" \
        -e "s|@DRUID_BROKER_URL@|http://druid-broker:8082|g" \
        -e "s|@DRUID_EXTERNAL_CALLS_BROKER_URL@|http://druid-broker:8082|g" \
        -e "s|@MEMACHED_HOSTNAME@|memcache|g" \
        -e "s|@MEMACHED_PORT@|11211|g" \
        -e "s|@MEMCACHED_HOSTNAME@|memcache|g" \
        -e "s|@MEMCACHED_PORT@|11211|g" \
        -e "s|@CONTACT_URL@|https://corp.kaltura.com/company/contact-us/|g" \
        -e "s|@INERNAL_BUNDLER_URL@|http://bundler:8080|g" \
        -e "s|@[A-Za-z_][A-Za-z0-9_]*@||g" \
        -e "/^[[:space:]]*=/s|^|;|" \
        "$TMPL" > "$DEST"
}

for TMPL in "$APP_DIR/configurations"/*.template.ini "$APP_DIR/configurations"/*.ini.template; do
    [ -f "$TMPL" ] || continue
    generate_ini_from_template "$TMPL"
done

# ── Re-fill the batch API secret after regenerating batchBase.ini ─────────────
# batchBase.template.ini carries `secret = @BATCH_PARTNER_ADMIN_SECRET@`, and the
# loop above runs on EVERY boot while the catch-all rule blanks any token it does
# not know. The secret was only filled inside the first-install branch, so every
# later restart of this container rewrote batchBase.ini with an empty secret and
# the batch worker lost its API credentials — `make restart` alone was enough to
# break transcoding, with nothing logged. Re-fill it from the database, which is
# the authoritative source. On a fresh install partner -1 does not exist yet;
# the install branch fills it then.
BATCHBASE_INI="$APP_DIR/configurations/batchBase.ini"
if [ -f "$BATCHBASE_INI" ] && grep -qE '^secret[[:space:]]*=[[:space:]]*$' "$BATCHBASE_INI"; then
    _bsecret=$(mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 -N \
        -e "SELECT admin_secret FROM partner WHERE id = -1" "$DB_NAME" 2>/dev/null)
    if [ -n "$_bsecret" ]; then
        sed -i "s|^secret\([[:space:]]*\)=[[:space:]]*$|secret\1= $_bsecret|" "$BATCHBASE_INI"
        echo "[kaltura] batchBase.ini: restored batch partner secret from the database"
    fi
fi

# ── broadcast.ini: unique per-entry stream names ───────────────────────────────
# LiveEntry::getStreamName() honors a {entryId} template from the broadcast map;
# without it every Kaltura-Live entry is named "%i" (shown as "1") and streams
# collide on the media server. nginx-rtmp also keys its HLS output by stream
# name, so per-entry uniqueness is required.
BROADCAST_INI="$APP_DIR/configurations/broadcast.ini"
if [ -f "$BROADCAST_INI" ] && ! grep -q "stream_name_template" "$BROADCAST_INI"; then
    sed -i '/^queryParams/a stream_name_template = {entryId}_%i' "$BROADCAST_INI"
    echo "[kaltura] broadcast.ini: stream_name_template = {entryId}_%i"
fi

# ── Route KMC NG queries away from ElasticSearch ───────────────────────────────
# ElasticSearchPlugin::canExecuteFilter consults `filterExecutionTags` in
# elasticDynamicMap.ini — if the client tag (e.g. "kmcng") is in that list,
# the plugin claims the filter and routes the API call to Elasticsearch.
# We don't ship Elasticsearch, so the call hits curl with an empty host and
# silently returns 0 results (KMC shows "No Results" even when entries exist).
# Removing kmcng from the tag list makes Kaltura fall through to the next
# executor (Sphinx), which we DO run. disableElastic=true alone is not enough
# because it only governs indexing, not search routing.
ELASTIC_INI="$APP_DIR/configurations/elastic.ini"
if [ -f "$ELASTIC_INI" ]; then
    sed -i 's|^disableElastic.*|disableElastic = true|' "$ELASTIC_INI"
fi
ELASTIC_MAP="$APP_DIR/configurations/elasticDynamicMap.ini"
if [ -f "$ELASTIC_MAP" ]; then
    sed -i '/= "kmcng"/d' "$ELASTIC_MAP"
fi

# ── Generate plugins.ini (registers which plugin classes to load) ──────────────
# Scanned from plugins/ directory every startup so newly added plugins get picked up.
echo "[kaltura] Generating plugins.ini..."
PLUGINS_INI="$APP_DIR/configurations/plugins.ini"
: > "$PLUGINS_INI"
while IFS= read -r f; do
    cls=$(basename "$f" .php)
    # Skip interfaces (IKalturaXPlugin) and abstract base classes
    grep -qE "^([[:space:]]*final[[:space:]]+)?class[[:space:]]+${cls}\b" "$f" || continue
    echo "${cls%Plugin}" >> "$PLUGINS_INI"
done < <(find "$APP_DIR/plugins" -type f -name "*Plugin.php")
sort -u -o "$PLUGINS_INI" "$PLUGINS_INI"
echo "[kaltura] Registered $(wc -l < "$PLUGINS_INI" | tr -d ' ') plugins."

# ── Skip if already fully initialized ─────────────────────────────────────────
# Install state is derived from the DATABASE, not from the marker file. The
# marker lives in the bind-mounted working tree, so it drifts from reality in
# both directions and each direction corrupts an install:
#   marker gone, DB populated  (git clean -xfd, fresh clone, different checkout
#     path) → the whole init re-runs over live data, re-inserting partners with
#     freshly generated secrets while the old rows survive.
#   marker present, DB empty  (docker volume rm mysql_data) → init is skipped
#     against an empty schema and everything fails at request time instead.
# partner -1 is created by insertDefaults.php, so its presence is the ground
# truth for "this database has been initialised". The marker is kept purely as
# a human-readable breadcrumb.
DB_INSTALLED=$(mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 -N \
    -e "SELECT COUNT(*) FROM partner WHERE id = -1" "$DB_NAME" 2>/dev/null || echo 0)
case "$DB_INSTALLED" in ''|*[!0-9]*) DB_INSTALLED=0 ;; esac

if [ "$DB_INSTALLED" -gt 0 ]; then
    if [ -f "$MARKER" ]; then
        echo "[kaltura] Already initialized ($(cat "$MARKER")). Skipping setup."
    else
        echo "[kaltura] Database already initialized (partner -1 present) but the marker file was missing — restoring it and skipping setup."
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) admin=$ADMIN_EMAIL (marker restored from DB state)" > "$MARKER"
    fi
else
    [ -f "$MARKER" ] && warn "marker file exists but the database has no partner -1 — treating this as a FRESH install (was the mysql volume removed?)"
    echo "[kaltura] Starting database initialization..."

    # ── Additional databases ───────────────────────────────────────────────────
    mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 <<SQL
CREATE DATABASE IF NOT EXISTS kalturadw           DEFAULT CHARACTER SET utf8;
CREATE DATABASE IF NOT EXISTS kalturadw_ds        DEFAULT CHARACTER SET utf8;
CREATE DATABASE IF NOT EXISTS kalturadw_bisources DEFAULT CHARACTER SET utf8;
CREATE DATABASE IF NOT EXISTS kalturalog          DEFAULT CHARACTER SET utf8;
GRANT INSERT,UPDATE,DELETE,SELECT,LOCK TABLES    ON kalturalog.*         TO '${DB_USER}'@'%';
GRANT INSERT,UPDATE,DELETE,SELECT,EXECUTE        ON kalturadw.*          TO '${DB_USER}'@'%';
GRANT INSERT,UPDATE,DELETE,SELECT,EXECUTE        ON kalturadw_ds.*       TO '${DB_USER}'@'%';
GRANT INSERT,UPDATE,DELETE,SELECT,EXECUTE        ON kalturadw_bisources.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

    # ── Schema SQL ─────────────────────────────────────────────────────────────
    echo "[kaltura] Loading schema..."
    mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 "$DB_NAME" \
        < "$APP_DIR/deployment/base/sql/01.kaltura_ce_tables.sql"
    mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 "$DB_NAME" \
        < "$APP_DIR/deployment/base/sql/04.stored_procedures.sql"
    mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 \
        < "$APP_DIR/deployment/base/sql/01.kaltura_sphinx_ce_tables.sql"
    mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 <<SQL
GRANT INSERT,UPDATE,DELETE,SELECT,ALTER,CREATE ON kaltura_sphinx_log.* TO '${DB_USER}'@'%';
GRANT INSERT,UPDATE,DELETE,SELECT,LOCK TABLES    ON kalturalog.*         TO '${DB_USER}'@'%';
GRANT INSERT,UPDATE,DELETE,SELECT,EXECUTE        ON kalturadw.*          TO '${DB_USER}'@'%';
GRANT INSERT,UPDATE,DELETE,SELECT,EXECUTE        ON kalturadw_ds.*       TO '${DB_USER}'@'%';
GRANT INSERT,UPDATE,DELETE,SELECT,EXECUTE        ON kalturadw_bisources.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
    echo "[kaltura] Schema loaded."

    # ── Generate random secrets ────────────────────────────────────────────────
    gen() { openssl rand -hex 20; }

    PARTNER_ZERO_ADMIN_SECRET=$(gen);   PARTNER_ZERO_SECRET=$(gen)
    BATCH_PARTNER_ADMIN_SECRET=$(gen);  BATCH_PARTNER_SECRET=$(gen)
    ADMIN_CONSOLE_PARTNER_ADMIN_SECRET=$(gen); ADMIN_CONSOLE_PARTNER_SECRET=$(gen)
    HOSTED_PAGES_PARTNER_ADMIN_SECRET=$(gen);  HOSTED_PAGES_PARTNER_SECRET=$(gen)
    MONITOR_PARTNER_ADMIN_SECRET=$(gen);       MONITOR_PARTNER_SECRET=$(gen)
    MEDIA_PARTNER_ADMIN_SECRET=$(gen);         MEDIA_PARTNER_SECRET=$(gen)
    PLAY_PARTNER_ADMIN_SECRET=$(gen);          PLAY_PARTNER_SECRET=$(gen)
    MONITORING_PROXY_ADMIN_SECRET=$(gen);      MONITORING_PROXY_SECRET=$(gen)
    KMC_SSO_SERVER_ADMIN_SECRET=$(gen);        KMC_SSO_SERVER_SECRET=$(gen)
    REACH_INTERNAL_PARTNER_ADMIN_SECRET=$(gen); REACH_INTERNAL_PARTNER_SECRET=$(gen)
    CNC_PARTNER_ADMIN_SECRET=$(gen);           CNC_PARTNER_SECRET=$(gen)
    SELF_SERVE_PARTNER_ADMIN_SECRET=$(gen);    SELF_SERVE_PARTNER_SECRET=$(gen)
    KME_PARTNER_ADMIN_SECRET=$(gen);           KME_PARTNER_SECRET=$(gen)
    CONNECTORS_FRAMEWORK_PARTNER_ADMIN_SECRET=$(gen); CONNECTORS_FRAMEWORK_PARTNER_SECRET=$(gen)
    BI_PARTNER_ADMIN_SECRET=$(gen);            BI_PARTNER_SECRET=$(gen)
    GAME_SERVICES_PARTNER_ADMIN_SECRET=$(gen); GAME_SERVICES_PARTNER_SECRET=$(gen)
    AUTH_BROKER_PARTNER_ADMIN_SECRET=$(gen);   AUTH_BROKER_PARTNER_SECRET=$(gen)
    USER_PROFILE_PARTNER_ADMIN_SECRET=$(gen);  USER_PROFILE_PARTNER_SECRET=$(gen)
    KMS_PARTNER_ADMIN_SECRET=$(gen);           KMS_PARTNER_SECRET=$(gen)
    MESSAGING_PARTNER_ADMIN_SECRET=$(gen);     MESSAGING_PARTNER_SECRET=$(gen)
    REPORTS_PARTNER_ADMIN_SECRET=$(gen);       REPORTS_PARTNER_SECRET=$(gen)
    PROVISIONER_PARTNER_ADMIN_SECRET=$(gen);   PROVISIONER_PARTNER_SECRET=$(gen)
    MEDIA_REPURPOSING_PARTNER_ADMIN_SECRET=$(gen); MEDIA_REPURPOSING_PARTNER_SECRET=$(gen)
    AI_PARTNER_ADMIN_SECRET=$(gen);            AI_PARTNER_SECRET=$(gen)
    AGENTS_MANAGER_PARTNER_ADMIN_SECRET=$(gen); AGENTS_MANAGER_PARTNER_SECRET=$(gen)
    IN_APP_MESSAGING_PARTNER_ADMIN_SECRET=$(gen); IN_APP_MESSAGING_PARTNER_SECRET=$(gen)
    VIDEO_AVATAR_PARTNER_ADMIN_SECRET=$(gen);  VIDEO_AVATAR_PARTNER_SECRET=$(gen)
    CONVERSATION_MANAGER_PARTNER_ADMIN_SECRET=$(gen); CONVERSATION_MANAGER_PARTNER_SECRET=$(gen)
    QUOTA_PARTNER_ADMIN_SECRET=$(gen);         QUOTA_PARTNER_SECRET=$(gen)
    TEMPLATE_PARTNER_ADMIN_SECRET=$(gen);      TEMPLATE_PARTNER_SECRET=$(gen)
    TEMPLATE_PARTNER_ADMIN_PASSWORD=$(gen)

    # ── Token replacement function ─────────────────────────────────────────────
    replace_tokens() {
        local FILE="$1"
        sed -i \
            -e "s#@PARTNER_ZERO_ADMIN_SECRET@#${PARTNER_ZERO_ADMIN_SECRET}#g" \
            -e "s#@PARTNER_ZERO_SECRET@#${PARTNER_ZERO_SECRET}#g" \
            -e "s#@BATCH_PARTNER_ADMIN_SECRET@#${BATCH_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@BATCH_PARTNER_SECRET@#${BATCH_PARTNER_SECRET}#g" \
            -e "s#@ADMIN_CONSOLE_PARTNER_ADMIN_SECRET@#${ADMIN_CONSOLE_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@ADMIN_CONSOLE_PARTNER_SECRET@#${ADMIN_CONSOLE_PARTNER_SECRET}#g" \
            -e "s#@HOSTED_PAGES_PARTNER_ADMIN_SECRET@#${HOSTED_PAGES_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@HOSTED_PAGES_PARTNER_SECRET@#${HOSTED_PAGES_PARTNER_SECRET}#g" \
            -e "s#@MONITOR_PARTNER_ADMIN_SECRET@#${MONITOR_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@MONITOR_PARTNER_SECRET@#${MONITOR_PARTNER_SECRET}#g" \
            -e "s#@MEDIA_PARTNER_ADMIN_SECRET@#${MEDIA_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@MEDIA_PARTNER_SECRET@#${MEDIA_PARTNER_SECRET}#g" \
            -e "s#@PLAY_PARTNER_ADMIN_SECRET@#${PLAY_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@PLAY_PARTNER_SECRET@#${PLAY_PARTNER_SECRET}#g" \
            -e "s#@MONITORING_PROXY_ADMIN_SECRET@#${MONITORING_PROXY_ADMIN_SECRET}#g" \
            -e "s#@MONITORING_PROXY_SECRET@#${MONITORING_PROXY_SECRET}#g" \
            -e "s#@KMC_SSO_SERVER_ADMIN_SECRET@#${KMC_SSO_SERVER_ADMIN_SECRET}#g" \
            -e "s#@KMC_SSO_SERVER_SECRET@#${KMC_SSO_SERVER_SECRET}#g" \
            -e "s#@REACH_INTERNAL_PARTNER_ADMIN_SECRET@#${REACH_INTERNAL_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@REACH_INTERNAL_PARTNER_SECRET@#${REACH_INTERNAL_PARTNER_SECRET}#g" \
            -e "s#@CNC_PARTNER_ADMIN_SECRET@#${CNC_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@CNC_PARTNER_SECRET@#${CNC_PARTNER_SECRET}#g" \
            -e "s#@SELF_SERVE_PARTNER_ADMIN_SECRET@#${SELF_SERVE_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@SELF_SERVE_PARTNER_SECRET@#${SELF_SERVE_PARTNER_SECRET}#g" \
            -e "s#@KME_PARTNER_ADMIN_SECRET@#${KME_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@KME_PARTNER_SECRET@#${KME_PARTNER_SECRET}#g" \
            -e "s#@CONNECTORS_FRAMEWORK_PARTNER_ADMIN_SECRET@#${CONNECTORS_FRAMEWORK_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@CONNECTORS_FRAMEWORK_PARTNER_SECRET@#${CONNECTORS_FRAMEWORK_PARTNER_SECRET}#g" \
            -e "s#@BI_PARTNER_ADMIN_SECRET@#${BI_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@BI_PARTNER_SECRET@#${BI_PARTNER_SECRET}#g" \
            -e "s#@GAME_SERVICES_PARTNER_ADMIN_SECRET@#${GAME_SERVICES_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@GAME_SERVICES_PARTNER_SECRET@#${GAME_SERVICES_PARTNER_SECRET}#g" \
            -e "s#@AUTH_BROKER_PARTNER_ADMIN_SECRET@#${AUTH_BROKER_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@AUTH_BROKER_PARTNER_SECRET@#${AUTH_BROKER_PARTNER_SECRET}#g" \
            -e "s#@USER_PROFILE_PARTNER_ADMIN_SECRET@#${USER_PROFILE_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@USER_PROFILE_PARTNER_SECRET@#${USER_PROFILE_PARTNER_SECRET}#g" \
            -e "s#@KMS_PARTNER_ADMIN_SECRET@#${KMS_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@KMS_PARTNER_SECRET@#${KMS_PARTNER_SECRET}#g" \
            -e "s#@MESSAGING_PARTNER_ADMIN_SECRET@#${MESSAGING_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@MESSAGING_PARTNER_SECRET@#${MESSAGING_PARTNER_SECRET}#g" \
            -e "s#@REPORTS_PARTNER_ADMIN_SECRET@#${REPORTS_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@REPORTS_PARTNER_SECRET@#${REPORTS_PARTNER_SECRET}#g" \
            -e "s#@PROVISIONER_PARTNER_ADMIN_SECRET@#${PROVISIONER_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@PROVISIONER_PARTNER_SECRET@#${PROVISIONER_PARTNER_SECRET}#g" \
            -e "s#@MEDIA_REPURPOSING_PARTNER_ADMIN_SECRET@#${MEDIA_REPURPOSING_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@MEDIA_REPURPOSING_PARTNER_SECRET@#${MEDIA_REPURPOSING_PARTNER_SECRET}#g" \
            -e "s#@AI_PARTNER_ADMIN_SECRET@#${AI_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@AI_PARTNER_SECRET@#${AI_PARTNER_SECRET}#g" \
            -e "s#@AGENTS_MANAGER_PARTNER_ADMIN_SECRET@#${AGENTS_MANAGER_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@AGENTS_MANAGER_PARTNER_SECRET@#${AGENTS_MANAGER_PARTNER_SECRET}#g" \
            -e "s#@IN_APP_MESSAGING_PARTNER_ADMIN_SECRET@#${IN_APP_MESSAGING_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@IN_APP_MESSAGING_PARTNER_SECRET@#${IN_APP_MESSAGING_PARTNER_SECRET}#g" \
            -e "s#@VIDEO_AVATAR_PARTNER_ADMIN_SECRET@#${VIDEO_AVATAR_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@VIDEO_AVATAR_PARTNER_SECRET@#${VIDEO_AVATAR_PARTNER_SECRET}#g" \
            -e "s#@CONVERSATION_MANAGER_PARTNER_ADMIN_SECRET@#${CONVERSATION_MANAGER_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@CONVERSATION_MANAGER_PARTNER_SECRET@#${CONVERSATION_MANAGER_PARTNER_SECRET}#g" \
            -e "s#@QUOTA_PARTNER_ADMIN_SECRET@#${QUOTA_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@QUOTA_PARTNER_SECRET@#${QUOTA_PARTNER_SECRET}#g" \
            -e "s#@TEMPLATE_PARTNER_ADMIN_SECRET@#${TEMPLATE_PARTNER_ADMIN_SECRET}#g" \
            -e "s#@TEMPLATE_PARTNER_SECRET@#${TEMPLATE_PARTNER_SECRET}#g" \
            -e "s#@TEMPLATE_PARTNER_ADMIN_PASSWORD@#${TEMPLATE_PARTNER_ADMIN_PASSWORD}#g" \
            -e "s#@ADMIN_CONSOLE_ADMIN_MAIL@#${ADMIN_EMAIL}#g" \
            -e "s#@ADMIN_CONSOLE_PASSWORD@#${ADMIN_PASS}#g" \
            -e "s#@WWW_HOST@#${WWW_HOST}#g" \
            -e "s#@SERVICE_URL@#${SERVICE_URL}#g" \
            -e "s#@WEB_DIR@#${WEB_DIR}#g" \
            -e "s#@STORAGE_BASE_DIR@#${WEB_DIR}#g" \
            -e "s#@VOD_PACKAGER_URL@#${WWW_HOST}#g" \
            -e "s#@LIVE_PACKAGER_URL@#${WWW_HOST}#g" \
            "$FILE"
    }

    # ── Process init_data templates ────────────────────────────────────────────
    INIT_DATA="$APP_DIR/deployment/base/scripts/init_data"
    echo "[kaltura] Processing init_data templates..."
    for TMPL in "$INIT_DATA"/*.template.ini; do
        DEST="${TMPL/.template.ini/.ini}"
        cp "$TMPL" "$DEST"
        replace_tokens "$DEST"
    done

    # ── Process init_content templates ────────────────────────────────────────
    INIT_CONTENT="$APP_DIR/deployment/base/scripts/init_content"
    echo "[kaltura] Processing init_content templates..."
    for TMPL in "$INIT_CONTENT"/*.template.xml; do
        DEST="${TMPL/.template.xml/.xml}"
        cp "$TMPL" "$DEST"
        replace_tokens "$DEST"
    done

    # ── Run PHP deployment scripts ─────────────────────────────────────────────
    cd "$APP_DIR/deployment/base/scripts"

    echo "[kaltura] Running installPlugins.php..."
    php installPlugins.php >> "$LOG_DIR/installPlugins.log" 2>&1

    echo "[kaltura] Running insertDefaults.php..."
    php insertDefaults.php "$INIT_DATA" >> "$LOG_DIR/insertDefaults.log" 2>&1

    echo "[kaltura] Running insertPermissions.php..."
    php insertPermissions.php >> "$LOG_DIR/insertPermissions.log" 2>&1

    # Apache needs to be up for both client SDK generation (API self-call) and
    # insertContent.php (also calls API). Generate clients FIRST because
    # insertContent.php uses tests/standAloneClient/exec.php → tests/lib/KalturaClient.php
    # which is one of the generated files.
    echo "[kaltura] Starting Apache temporarily for content init..."
    apache2ctl start
    sleep 5

    # ── Generate Kaltura PHP client SDKs ───────────────────────────────────────
    # batch/client/*, tests/lib/*, admin_console/lib/Kaltura/Client/*, var_console/...
    # are auto-generated from the live API schema. Required for insertContent
    # (standAloneClient uses tests/lib/KalturaClient.php) and batch workers.
    #
    # We call generate_xml.php WITH an explicit output path arg to bypass its
    # default behavior of looking up myContentStorage::getFSContentRootPath()
    # which requires Propel/DbManager initialization that this script lacks.
    # Then clients-generator/exec.php reads the XML and produces all clients.
    echo "[kaltura] Generating Kaltura PHP client SDKs (XML schema)..."
    mkdir -p "$WEB_DIR/content/clientlibs"
    php "$APP_DIR/api_v3/generator/generate_xml.php" "$WEB_DIR/content/clientlibs" \
        >> "$LOG_DIR/generate.log" 2>&1 \
        || echo "[kaltura] WARN: generate_xml.php had errors (check $LOG_DIR/generate.log)"

    echo "[kaltura] Generating Kaltura PHP client SDKs (php clients)..."
    cd /opt/kaltura/clients-generator
    php exec.php >> "$LOG_DIR/generate.log" 2>&1 \
        || echo "[kaltura] WARN: clients-generator/exec.php had errors (check $LOG_DIR/generate.log)"
    cd "$APP_DIR/deployment/base/scripts"

    echo "[kaltura] Running insertContent.php..."
    php insertContent.php >> "$LOG_DIR/insertContent.log" 2>&1 \
        || echo "[kaltura] WARN: insertContent.php had non-fatal errors (check $LOG_DIR/insertContent.log)"

    # html5studio confFile fix runs in the always-on section below (handles new partners too).

    # ── Deploy UI confs via official deploy_v2.php for KMC / KMCng / studio ────
    # The official installer's kaltura-db-config.sh runs deploy_v2.php for each
    # UI app's config.ini to seed dozens of ui_conf rows that KMC's Studio,
    # Players, etc. tabs need. We previously hardcoded only two INSERTs;
    # this picks up the full set.
    DEPLOY_V2="$APP_DIR/deployment/uiconf/deploy_v2.php"
    if [ -f "$DEPLOY_V2" ]; then
        for UICONF_INI in \
            "$APP_DIR/apps/kmcng/latest/deploy/config.ini" \
            "$APP_DIR/apps/kmcng/v7.20.0/deploy/config.ini" \
            "$APP_DIR/apps/studio/latest/studio.ini" \
            "$APP_DIR/apps/liveanalytics/latest/deploy/config.ini" \
            "$WEB_DIR/flash/kmc/latest/config.ini"; do
            [ -f "$UICONF_INI" ] || continue
            echo "[kaltura] Deploying UI confs from $UICONF_INI..."
            php "$DEPLOY_V2" --ini="$UICONF_INI" >> "$LOG_DIR/uiconf_deploy.log" 2>&1 \
                || echo "[kaltura] WARN: deploy_v2.php for $UICONF_INI had errors (check $LOG_DIR/uiconf_deploy.log)"
        done
    fi

    apache2ctl stop 2>/dev/null || true
    sleep 2

    # ── Create KMC NG preview player uiConf records ────────────────────────────
    # kmcngAction.php calls uiConfPeer::getUiconfByTagAndVersion('KMCngV2', version)
    # and getUiconfByTagAndVersion('KMCngV7', version) — both need partner_id=0.
    # deploy_v2.php above creates many uiConfs but not specifically the KMCngV2/V7
    # records the kmcngAction PHP file looks up at runtime by tag.
    echo "[kaltura] Creating KMC NG preview player uiConf records..."
    KMCNG_VER=$(awk -F'=' '/^\[kmcng\]/{f=1} f && /^kmcng_version/{gsub(/ /,"",$2); print $2; exit}' \
        "$APP_DIR/configurations/base.ini" 2>/dev/null)
    KMCNG_VER="${KMCNG_VER:-v7.20.0}"
    # Resolve actual player version from the bundler service so conf_vars has a real semver
    # (version_compare('{latest}', '1.9.0') returns -1, forcing the old UIConf format which
    # the v3.x pre-built player cannot read — real version number fixes the format selection)
    PLAYER_VER=$(curl -sf http://bundler:8080/version 2>/dev/null || echo "3.17.82")
    mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 kaltura <<SQL
INSERT INTO ui_conf (obj_type, partner_id, subp_id, name, width, height, swf_url, tags, status, creation_mode, created_at, updated_at)
SELECT 8, 0, 0, 'KMCng Player', '560', '395', '/flash/kdp3/v3.9.9/kdp3.swf',
       CONCAT('preview,html5studio,player,KMCngV2,', '${KMCNG_VER}'), 2, 2, NOW(), NOW()
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM ui_conf WHERE partner_id=0 AND tags LIKE '%KMCngV2%' AND tags LIKE '%${KMCNG_VER}%');

INSERT INTO ui_conf (obj_type, partner_id, subp_id, name, width, height, swf_url, conf_vars, tags, status, creation_mode, created_at, updated_at)
SELECT 1, 0, 0, 'KMCng Player V7', '528', '327', '/',
       '{"kaltura-ovp-player":"${PLAYER_VER}","playkit-youtube":"${PLAYER_VER}","playkit-ivq":"${PLAYER_VER}","playkit-kaltura-cuepoints":"${PLAYER_VER}","playkit-kaltura-live":"${PLAYER_VER}"}',
       CONCAT('kalturaPlayerJs,player,ovp,KMCngV7,', '${KMCNG_VER}'), 2, 2, NOW(), NOW()
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM ui_conf WHERE partner_id=0 AND tags LIKE '%KMCngV7%' AND tags LIKE '%${KMCNG_VER}%');
SQL
    echo "[kaltura] KMC NG uiConf records created (version: ${KMCNG_VER})."

    # ── Finalize batch.ini with values that depend on DB state ─────────────────
    # The official kaltura-batch-config.sh reads partner -1's admin_secret from
    # the DB (populated by insertDefaults.php) and substitutes it into batch.ini,
    # along with the typo'd @INSTALLED_HOSNAME@ and a random @BATCH_SCHEDULER_ID@.
    # Without this, batch workers cannot authenticate to the API.
    BATCH_PARTNER_ADMIN_SECRET=$(mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 \
        -N -e "SELECT admin_secret FROM partner WHERE id=-1;" kaltura 2>/dev/null)
    BATCH_SCHEDULER_ID=$(LC_ALL=C tr -dc 0-9 < /dev/urandom | head -c 5)
    BATCH_INI="$APP_DIR/configurations/batch/batch.ini"
    if [ -n "$BATCH_PARTNER_ADMIN_SECRET" ] && [ -f "$BATCH_INI" ]; then
        echo "[kaltura] Finalizing batch.ini with batch partner secret..."
        sed -i \
            -e "s|@BATCH_PARTNER_ADMIN_SECRET@|$BATCH_PARTNER_ADMIN_SECRET|g" \
            -e "s|@INSTALLED_HOSNAME@|$(hostname)|g" \
            -e "s|@INSTALLED_HOSTNAME@|$(hostname)|g" \
            -e "s|@BATCH_SCHEDULER_ID@|$BATCH_SCHEDULER_ID|g" \
            "$BATCH_INI"
    fi
    BATCHBASE_INI="$APP_DIR/configurations/batchBase.ini"
    if [ -n "$BATCH_PARTNER_ADMIN_SECRET" ] && [ -f "$BATCHBASE_INI" ]; then
        sed -i "s|@BATCH_PARTNER_ADMIN_SECRET@|$BATCH_PARTNER_ADMIN_SECRET|g" "$BATCHBASE_INI"
    fi

    # Mark as initialized
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) admin=$ADMIN_EMAIL" > "$MARKER"
    echo "[kaltura] Initialization complete."
    # Printed ONCE, at install time only — docker logs are routinely collected
    # and retained, so the password must not be re-emitted on every restart.
    echo "[kaltura] Admin Console login: $ADMIN_EMAIL (password: as set in docker/kaltura.conf)"
fi

# ── Create /opt/kaltura/var/run for batch pidfile (batchBase.ini pidFileDir) ──
mkdir -p /opt/kaltura/var/run
chown -R www-data:www-data /opt/kaltura/var 2>/dev/null || true

# ── Always run installPlugins (idempotent, registers plugin enums in dynamic_enum)
echo "[kaltura] Syncing plugin enums..."
cd "$APP_DIR/deployment/base/scripts"
php installPlugins.php >> "$LOG_DIR/installPlugins.log" 2>&1

# Re-assert ownership on everything the root-run steps above touched.
# installPlugins.php (and the init scripts before it) run as ROOT and write
# into directories shared with the batch/scheduler containers, which run PHP as
# www-data. The chown near the top of this script happens BEFORE those runs, so
# without this second pass the following stay root-owned:
#   cache/scripts/classMap.cache  — written 0600, so www-data cannot read it at
#     all: every cron job and batch worker logs "Class map could not be loaded"
#     and rebuilds the autoloader map from scratch on every single invocation.
#   cache/*.cache, cache/deploy, cache/generator, $LOG_DIR/*.log
# classMap.cache also needs an explicit chmod: chown alone leaves it 0600.
chown -R www-data:www-data "$WEB_DIR/content" "$WEB_DIR/cache" "$WEB_DIR/tmp" \
    "$LOG_DIR" "$APP_DIR/cache" 2>/dev/null || true
chmod 644 "$APP_DIR/cache/scripts/classMap.cache" 2>/dev/null || true

# ── html5lib (V2 mwEmbed player) ──────────────────────────────────────────────
# Copy from image path into the web volume once, then patch for PHP 8.1 compat.
HTML5LIB_IMAGE="/opt/kaltura/html5lib_image"
HTML5LIB_WEB="$WEB_DIR/html5/html5lib"
if [ -d "$HTML5LIB_IMAGE" ]; then
    for IMG_VER_DIR in "$HTML5LIB_IMAGE"/*/; do
        VER=$(basename "$IMG_VER_DIR")
        DEST="$HTML5LIB_WEB/$VER"
        if [ ! -d "$DEST" ]; then
            echo "[kaltura] Installing html5lib $VER into web volume..."
            mkdir -p "$HTML5LIB_WEB"
            cp -a "$IMG_VER_DIR" "$DEST"
            chown -R www-data:www-data "$DEST"
        fi
    done
fi

# LocalSettings.php, PHP 8.1 patches, conf files — run for every installed version
[ ! -e "$WEB_DIR/app" ] && ln -sf "$APP_DIR" "$WEB_DIR/app"
if [ -d "$HTML5LIB_WEB" ]; then
    for VER_DIR in "$HTML5LIB_WEB"/*/; do
        [ -d "$VER_DIR" ] || continue

        # LocalSettings.php — required by mwEmbedFrame bootstrap
        if [ ! -f "$VER_DIR/LocalSettings.php" ] && [ -f "$VER_DIR/LocalSettings.KalturaPlatform.php" ]; then
            echo "[kaltura] Creating LocalSettings.php for $(basename $VER_DIR)..."
            printf '<?php require_once(dirname(__FILE__).'\''/LocalSettings.KalturaPlatform.php'\'');\n' \
                > "$VER_DIR/LocalSettings.php"
        fi

        # PHP 8.0+ rejects function __autoload() at compile time even in dead code
        AUTOLOADER="$VER_DIR/includes/MwEmbedAutoLoader.php"
        if [ -f "$AUTOLOADER" ] && grep -q 'function __autoload(' "$AUTOLOADER" 2>/dev/null; then
            echo "[kaltura] Patching MwEmbedAutoLoader.php PHP 8.1 compat ($(basename $VER_DIR))..."
            sed -i 's/function __autoload(/function mwembed_php8_compat_autoload(/' "$AUTOLOADER"
        fi

        # PHP 8.0+ removed unparenthesized chained ternary — line 462 of EntryResult.php
        ENTRY_RESULT="$VER_DIR/modules/KalturaSupport/EntryResult.php"
        if [ -f "$ENTRY_RESULT" ] \
            && sed -n '462p' "$ENTRY_RESULT" | grep -q 'isset' \
            && ! sed -n '462p' "$ENTRY_RESULT" | grep -q '(isset'; then
            echo "[kaltura] Patching EntryResult.php PHP 8.0 ternary compat ($(basename $VER_DIR))..."
            sed -i '462{s/isset/(isset/; s/null;\r\{0,1\}/null);/}' "$ENTRY_RESULT"
        fi

        # PHP 8.1: json_decode() throws TypeError when passed a non-string (e.g. already-decoded
        # stdClass). In PHP 7.x it silently returned null. Guard with is_string() check.
        KALTURA_UTILS="$VER_DIR/modules/KalturaSupport/KalturaUtils.php"
        if [ -f "$KALTURA_UTILS" ] \
            && grep -q '@json_decode( \$str ) !== null' "$KALTURA_UTILS" 2>/dev/null \
            && ! grep -q 'is_string(\$str) &&' "$KALTURA_UTILS" 2>/dev/null; then
            echo "[kaltura] Patching KalturaUtils.php PHP 8.1 json_decode compat ($(basename $VER_DIR))..."
            sed -i 's/else if( @json_decode( \$str ) !== null/else if( is_string($str) \&\& @json_decode( $str ) !== null/' "$KALTURA_UTILS"
        fi
    done
fi


# ── Fix delivery_profile URLs: remove stale :88 port (route through Apache) ───
mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 kaltura <<SQL 2>/dev/null
UPDATE delivery_profile SET url = REPLACE(url, ':88/', '/') WHERE url LIKE '%:88/%';
SQL

# ── LIVE_HLS delivery profile: manual live entries' isLive probe ──────────────
# Broadcasting Now / the KMC Live badge probe a manual entry's HLS URL through
# a LIVE_HLS (1001) delivery profile matched by host name. Seed one for our
# host (the API's hostName property is read-only, hence the direct row).
mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 kaltura <<SQL 2>/dev/null
INSERT INTO delivery_profile (partner_id, name, system_name, type, streamer_type, url, host_name, status, created_at, updated_at)
SELECT 0, 'nginx-rtmp manual live HLS (isLive probe)', 'nginxRtmpLiveHls', 1001, 'applehttp',
       '${SERVICE_PROTOCOL}://${WWW_HOST}/hlsme', '${WWW_HOST}', 0, NOW(), NOW()
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM delivery_profile WHERE type = 1001 AND host_name = '${WWW_HOST}');
SQL

# ── Widgets: every positive partner needs a _<id> widget for widget sessions ───
mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 kaltura <<SQL 2>/dev/null
INSERT IGNORE INTO widget (id, partner_id, subp_id, created_at, updated_at)
SELECT CONCAT('_', id), id, id * 100, NOW(), NOW()
FROM partner
WHERE id > 0
  AND CONCAT('_', id) NOT IN (SELECT id FROM widget);
SQL

# ── KAVA/Druid enabled: druid_url points at the druid broker (set via template) ──
# shouldUseKava() requires druid_url set → numeric report types with KAVA defs
# (e.g. reportType 34 USER_ENGAGEMENT_TIMELINE) route to Druid native /druid/v2/.
# Legacy report types without a KAVA def still fall back to the DWH below.
# Ensure druid_url is NOT commented out (clean up any stale comment from prior runs).
LOCAL_INI="$APP_DIR/configurations/local.ini"
if [ -f "$LOCAL_INI" ]; then
    sed -i 's|^;\(druid_url\s*=.*\)|\1|' "$LOCAL_INI"
    sed -i 's|^;\(external_calls_druid_url\s*=.*\)|\1|' "$LOCAL_INI"
fi

# ── Load DWH schema into kalturadw (idempotent: skips if tables already exist) ──
# Mirrors what kaltura-dwh-config.sh does on bare metal:
# 1. Patch old partition boundary dates (2013-2015) → current dates to avoid MySQL errors
# 2. Run DDL files in correct order across the four DWH databases
# 3. Populate time dimension and seed data
set +e
DWH_DDL="/opt/kaltura/dwh_ddl"
DWH_TABLE_COUNT=$(mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 \
    -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='kalturadw'" 2>/dev/null)
# NOTE: the DWH schema has no ETL feeding it in this stack (analytics is
# Druid-only) — legacy DWH-SQL reports (Admin Console partner usage etc.)
# query these tables and return empty. Loading the schema keeps them failing
# soft (empty result) instead of hard (SQL error). Set LOAD_DWH=false to skip
# the load entirely and save several minutes of first-boot time.
if [ "${LOAD_DWH:-true}" = "true" ] && [ "${DWH_TABLE_COUNT:-0}" -eq 0 ] && [ -d "$DWH_DDL/ddl" ]; then
    echo "[kaltura] Applying DWH partition date fixup..."
    # Bare metal installer replaces these hardcoded 2013-2015 partition boundary dates
    # with current dates. Without this, MySQL fails creating partitioned tables.
    LDAYLM=$(date -d "$(date +%Y-%m-01) -1 day" +%Y%m%d 2>/dev/null || date -v-1m -v+1d +%Y%m%d 2>/dev/null || echo $(date +%Y%m%d))
    FDAYCM=$(date +%Y%m01)
    LASTMO=$(date +%Y%m)
    FDAYNM=$(date -d "$(date +%Y-%m-01) +1 month" +%Y%m%d 2>/dev/null || date -v+1m -v1d +%Y%m%d 2>/dev/null || echo $(date +%Y%m%d))
    NEXMO=$(date -d "$(date +%Y-%m-01) +1 month" +%Y%m 2>/dev/null || date -v+1m +%Y%m 2>/dev/null || echo $(date +%Y%m))
    # Replace old 2013-2015 dates in all DDL files
    find "$DWH_DDL/ddl" -name "*.sql" -exec sed -i \
        -e "s/20130831/$LDAYLM/g" \
        -e "s/201308/$LASTMO/g" \
        -e "s/20130901/$FDAYCM/g" \
        -e "s/20131001/$FDAYNM/g" \
        -e "s/201309/$LASTMO/g" \
        -e "s/20131231/$LDAYLM/g" \
        -e "s/201312/$LASTMO/g" \
        -e "s/20140101/$FDAYCM/g" \
        -e "s/201401/$NEXMO/g" \
        -e "s/20150801/$LDAYLM/g" \
        -e "s/201508/$LASTMO/g" \
        -e "s/20150901/$FDAYCM/g" \
        -e "s/201509/$NEXMO/g" \
        -e "s/20151001/$FDAYNM/g" \
        -e "s/201510/$NEXMO/g" \
        -e "s/20151101/$FDAYNM/g" \
        {} \;
    # MySQL 5.7: PRIMARY KEY columns cannot be DEFAULT NULL (ERROR 1171)
    # DWH DDL was written for MySQL 5.5 which allowed this silently.
    # Fix: change DEFAULT NULL → NOT NULL DEFAULT 0/'' for aggr and facts tables.
    find "$DWH_DDL/ddl/dw/aggr" "$DWH_DDL/ddl/dw/facts" "$DWH_DDL/ddl/dw/dimensions" \
        -name "*.sql" -exec sed -i \
        -e 's/\bINT\b DEFAULT NULL/INT NOT NULL DEFAULT 0/g' \
        -e 's/INT(11) DEFAULT NULL/INT(11) NOT NULL DEFAULT 0/g' \
        -e 's/INT(6) DEFAULT NULL/INT(6) NOT NULL DEFAULT 0/g' \
        -e 's/VARCHAR(20) DEFAULT NULL/VARCHAR(20) NOT NULL DEFAULT '"'"''"'"'/g' \
        -e 's/VARCHAR(50) DEFAULT NULL/VARCHAR(50) NOT NULL DEFAULT '"'"''"'"'/g' \
        {} \;
    echo "[kaltura] Loading DWH schema into kalturadw..."
    # MySQL errors go to this log (NOT /dev/null) so a partial load is diagnosable.
    # --force keeps loading past per-statement errors; every error is captured here
    # with its file context, and the table counts are verified afterwards.
    DWH_LOG="$LOG_DIR/dwh_load.log"
    : > "$DWH_LOG"
    _mysql_run() {
        local db="$1"; local f="$2"
        [ -f "$f" ] || return 0
        echo "=== $db < $f ===" >> "$DWH_LOG"
        mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" \
            --ssl=0 --force "$db" < "$f" 2>> "$DWH_LOG"; return 0
    }
    _mysql_batch() {
        # Batch all plain files (no DELIMITER) in one connection; run DELIMITER files individually
        local db="$1"; shift
        local plain="" delim_files=""
        for f in "$@"; do
            [ -f "$f" ] || continue
            if grep -q "DELIMITER" "$f" 2>/dev/null; then
                delim_files="$delim_files $f"
            else
                plain="$plain $f"
            fi
        done
        echo "=== $db < (batch: $(echo $plain | wc -w) plain files) ===" >> "$DWH_LOG"
        # shellcheck disable=SC2086
        [ -n "$plain" ] && cat $plain 2>/dev/null | mysql -h"$DB_HOST" -P"$DB_PORT" \
            -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 --force "$db" 2>> "$DWH_LOG"; true
        for f in $delim_files; do _mysql_run "$db" "$f"; done
    }
    _mysql_batch kalturadw_bisources "$DWH_DDL/ddl/bi_sources/"*.sql
    _mysql_batch kalturadw_ds        "$DWH_DDL/ddl/ds/"*.sql
    _mysql_batch kalturalog          "$DWH_DDL/ddl/log/"*.sql
    _mysql_batch kalturadw \
        "$DWH_DDL/ddl/dw/"*.sql \
        "$DWH_DDL/ddl/dw/facts/"*.sql \
        "$DWH_DDL/ddl/dw/dimensions/"*.sql \
        "$DWH_DDL/ddl/dw/maintenance/"*.sql \
        "$DWH_DDL/ddl/dw/aggr/"*.sql \
        "$DWH_DDL/ddl/dw/functions/"*.sql \
        "$DWH_DDL/ddl/dw/ri/"*.sql \
        "$DWH_DDL/ddl/dw/views/"*.sql \
        "$DWH_DDL/ddl/dw/fms/"*.sql \
        "$DWH_DDL/ddl/setup/populate_time_dim.sql" \
        "$DWH_DDL/ddl/setup/populate_dwh_dim_ip_ranges.sql"
    mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 2>> "$DWH_LOG" <<SQL
CREATE USER IF NOT EXISTS 'etl'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON kalturadw.*           TO 'etl'@'%';
GRANT ALL PRIVILEGES ON kalturadw_ds.*        TO 'etl'@'%';
GRANT ALL PRIVILEGES ON kalturadw_bisources.* TO 'etl'@'%';
GRANT SELECT, INSERT, UPDATE ON kalturalog.*  TO 'etl'@'%';
GRANT SELECT ON ${DB_NAME}.*                  TO 'etl'@'%';
FLUSH PRIVILEGES;
SQL
    # ── Verify what actually landed (a silent partial load is the #1 DWH pitfall) ──
    _dwh_count() {
        mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 -N \
            -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$1'" 2>/dev/null
    }
    DWH_MAIN_TABLES=$(_dwh_count kalturadw)
    echo "[kaltura] DWH tables: kalturadw=${DWH_MAIN_TABLES:-0} ds=$(_dwh_count kalturadw_ds) bisources=$(_dwh_count kalturadw_bisources) log=$(_dwh_count kalturalog)"
    # kalturadw should hold ~140 tables; far fewer means the DDL failed mid-load.
    if [ "${DWH_MAIN_TABLES:-0}" -lt 100 ]; then
        echo "[kaltura] WARN: kalturadw has only ${DWH_MAIN_TABLES:-0} tables (expected ~140) — DWH load incomplete. See $DWH_LOG"
        grep -iE "ERROR [0-9]+" "$DWH_LOG" 2>/dev/null | sort -u | head -5 | sed 's/^/[kaltura]   /'
    else
        echo "[kaltura] DWH schema loaded (${DWH_MAIN_TABLES} tables in kalturadw)."
    fi
fi
set -e

# ── appVersions.ini: set html5_version so embedIframeJs can serve kWidget JS ──
# embedIframeJsAction reads html5_version; if empty it exits with "version not found"
APPVERSIONS="$APP_DIR/configurations/appVersions.ini"
if [ -f "$APPVERSIONS" ] && grep -qE '^html5_version\s*=\s*$' "$APPVERSIONS" 2>/dev/null; then
    sed -i "s|^html5_version = *$|html5_version = ${HTML5LIB_VERSION}|" "$APPVERSIONS"
    echo "[kaltura] Set html5_version = ${HTML5LIB_VERSION} in appVersions.ini"
fi
if [ -f "$APPVERSIONS" ] && grep -qE '^studio_version\s*=\s*$' "$APPVERSIONS" 2>/dev/null; then
    sed -i "s|^studio_version = *$|studio_version = ${STUDIO_VERSION}|" "$APPVERSIONS"
    echo "[kaltura] Set studio_version = ${STUDIO_VERSION} in appVersions.ini"
fi
if [ -f "$APPVERSIONS" ] && grep -qE '^studio_v3_version\s*=\s*$' "$APPVERSIONS" 2>/dev/null; then
    sed -i "s|^studio_v3_version = *$|studio_v3_version = ${STUDIO_V3_VERSION:-v3.18.0}|" "$APPVERSIONS"
    echo "[kaltura] Set studio_v3_version = ${STUDIO_V3_VERSION:-v3.18.0} in appVersions.ini"
fi
LOCAL_INI="$APP_DIR/configurations/local.ini"
if [ -f "$LOCAL_INI" ] && ! grep -q "^kmc_analytics_version" "$LOCAL_INI" 2>/dev/null; then
    FIRST_SECTION=$(grep -n "^\[" "$LOCAL_INI" | head -1 | cut -d: -f1)
    if [ -n "$FIRST_SECTION" ]; then
        sed -i "${FIRST_SECTION}i kmc_analytics_version = ${ANALYTICS_VERSION:-v3.4.2}" "$LOCAL_INI"
    else
        echo "kmc_analytics_version = ${ANALYTICS_VERSION:-v3.4.2}" >> "$LOCAL_INI"
    fi
    echo "[kaltura] Set kmc_analytics_version = ${ANALYTICS_VERSION:-v3.4.2} in local.ini"
fi

# ── Studio v2 spinner fixes ────────────────────────────────────────────────────
# Two-pronged fix for the loading spinner that never disappears after the
# players list is shown:
#
# Fix A (index.html watchdog): intercepts KMCModule's run() phase to wrap
#   requestStarted with a 6-second watchdog timer. If the spinner is still
#   blocking after 6s (customStart still set), the timer force-broadcasts
#   _END_REQUEST_ to hide it. Safe: fires only when something went wrong.
#
# Fix B (main.min.js, simple sed): wraps cachePlayers() in a try/finally so
#   requestEnded('list') always fires even if cachePlayers() throws.
STUDIO_DIR="/opt/kaltura/apps/studio/${STUDIO_VERSION}"
STUDIO_INDEX="$STUDIO_DIR/index.html"
STUDIO_MIN="$STUDIO_DIR/main.min.js"
STUDIO_INI="$STUDIO_DIR/studio.ini"

# Fix A: append spinner watchdog run-block to main.min.js
# angular.module('KMCModule') (no deps array) retrieves the existing module
# and adds a run() block. The block wraps requestStarted with a 6-second
# watchdog: if customStart is still set after 6s, forcibly broadcasts
# _END_REQUEST_ to hide the stuck spinner. Idempotent via marker comment.
WATCHDOG_MARKER='/* spinner-watchdog-v1 */'
# Fix B: wrap cachePlayers() in IIFE try/finally so requestEnded('list') always fires
# even if cachePlayers() throws (e.g. conf_file wrong format). Must use an IIFE
# because the original is a comma-operator expression — 'try' as a bare statement
# causes SyntaxError in that context.
if [ -f "$STUDIO_MIN" ] && grep -q 'f\.cachePlayers(e\.objects),p\.requestEnded("list")' "$STUDIO_MIN" 2>/dev/null; then
    sed -i 's|f\.cachePlayers(e\.objects),p\.requestEnded("list")|(function(){try{f.cachePlayers(e.objects)}finally{p.requestEnded("list")}})()|g' "$STUDIO_MIN" \
        && echo "[kaltura] Studio main.min.js: patched cachePlayers with IIFE try/finally"
fi

if [ -f "$STUDIO_MIN" ] && ! grep -q 'spinner-watchdog-v1' "$STUDIO_MIN" 2>/dev/null; then
    cat >> "$STUDIO_MIN" <<'JSEOF'
/* spinner-watchdog-v1 */
angular.module('KMCModule').run(['requestNotificationChannel','$rootScope',function(ch,$root){var _t,_o=ch.requestStarted.bind(ch);ch.requestStarted=function(c){_o(c);clearTimeout(_t);_t=setTimeout(function(){if(ch.customStart){ch.customStart=null;$root.$broadcast('_END_REQUEST_');}},6000);};}]);
JSEOF
    echo "[kaltura] Studio main.min.js: appended spinner watchdog run block"
fi


# Fix C: update studio.ini — point html5lib to local server and align html5_version with it
# html5_version mismatch (Studio ships v2.86.1) makes Studio request non-existent resources.
if [ -f "$STUDIO_INI" ]; then
    sed -i \
        -e "s|http://kgit\.html5video\.org/tags/v2\.86\.1/mwEmbedLoader\.php|${SERVICE_PROTOCOL}://${WWW_HOST}/html5/html5lib/${HTML5LIB_VERSION}/mwEmbedLoader.php|g" \
        -e "s|\"html5_version\":\"v2\.86\.1\"|\"html5_version\":\"${HTML5LIB_VERSION}\"|g" \
        "$STUDIO_INI" \
        && echo "[kaltura] Studio studio.ini: set html5lib to local URL and html5_version=${HTML5LIB_VERSION}"
fi

# ── PHP 8.1 fix: KalturaUtils::formatString non-scalar input ──────────────────
# UiConfResult::normalizeFlashVars passes nested stdClass objects to formatString.
# PHP 8.1 makes json_decode() strict about its type, throwing TypeError when
# called with a non-string even inside @json_decode. Guard non-scalar inputs.
# This fixes the "Fatal error: json_decode(): Argument #1 ($json) must be of
# type string, stdClass given" crash in services.php?service=uiConfJs.
KALTURA_UTILS_FILE="$WEB_DIR/html5/html5lib/${HTML5LIB_VERSION}/modules/KalturaSupport/KalturaUtils.php"
if [ -f "$KALTURA_UTILS_FILE" ] && ! grep -q 'is_scalar.*PHP81' "$KALTURA_UTILS_FILE" 2>/dev/null; then
    sed -i 's|public function formatString( \$str ) {|public function formatString( $str ) { /* PHP81 */ if(!is_scalar($str)\&\&!is_null($str)){return $str;}|' \
        "$KALTURA_UTILS_FILE" \
        && echo "[kaltura] KalturaUtils.php: patched formatString for PHP 8.1 non-scalar input" \
        || echo "[kaltura] WARN: KalturaUtils.php formatString patch did not apply"
fi

# ── PHP 8.1 fix: KalturaCommon memcache flags key missing ────────────────────
# cache.ini [memcacheLocal] has no 'flags' key; PHP 8.1 promotes undefined array
# key access to E_WARNING. Default flags to 0 (no compression) when absent.
KALTURA_COMMON="$WEB_DIR/html5/html5lib/${HTML5LIB_VERSION}/modules/KalturaSupport/KalturaCommon.php"
if [ -f "$KALTURA_COMMON" ] && ! grep -q 'PHP81' "$KALTURA_COMMON" 2>/dev/null; then
    sed -i "s|\\\$wgMemcacheConfiguration\['flags'\]|(/* PHP81 */isset(\$wgMemcacheConfiguration['flags']) ? \$wgMemcacheConfiguration['flags'] : 0)|g" \
        "$KALTURA_COMMON" \
        && echo "[kaltura] KalturaCommon.php: patched memcache flags for PHP 8.1" \
        || echo "[kaltura] WARN: KalturaCommon.php flags patch did not apply"
fi

echo "[kaltura] Starting Apache..."
apache2-foreground &
APACHE_PID=$!
trap 'kill -TERM "$APACHE_PID" 2>/dev/null; wait "$APACHE_PID"' TERM INT HUP

# Fix html5studio confFiles via API once Apache is fully up.
# saveConfFileToDisk() silently fails during the temp init Apache phase
# (missing PHP/Kaltura context). Running after full startup it works correctly.
# Queries DB first — only calls update() for uiConfs with no file_sync record.
_HTML5_TMPL="$APP_DIR/deployment/base/scripts/init_content/ui_conf/html5Player.json"
if [ -f "$APP_DIR/tests/lib/KalturaClient.php" ] && [ -f "$_HTML5_TMPL" ]; then
    echo "[kaltura] Waiting for Kaltura API to be ready..."
    _TRIES=0
    until curl -sf --insecure "${SERVICE_URL}/api_v3/?service=system&action=ping" > /dev/null 2>&1; do
        sleep 3
        _TRIES=$(( _TRIES + 1 ))
        if [ "$_TRIES" -gt 20 ]; then
            echo "[kaltura] WARN: API not ready after 60s, skipping confFile fix"
            break
        fi
    done
    if [ "$_TRIES" -le 20 ]; then
        cat > /tmp/fix_uiconf.php <<PHP
<?php
require_once '$APP_DIR/tests/lib/KalturaClient.php';
\$json = file_get_contents('$_HTML5_TMPL');
\$pdo = new PDO('mysql:host=$DB_HOST;dbname=$DB_NAME', '$DB_USER', '$DB_PASS');
\$partners = \$pdo->query('SELECT id, admin_secret FROM partner WHERE id > 0 ORDER BY id')->fetchAll(PDO::FETCH_ASSOC);
foreach (\$partners as \$p) {
    \$stmt = \$pdo->prepare(
        "SELECT u.id FROM ui_conf u
         WHERE u.tags LIKE '%html5studio%'
           AND u.tags NOT LIKE '%kalturaPlayerJs%'
           AND u.partner_id = ?
           AND NOT EXISTS (SELECT 1 FROM file_sync WHERE object_id=u.id AND object_type=2 AND object_sub_type=1)"
    );
    \$stmt->execute([\$p['id']]);
    \$broken = \$stmt->fetchAll(PDO::FETCH_COLUMN);
    if (!\$broken) continue;
    try {
        \$cfg = new KalturaConfiguration(\$p['id']);
        \$cfg->serviceUrl = '$SERVICE_URL';
        \$cfg->curlOptVerifyPeer = false;
        \$client = new KalturaClient(\$cfg);
        \$ks = \$client->session->start(\$p['admin_secret'], '', KalturaSessionType::ADMIN, \$p['id']);
        \$client->setKs(\$ks);
        foreach (\$broken as \$uc_id) {
            \$upd = new KalturaUiConf();
            \$upd->config = \$json;
            \$client->uiConf->update(\$uc_id, \$upd);
            echo "[kaltura] confFile fixed for uiConf \$uc_id (partner {\$p['id']})\n";
        }
    } catch (Exception \$e) {
        echo "[kaltura] ERROR partner {\$p['id']}: " . \$e->getMessage() . "\n";
    }
}
PHP
        php /tmp/fix_uiconf.php >> "$LOG_DIR/uiconf_fix.log" 2>&1 \
            && echo "[kaltura] html5studio confFiles fixed via API" \
            || echo "[kaltura] WARN: confFile fix had errors (check $LOG_DIR/uiconf_fix.log)"
        rm -f /tmp/fix_uiconf.php
    fi
fi

# ── Ready ──────────────────────────────────────────────────────────────────────
log "────────────────────────────────────────────────────────────"
log "Kaltura is ready at ${SERVICE_URL}"
log "  KMC:            ${SERVICE_URL}/index.php/kmcng"
log "  Admin Console:  ${SERVICE_URL}/admin_console   (${ADMIN_EMAIL})"
log "────────────────────────────────────────────────────────────"

wait "$APACHE_PID"
