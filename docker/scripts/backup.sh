#!/usr/bin/env bash
# Take a restorable backup of a running Kaltura stack.
#
# What is captured, and why exactly this set:
#   databases.sql.gz  every Kaltura schema, with stored routines and triggers.
#   web-content.tgz   the kaltura_web volume: uploaded media, transcoded
#                     flavors, thumbnails, generated UI confs. The database is
#                     worthless without it — entries would point at missing files.
#   kaltura.conf      the credentials the database was created with. Restoring
#                     the data without it leaves you locked out of MySQL.
#   certs.tgz         TLS material.
#   docker_secrets.env  per-deployment secrets (DC0 secret, remote-addr salt,
#                     tokens). Regenerating these silently invalidates signed
#                     URLs and headers, so they belong with the data.
#   MANIFEST          what was taken, when, from which commit, and which
#                     services were running — restore starts the same set.
#
# NOT captured on purpose:
#   sphinx_data  rebuildable with `make reindex`; backing it up wastes space and
#                risks restoring a stale index over fresh data.
#   logs, tmp    transient.
#   druid_*      analytics segments. Set BACKUP_DRUID=1 to include them.
#
# Order matters: content is archived BEFORE the database is dumped. A file that
# appears in between ends up in the archive but not the dump (a harmless orphan
# file). The reverse order would produce database rows pointing at files the
# archive does not contain — a broken entry.
#
# Backups are written OUTSIDE the repository (~/kaltura-backups by default) on
# purpose. A backup that lives in the working tree is one `git clean -xfd` away
# from being deleted along with the thing it was protecting.
#
# Usage:  make -C docker backup
# Env:    SKIP_CONTENT=1  database + config only (fast, small)
#         BACKUP_DRUID=1  also archive the Druid deep-storage volume
#         BACKUP_DIR=path override the destination (default ~/kaltura-backups)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$DOCKER_DIR/.." && pwd)"
CONF="${KALTURA_CONF:-$DOCKER_DIR/kaltura.conf}"
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$DOCKER_DIR")}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${BACKUP_DIR:-$HOME/kaltura-backups}/kaltura-$STAMP"

die() { echo "backup: $*" >&2; exit 1; }
say() { printf '  %-34s %s\n' "$1" "${2:-}"; }

[ -f "$CONF" ] || die "$CONF not found"
docker inspect -f '{{.State.Running}}' kaltura_mysql 2>/dev/null | grep -q true \
    || die "kaltura_mysql is not running — start the stack before backing up"

mkdir -p "$DEST" || die "cannot create $DEST"
echo "Backing up to $DEST"

# ── 1. Content volume ─────────────────────────────────────────────────────────
if [ "${SKIP_CONTENT:-0}" = "1" ]; then
    say "web content" "skipped (SKIP_CONTENT=1)"
else
    docker run --rm -v "${PROJECT}_kaltura_web:/data:ro" -v "$DEST:/backup" alpine \
        tar czf /backup/web-content.tgz -C /data . 2>/dev/null \
        || die "could not archive the ${PROJECT}_kaltura_web volume"
    say "web content" "$(du -h "$DEST/web-content.tgz" | cut -f1)"
fi

# ── 2. Databases ──────────────────────────────────────────────────────────────
# Enumerated rather than --all-databases: the mysql system schema is version
# specific and restoring it over a different server is a good way to lock
# yourself out. Users and grants are re-created by restore instead.
DBS=$(docker exec kaltura_mysql sh -c \
    'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SHOW DATABASES" 2>/dev/null' \
    | grep -E '^(kaltura|kaltura_sphinx_log|kalturadw|kalturadw_ds|kalturadw_bisources|kalturalog)$' | tr '\n' ' ')
[ -n "$DBS" ] || die "no Kaltura databases found"

docker exec kaltura_mysql sh -c \
    "mysqldump -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --single-transaction --routines --triggers --events --databases $DBS 2>/dev/null" \
    | gzip > "$DEST/databases.sql.gz"
[ -s "$DEST/databases.sql.gz" ] || die "database dump is empty"
say "databases" "$(echo "$DBS" | wc -w | tr -d ' ') schemas, $(du -h "$DEST/databases.sql.gz" | cut -f1)"

# ── 3. Configuration and secrets ──────────────────────────────────────────────
cp "$CONF" "$DEST/kaltura.conf" && chmod 600 "$DEST/kaltura.conf"
say "kaltura.conf" "ok"

if [ -d "$DOCKER_DIR/certs" ] && [ -n "$(ls -A "$DOCKER_DIR/certs" 2>/dev/null)" ]; then
    tar czf "$DEST/certs.tgz" -C "$DOCKER_DIR" certs && chmod 600 "$DEST/certs.tgz"
    say "certificates" "ok"
else
    say "certificates" "none present"
fi

if [ -f "$ROOT/configurations/.docker_secrets.env" ]; then
    cp "$ROOT/configurations/.docker_secrets.env" "$DEST/docker_secrets.env"
    chmod 600 "$DEST/docker_secrets.env"
    say "deployment secrets" "ok"
else
    say "deployment secrets" "not found (will be regenerated on restore)"
fi

# ── 4. Druid (opt-in) ─────────────────────────────────────────────────────────
if [ "${BACKUP_DRUID:-0}" = "1" ]; then
    docker run --rm -v "${PROJECT}_druid_shared:/data:ro" -v "$DEST:/backup" alpine \
        tar czf /backup/druid-shared.tgz -C /data . 2>/dev/null \
        && say "druid segments" "$(du -h "$DEST/druid-shared.tgz" | cut -f1)" \
        || say "druid segments" "FAILED (volume missing?)"
fi

# ── 5. Manifest ───────────────────────────────────────────────────────────────
RUNNING=$(docker ps --filter "name=kaltura_" --format '{{.Names}}' | sed 's/^kaltura_//' | sort | tr '\n' ' ')
{
    # Values are quoted: restore sources this file, and an unquoted value
    # containing spaces or parentheses is parsed as a command.
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(hostname)"
    echo "project=$PROJECT"
    echo "git_commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "git_branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "databases=\"$DBS\""
    echo "content_included=$([ -f "$DEST/web-content.tgz" ] && echo yes || echo no)"
    echo "druid_included=$([ -f "$DEST/druid-shared.tgz" ] && echo yes || echo no)"
    # Container names minus the kaltura_ prefix; restore maps these back to
    # compose services so a core-only stack is not restored as a full one.
    echo "running_containers=\"$RUNNING\""
    echo "mysql_version=\"$(docker exec kaltura_mysql mysql --version 2>/dev/null | head -1)\""
} > "$DEST/MANIFEST"
say "manifest" "ok"

# Checksums make a truncated or half-copied backup obvious at restore time
# rather than halfway through loading it.
( cd "$DEST" && find . -maxdepth 1 -type f ! -name SHA256SUMS -exec shasum -a 256 {} \; > SHA256SUMS 2>/dev/null ) || true

echo
echo "Backup complete: $DEST  ($(du -sh "$DEST" | cut -f1))"
echo "Restore with:    make -C docker restore B=$DEST"
echo
echo "A backup you have never restored is not a backup — rehearse it on a"
echo "scratch host at least once before you need it."
