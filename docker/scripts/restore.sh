#!/usr/bin/env bash
# Restore a Kaltura stack from a backup taken by scripts/backup.sh.
#
# This is destructive: it replaces the databases, the content volume and the
# local configuration with the contents of the backup. It asks first.
#
# Three things this handles that a naive `mysql < dump.sql` does not:
#   Order. The configuration is restored before anything else, because every
#     compose call needs --env-file. On a rebuilt host (fresh clone, no
#     kaltura.conf) nothing else can run until that file exists.
#   Grants. The kaltura DB user's grants on kaltura_sphinx_log and the DWH
#     schemas are created by the app entrypoint's first-install branch. After a
#     restore that branch is skipped (partner -1 exists), so the grants would
#     never be created and every Sphinx write would fail. Re-applied here.
#   Search. sphinx_data is deliberately not in the backup, so the restored
#     stack starts with an empty index. It is rebuilt from the restored
#     database at the end.
#
# Usage:  make -C docker restore B=~/kaltura-backups/kaltura-YYYYmmdd-HHMMSS
# Env:    FORCE=1        skip the confirmation prompt
#         SKIP_REINDEX=1 do not rebuild the search index afterwards
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$DOCKER_DIR/.." && pwd)"
CONF="$DOCKER_DIR/kaltura.conf"
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$DOCKER_DIR")}"
SRC="${1:-}"

die() { echo "restore: $*" >&2; exit 1; }
say() { printf '  %-34s %s\n' "$1" "${2:-}"; }

[ -n "$SRC" ] || die "usage: make -C docker restore B=<backup directory>"
[ -d "$SRC" ] || die "$SRC is not a directory"
SRC="$(cd "$SRC" && pwd)"
[ -f "$SRC/MANIFEST" ]         || die "$SRC/MANIFEST missing — not a backup directory"
[ -f "$SRC/databases.sql.gz" ] || die "$SRC/databases.sql.gz missing"
[ -f "$SRC/kaltura.conf" ]     || die "$SRC/kaltura.conf missing — cannot authenticate to the restored data"

# shellcheck disable=SC1090
. "$SRC/MANIFEST"

echo "Backup:      $SRC"
echo "Taken:       ${created_at:-unknown} on ${host:-unknown}"
echo "From commit: ${git_commit:-unknown} (${git_branch:-unknown})"
echo "Content:     ${content_included:-no}"
echo

if [ -f "$SRC/SHA256SUMS" ]; then
    ( cd "$SRC" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 ) \
        && say "checksums" "ok" \
        || die "checksum mismatch — this backup is incomplete or corrupted"
fi

if [ "${FORCE:-0}" != "1" ]; then
    echo "This REPLACES the current databases, media content and docker/kaltura.conf."
    printf 'Type "restore" to continue: '
    read -r answer
    [ "$answer" = "restore" ] || die "aborted"
fi

echo
echo "1. Restoring configuration"
# First, before any compose call: they all need --env-file. Any existing config
# is kept aside — if this turns out to be the wrong backup, the credentials for
# the current data are still on disk.
[ -f "$CONF" ] && cp "$CONF" "$CONF.before-restore-$(date +%Y%m%d-%H%M%S)"
cp "$SRC/kaltura.conf" "$CONF" && chmod 600 "$CONF"
say "kaltura.conf" "restored (any previous copy kept as .before-restore-*)"

[ -f "$SRC/certs.tgz" ] && tar xzf "$SRC/certs.tgz" -C "$DOCKER_DIR" && say "certificates" "restored"
if [ -f "$SRC/docker_secrets.env" ]; then
    mkdir -p "$ROOT/configurations"
    cp "$SRC/docker_secrets.env" "$ROOT/configurations/.docker_secrets.env"
    chmod 600 "$ROOT/configurations/.docker_secrets.env"
    say "deployment secrets" "restored"
fi

# Re-read the restored credentials — everything below authenticates with them.
set -a; . "$CONF"; set +a
COMPOSE=(docker compose --env-file "$CONF" -f "$DOCKER_DIR/docker-compose.yml")

echo "2. Stopping the stack"
"${COMPOSE[@]}" down >/dev/null 2>&1 || true
say "containers" "stopped"

echo "3. Restoring the content volume"
if [ -f "$SRC/web-content.tgz" ]; then
    docker volume rm "${PROJECT}_kaltura_web" >/dev/null 2>&1 || true
    docker run --rm -v "${PROJECT}_kaltura_web:/data" -v "$SRC:/backup:ro" alpine \
        sh -c 'rm -rf /data/* /data/..?* 2>/dev/null; tar xzf /backup/web-content.tgz -C /data' \
        || die "could not restore the content volume"
    say "web content" "restored"
else
    say "web content" "not in backup — skipped"
fi

echo "4. Starting MySQL on an empty data volume"
docker volume rm "${PROJECT}_mysql_data" >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d mysql >/dev/null 2>&1 || die "could not start MySQL"
# Wait for the compose healthcheck, not a bare ping: on a fresh data volume the
# mysql image runs a TEMPORARY server to initialise, answers ping from it, then
# restarts for real. A load started in that window dies halfway through.
for i in $(seq 1 100); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' kaltura_mysql 2>/dev/null)" = healthy ] && break
    [ "$i" = 100 ] && die "MySQL did not become healthy"
    sleep 3
