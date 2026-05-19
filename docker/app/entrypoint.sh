#!/bin/bash
set -e

APP_DIR=/opt/kaltura/app
WEB_DIR=/opt/kaltura/web
LOG_DIR=/opt/kaltura/log
TMP_DIR=/opt/kaltura/tmp
DB_HOST="${DB1_HOST:-mysql}"
DB_PORT="${DB1_PORT:-3306}"
DB_USER="${DB1_USER:-kaltura}"
DB_PASS="${DB1_PASS:-kaltura123}"
DB_NAME="${DB1_NAME:-kaltura}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-kaltura_root}"
TIME_ZONE="${TIME_ZONE:-UTC}"
SERVICE_PROTOCOL="${PROTOCOL:-http}"
SERVICE_PORT=$( [ "$SERVICE_PROTOCOL" = "https" ] && echo 443 || echo 80 )
WWW_HOST="${WWW_HOST:-kaltura.example.com}"
SERVICE_URL="${SERVICE_URL:-${SERVICE_PROTOCOL}://${WWW_HOST}}"
ADMIN_EMAIL="${ADMIN_CONSOLE_ADMIN_MAIL:-admin@kaltura.local}"
ADMIN_PASS="${ADMIN_CONSOLE_PASSWORD:-Admin1234!}"
MARKER="$APP_DIR/.kaltura_installed"

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
    {
        printf '<VirtualHost *:80>\n'
        printf '    ServerName %s\n' "$WWW_HOST"
        if [ "$SERVICE_PROTOCOL" = "https" ]; then
            printf '    Redirect permanent / https://%s/\n' "$WWW_HOST"
        else
            printf '%s\n' "$BODY"
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
            printf '    ProxyPreserveHost On\n'
            printf '    RequestHeader set X-Forwarded-Proto "https"\n'
            printf '    ProxyPass /hls/ http://packager:88/hls/\n'
            printf '    ProxyPassReverse /hls/ http://packager:88/hls/\n'
            printf '    ProxyPass /dash/ http://packager:88/dash/\n'
            printf '    ProxyPassReverse /dash/ http://packager:88/dash/\n'
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

# ── Hostname resolution for API self-calls ─────────────────────────────────────
grep -q "$WWW_HOST" /etc/hosts || echo "127.0.0.1 $WWW_HOST" >> /etc/hosts

# ── Wait for MySQL ─────────────────────────────────────────────────────────────
echo "[kaltura] Waiting for MySQL at $DB_HOST:$DB_PORT..."
until mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 -e "SELECT 1" > /dev/null 2>&1; do
    echo "[kaltura] MySQL not ready, retrying in 3s..."
    sleep 3
done
echo "[kaltura] MySQL is ready."

# ── Per-deployment secrets (preserved across container restarts) ───────────────
# These are random values referenced as @TOKEN@, @POLL_SECRET@, etc. in templates.
# Persisted to disk so .ini files stay consistent if regenerated.
SECRETS_FILE="$APP_DIR/configurations/.docker_secrets.env"
if [ ! -f "$SECRETS_FILE" ]; then
    cat > "$SECRETS_FILE" <<EOF
DC0_SECRET=$(openssl rand -hex 20)
APP_REMOTE_ADDR_HEADER_SALT=$(printf '%s' "$SERVICE_URL" | base64 | tr -d '\n=')
DEFAULT_IV_16B=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
TOKEN=$(openssl rand -hex 20)
TOKEN_IV=$(openssl rand -hex 8)
POLL_SECRET=$(openssl rand -hex 20)
RTC_TOKEN_SECRET=$(openssl rand -hex 20)
ANALYTICS_SYNC_SECRET=$(openssl rand -hex 20)
AUTHENTICATION_SECRET=$(openssl rand -hex 20)
INSTALLATION_UID=$(cat /proc/sys/kernel/random/uuid)
EOF
fi
. "$SECRETS_FILE"

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
        -e "s|@VOD_PACKAGER_HOST@|$WWW_HOST|g" \
        -e "s|@VOD_PACKAGER_PORT@|$SERVICE_PORT|g" \
        -e "s|@VOD_PACKAGER_URL@|$WWW_HOST|g" \
        -e "s|@LIVE_PACKAGER_HOST@|$WWW_HOST|g" \
        -e "s|@LIVE_PACKAGER_PORT@|$SERVICE_PORT|g" \
        -e "s|@LIVE_PACKAGER_URL@|$WWW_HOST|g" \
        -e "s|@LIVE_PACKAGER_TOKEN@||g" \
        -e "s|@STORAGE_BASE_DIR@|$WEB_DIR|g" \
        -e "s|@KMCNG_VERSION@|v7.20.0|g" \
        -e "s|@DRUID_BROKER_URL@|http://localhost:8082/druid/v2/|g" \
        -e "s|@DRUID_EXTERNAL_CALLS_BROKER_URL@|http://localhost:8082/druid/v2/|g" \
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
if [ -f "$MARKER" ]; then
    echo "[kaltura] Already initialized ($(cat $MARKER)). Skipping setup."
else
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
fi

# ── Create /opt/kaltura/var/run for batch pidfile (batchBase.ini pidFileDir) ──
mkdir -p /opt/kaltura/var/run
chown -R www-data:www-data /opt/kaltura/var 2>/dev/null || true

# ── Always run installPlugins (idempotent, registers plugin enums in dynamic_enum)
echo "[kaltura] Syncing plugin enums..."
cd "$APP_DIR/deployment/base/scripts"
php installPlugins.php >> "$LOG_DIR/installPlugins.log" 2>&1

echo "[kaltura] Admin: $ADMIN_EMAIL / $ADMIN_PASS"

# Ensure all web content dirs created during init are writable by www-data
chown -R www-data:www-data "$WEB_DIR/content" "$WEB_DIR/cache" "$WEB_DIR/tmp" 2>/dev/null || true

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
    done
fi

# ── V2 uiConf: fix html5_url {latest} and wire up file_sync records ───────────
# insertDefaults.php creates partner uiconfs via raw SQL (bypasses Kaltura API),
# so no conf file or file_sync record is created. We link each partner V2 uiconf
# to the system uiconf's (partner_id=0) existing file_sync record — same physical
# file, no copy needed, batch workers won't delete READY records.
# html5_url with {latest} also needs resolving: embedIframeAction handles it but
# mwEmbedFrame reads html5_url directly from uiconf.get inside the iframe.
mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 kaltura <<SQL 2>/dev/null
UPDATE ui_conf
SET html5_url   = REPLACE(html5_url, '{latest}', 'v2.7.4'),
    custom_data = 'a:1:{s:17:"conf_file_version";d:2;}'
WHERE partner_id > 0
  AND html5_url LIKE '%{latest}%'
  AND tags NOT LIKE '%kalturaPlayerJs%';

INSERT INTO file_sync
    (partner_id, object_type, object_id, object_sub_type, version, original, status, dc,
     file_root, file_path, file_size, created_at, updated_at, ready_at)
SELECT
    uc.partner_id, 2, CAST(uc.id AS CHAR), 1,
    fs.version, 1, fs.status, fs.dc,
    fs.file_root, fs.file_path, fs.file_size,
    NOW(), NOW(), NOW()
FROM ui_conf uc
CROSS JOIN (
    SELECT * FROM file_sync
    WHERE object_type=2 AND object_sub_type=1 AND status=2
      AND partner_id=0 AND file_size > 1000
    ORDER BY id LIMIT 1
) fs
WHERE uc.partner_id > 0
  AND uc.tags NOT LIKE '%kalturaPlayerJs%'
  AND CAST(uc.id AS CHAR) NOT IN (
      SELECT object_id FROM file_sync
      WHERE object_type=2 AND object_sub_type=1 AND status=2
  );
SQL
echo "[kaltura] V2 uiConf file_sync records ensured."

# ── Fix delivery_profile URLs: remove stale :88 port (route through Apache) ───
mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 kaltura <<SQL 2>/dev/null
UPDATE delivery_profile SET url = REPLACE(url, ':88/', '/') WHERE url LIKE '%:88/%';
SQL

# ── Widgets: every positive partner needs a _<id> widget for widget sessions ───
mysql -h"$DB_HOST" -P"$DB_PORT" -uroot -p"$MYSQL_ROOT_PASS" --ssl=0 kaltura <<SQL 2>/dev/null
INSERT IGNORE INTO widget (id, partner_id, subp_id, created_at, updated_at)
SELECT CONCAT('_', id), id, id * 100, NOW(), NOW()
FROM partner
WHERE id > 0
  AND CONCAT('_', id) NOT IN (SELECT id FROM widget);
SQL

# ── appVersions.ini: set html5_version so embedIframeJs can serve kWidget JS ──
# embedIframeJsAction reads html5_version; if empty it exits with "version not found"
APPVERSIONS="$APP_DIR/configurations/appVersions.ini"
if [ -f "$APPVERSIONS" ] && grep -qE '^html5_version\s*=\s*$' "$APPVERSIONS" 2>/dev/null; then
    sed -i "s|^html5_version = *$|html5_version = v2.7.4|" "$APPVERSIONS"
    echo "[kaltura] Set html5_version = v2.7.4 in appVersions.ini"
fi

echo "[kaltura] Starting Apache..."
exec apache2-foreground
