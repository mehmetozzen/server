#!/usr/bin/env bash
# Rebuild every Sphinx index from the database.
#
# Why this exists: search results are written to Sphinx synchronously by the app
# (base.ini exec_sphinx = true) and a row is appended to `sphinx_log`. Nothing in
# this stack consumes sphinx_log — bare metal runs populateFromLog.php as a
# daemon, we do not. So if the sphinx_data volume is lost, or a synchronous write
# fails while Sphinx is restarting, the affected objects are missing from search
# with no way back. This script is that way back.
#
# Safe to run at any time: the populate scripts issue REPLACE statements, so
# re-running only refreshes rows. Run it after `docker volume rm docker_sphinx_data`,
# after restoring a database backup, or whenever KMC search looks incomplete.
#
# Usage:  make -C docker reindex
set -uo pipefail

APP_CONTAINER="${KALTURA_APP_CONTAINER:-kaltura_app}"
SPHINX_CONTAINER="${KALTURA_SPHINX_CONTAINER:-kaltura_sphinx}"

# Ordered: entries first (the bulk and what most searches hit), then the objects
# that reference them. Each is independent — a failure does not block the rest.
SCRIPTS=(
    populateSphinxEntries.php
    populateSphinxCategories.php
    populateSphinxKusers.php
    populateSphinxCategoryKusers.php
    populateSphinxTags.php
    populateSphinxCuePoints.php
    populateSphinxMetadata.php
    populateSphinxCaptionAssetItem.php
    populateSphinxScheduleEvents.php
    populateSphinxEntryDistributions.php
    populateSphinxEntryVendorTasks.php
)

die() { echo "reindex: $*" >&2; exit 1; }

docker inspect -f '{{.State.Running}}' "$APP_CONTAINER"  2>/dev/null | grep -q true \
    || die "$APP_CONTAINER is not running — start the stack first (make -C docker up)"
docker inspect -f '{{.State.Running}}' "$SPHINX_CONTAINER" 2>/dev/null | grep -q true \
    || die "$SPHINX_CONTAINER is not running — Sphinx must be up to receive the index writes"

echo "Rebuilding Sphinx indexes from the database. This can take a while on a large library."
echo

failed=0
for s in "${SCRIPTS[@]}"; do
    printf '  %-38s ' "$s"
    # www-data, not root: these scripts write into the shared cache/ tree, and
    # root-owned cache files break every later www-data process (batch workers,
    # cron). Output is captured so a stack trace does not flood the terminal.
    out=$(docker exec "$APP_CONTAINER" su -s /bin/bash www-data \
             -c "cd /opt/kaltura/app/deployment/base/scripts && php $s" 2>&1)
    rc=$?
    # Exit code alone is not enough: these scripts catch their own exceptions,
    # write "ERR: Exception ..." to the log and still exit 0. A reindex that
    # silently indexes nothing is the exact failure this script exists to fix.
    # "Pending plugin name [rabbitMQ] is not available" is emitted by every
    # script on this stack (BeaconPlugin / SearchHistoryPlugin want RabbitMQ,
    # which we deliberately do not run) and does not affect indexing. Filter it
    # out so the check stays sensitive to errors that DO matter, such as the
    # "Access denied to kaltura_sphinx_log" that once left the index empty
    # while every script reported success.
    real_err=$(echo "$out" | grep -E '\] ERR:|Exception:|PHP Fatal' | grep -v 'Pending plugin name')
    if [ "$rc" -ne 0 ] || [ -n "$real_err" ]; then
        echo "FAILED"
        echo "$real_err" | head -3 | cut -c1-160 | sed 's/^/      /'
        failed=$((failed + 1))
    else
        echo "ok"
    fi
done

# Report what actually landed in the index. "All scripts ok" with an empty
# index is not a successful reindex.
echo
echo "Index contents:"
for idx in kaltura_entry kaltura_category kaltura_kuser kaltura_tag; do
    n=$(docker exec "$SPHINX_CONTAINER" mysql -h 127.0.0.1 -P 9312 -N -B \
            -e "SELECT COUNT(*) FROM $idx" 2>/dev/null)
    printf '  %-28s %s rows\n' "$idx" "${n:-?}"
done
ENTRIES=$(docker exec "$SPHINX_CONTAINER" mysql -h 127.0.0.1 -P 9312 -N -B \
              -e "SELECT COUNT(*) FROM kaltura_entry" 2>/dev/null)
DB_ENTRIES=$(docker exec kaltura_mysql sh -c \
    'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" kaltura -N -B -e "SELECT COUNT(*) FROM entry WHERE status <> 3"' 2>/dev/null)
if [ "${DB_ENTRIES:-0}" -gt 0 ] && [ "${ENTRIES:-0}" -eq 0 ]; then
    echo
    echo "reindex: the database holds ${DB_ENTRIES} entries but the index is EMPTY."
    failed=$((failed + 1))
fi

echo
if [ "$failed" -gt 0 ]; then
    echo "reindex: $failed script(s) failed — see the excerpts above."
    echo "Scripts for plugins with no data (distribution, reach) can fail harmlessly."
    exit 1
fi

echo "reindex: all indexes rebuilt."
echo "Verify from KMC search, or:"
echo "  docker exec $SPHINX_CONTAINER mysql -h 127.0.0.1 -P 9312 -e 'SELECT COUNT(*) FROM kaltura_entry'"