done
# Over TCP, and retried: the init server accepts socket connections while the
# real one is not up yet, and the server bounces once between the two.
_ok=0
for i in $(seq 1 40); do
    docker exec kaltura_mysql sh -c \
        'mysql -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1"' >/dev/null 2>&1 \
        && { _ok=1; break; }
    sleep 3
done
[ "$_ok" = 1 ] || die "MySQL never accepted a TCP query"
say "mysql" "ready"

echo "5. Loading databases"
LOAD_ERR=$(gunzip -c "$SRC/databases.sql.gz" \
    | docker exec -i kaltura_mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' 2>&1 \
    | grep -v "Using a password on the command line" | head -5)
[ -z "$LOAD_ERR" ] || die "database load failed: $LOAD_ERR"
COUNT=$(docker exec kaltura_mysql sh -c \
    'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"kaltura\"" 2>/dev/null')
[ "${COUNT:-0}" -gt 50 ] || die "only ${COUNT:-0} tables in the kaltura schema — the load did not work"
say "databases" "$COUNT tables in kaltura"

echo "6. Re-applying grants"
# -i is required: without it docker exec does not forward stdin and the
# heredoc below is silently discarded — the grants appear to succeed while
# nothing is applied, and Sphinx writes then fail with "Access denied".
GRANT_ERR=$(docker exec -i kaltura_mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' 2>&1 <<SQL
CREATE USER IF NOT EXISTS '${DB1_USER:-kaltura}'@'%' IDENTIFIED BY '${DB1_PASS}';
ALTER USER '${DB1_USER:-kaltura}'@'%' IDENTIFIED BY '${DB1_PASS}';
GRANT ALL PRIVILEGES                           ON \`${DB1_NAME:-kaltura}\`.* TO '${DB1_USER:-kaltura}'@'%';
GRANT INSERT,UPDATE,DELETE,SELECT,ALTER,CREATE ON kaltura_sphinx_log.*       TO '${DB1_USER:-kaltura}'@'%';
GRANT INSERT,UPDATE,DELETE,SELECT,LOCK TABLES  ON kalturalog.*               TO '${DB1_USER:-kaltura}'@'%';
GRANT INSERT,UPDATE,DELETE,SELECT,EXECUTE      ON kalturadw.*                TO '${DB1_USER:-kaltura}'@'%';
GRANT INSERT,UPDATE,DELETE,SELECT,EXECUTE      ON kalturadw_ds.*             TO '${DB1_USER:-kaltura}'@'%';
GRANT INSERT,UPDATE,DELETE,SELECT,EXECUTE      ON kalturadw_bisources.*      TO '${DB1_USER:-kaltura}'@'%';
FLUSH PRIVILEGES;
SQL
)
GRANT_ERR=$(echo "$GRANT_ERR" | grep -v "Using a password on the command line" | head -3)
[ -z "$GRANT_ERR" ] || die "grants failed: $GRANT_ERR"
# Prove it, rather than trusting the exit code.
docker exec kaltura_mysql sh -c \
    'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SHOW GRANTS FOR \"'"${DB1_USER:-kaltura}"'\"@\"%\""' 2>/dev/null \
    | grep -q kaltura_sphinx_log \
    || die "grant on kaltura_sphinx_log did not apply — Sphinx writes would fail"
say "grants" "applied and verified"

if [ -f "$SRC/druid-shared.tgz" ]; then
    echo "7. Restoring Druid segments"
    docker run --rm -v "${PROJECT}_druid_shared:/data" -v "$SRC:/backup:ro" alpine \
        sh -c 'rm -rf /data/* 2>/dev/null; tar xzf /backup/druid-shared.tgz -C /data' \
        && say "druid segments" "restored"
fi

echo "8. Starting the stack"
# Bring back exactly what was running when the backup was taken, so a core-only
# deployment is not silently restored as a full one with Druid.
SERVICES=""
for c in ${running_containers:-}; do
    case "$c" in
        app)                SERVICES="$SERVICES kaltura" ;;
        analytics_receiver) SERVICES="$SERVICES analytics-receiver" ;;
        live_rtmp)          SERVICES="$SERVICES live-rtmp" ;;
        druid_*)            SERVICES="$SERVICES $(echo "$c" | tr '_' '-')" ;;
        mysql|mailpit)      ;;
        *)                  SERVICES="$SERVICES $c" ;;
    esac
done
[ -n "$SERVICES" ] || SERVICES="memcache sphinx bundler kaltura packager batch scheduler live-rtmp analytics-receiver"
# shellcheck disable=SC2086
"${COMPOSE[@]}" up -d $SERVICES >/dev/null 2>&1 || die "could not start the stack"
say "services" "$(echo "$SERVICES" | wc -w | tr -d ' ') started"

echo "9. Waiting for the API"
BASE="${PROTOCOL:-http}://${WWW_HOST:-localhost}"
ready=no
for i in $(seq 1 90); do
    curl -sk --max-time 5 "$BASE/api_v3/?service=system&action=ping" 2>/dev/null | grep -q '<result>1</result>' && { ready=yes; break; }
    sleep 5
done
[ "$ready" = yes ] && say "api" "responding" || say "api" "NOT responding — check: docker logs kaltura_app"

if [ "${SKIP_REINDEX:-0}" != "1" ] && [ "$ready" = yes ]; then
    echo "10. Rebuilding the search index"
    "$HERE/reindex.sh" 2>&1 | sed 's/^/   /' || say "reindex" "failed — run 'make -C docker reindex' manually"
fi

echo
echo "Restore finished."
echo "Confirm it actually worked:  make -C docker verify"
