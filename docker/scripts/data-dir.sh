#!/usr/bin/env bash
# Named volumes kept in host directories chosen in kaltura.conf.
#
#   data-dir.sh render     write docker-compose.volumes.yml for the volumes that
#                          have a host directory and print "-f <file>" for
#                          compose; print nothing (and remove the file) when
#                          none has one
#   data-dir.sh prepare    before compose creates anything: check the settings,
#                          check every existing volume is where they say, then
#                          create the subdirectories the group settings need
#   data-dir.sh wipe       after `down -v`: empty every volume's host directory
#   data-dir.sh wipe VOL…  the same for the named volumes only (restore.sh)
#   data-dir.sh path VOL   print VOL's host directory, empty if it has none
#   data-dir.sh list       "<volume> <directory> own|sub" for every volume that has one
#
# Where a volume lives — the first that is set wins:
#   1. its own setting: KALTURA_DB_DIR, KALTURA_WEB_DIR, … (see VOLUMES below).
#      A single-volume setting IS the directory; KALTURA_ANALYTICS_DIR holds
#      one subdirectory per analytics volume, named after it.
#   2. KALTURA_DATA_DIR/<volume name>
#   3. Docker's own storage (/var/lib/docker/volumes), as without any setting.
# The volumes keep their names (docker_mysql_data, …), so everything that
# addresses them by name works unchanged; only where the bytes live changes.
# Docker still fills an empty one from the image and gives it the image
# directory's owner.
#
# Why render writes a file on every run: compose cannot make a volume's bind
# conditional on a variable, so the file lists exactly the volumes that have a
# directory. It is generated, git-ignored, and readable — `cat` it to see what
# is bound where.
#
# Why prepare refuses instead of repairing: compose reuses an existing volume
# as it is and never moves data. A volume created in Docker's own storage
# before its setting was added would go on being used, the setting silently
# ignored. One whose setting was removed keeps working too, until
# `make destroy` leaves its data behind (wipe no longer knows the directory)
# and the next `up` starts on an empty volume. Moving data is a deliberate step
# (README, section 7), never a side effect.
#
# Why wipe exists: `down -v` removes a bind volume's definition, not its
# directory. Without it `make destroy` would keep every byte and the next `up`
# would start on the old database. It empties the volumes' own directories —
# nothing else under KALTURA_DATA_DIR or KALTURA_ANALYTICS_DIR is touched.
#
# Directories are created and emptied from an alpine container: what is in them
# belongs to the containers' users (mysql, druid, …) and the host user running
# make is usually not root, but Docker is. alpine is part of the offline image
# export (scripts/export-images.sh), so this works without internet too.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
CONF="${KALTURA_CONF:-$DOCKER_DIR/kaltura.conf}"
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$DOCKER_DIR")}"
OUT="$DOCKER_DIR/docker-compose.volumes.yml"

# <volume> <setting> [group]. Must list every volume in docker-compose.yml;
# prepare refuses to start when one is missing here.
VOLUMES="
mysql_data            KALTURA_DB_DIR
kaltura_web           KALTURA_WEB_DIR
kaltura_log           KALTURA_LOG_DIR
kaltura_tmp           KALTURA_TMP_DIR
sphinx_data           KALTURA_SEARCH_DIR
live_recordings       KALTURA_LIVE_DIR
kafka_data            KALTURA_ANALYTICS_DIR group
druid_shared          KALTURA_ANALYTICS_DIR group
druid_pgdata          KALTURA_ANALYTICS_DIR group
druid_coordinator_var KALTURA_ANALYTICS_DIR group
druid_broker_var      KALTURA_ANALYTICS_DIR group
druid_historical_var  KALTURA_ANALYTICS_DIR group
druid_middle_var      KALTURA_ANALYTICS_DIR group
druid_router_var      KALTURA_ANALYTICS_DIR group
"
SETTINGS="KALTURA_DB_DIR KALTURA_WEB_DIR KALTURA_LOG_DIR KALTURA_TMP_DIR KALTURA_SEARCH_DIR KALTURA_LIVE_DIR KALTURA_ANALYTICS_DIR KALTURA_DATA_DIR"

die() { echo "data-dir: $*" >&2; exit 1; }

# A setting's value as compose reads it: last assignment wins, comments ignored.
conf() { [ -f "$CONF" ] && sed -n "s/^$1=//p" "$CONF" | tail -1 | sed 's/[[:space:]]*$//'; }

# "<directory> <kind>" for one volume, nothing for Docker's own storage.
# kind "own": the setting is the directory, it must exist already.
# kind "sub": a subdirectory of a group setting or KALTURA_DATA_DIR, which
# prepare creates.
locate() {
    local line vol setting group v
    line=$(echo "$VOLUMES" | awk -v v="$1" '$1 == v')
    [ -n "$line" ] || return 0
    read -r vol setting group <<< "$line"
    v=$(conf "$setting")
    if [ -n "$v" ]; then
        if [ "$group" = group ]; then echo "$v/$vol sub"; else echo "$v own"; fi
        return 0
    fi
    v=$(conf KALTURA_DATA_DIR)
    [ -n "$v" ] && echo "$v/$vol sub"
    return 0
}

dir_of() { locate "$1" | awk '{print $1}'; }

# "<volume> <directory> <kind>" for every volume that has a directory.
list() {
    local vol l
    for vol in $(echo "$VOLUMES" | awk 'NF {print $1}'); do
        l=$(locate "$vol")
        [ -n "$l" ] && echo "$vol $l"
    done
    return 0
}

render() {
    local entries
    entries=$(list)
    if [ -z "$entries" ]; then
        rm -f "$OUT"
        return 0
    fi
    {
        echo "# Generated by scripts/data-dir.sh from kaltura.conf on every make run."
        echo "# Do not edit: change KALTURA_*_DIR in kaltura.conf instead."
        echo "volumes:"
        echo "$entries" | while read -r vol d _; do
            echo "  $vol:"
            echo "    driver_opts: {type: none, o: bind, device: \"$d\"}"
        done
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT" || die "could not write $OUT"
    echo "-f $OUT"
}

# Where each existing volume of this project keeps its data: "<volume> <device>",
# device empty for one in Docker's own storage. Missing volumes are not listed.
# By name, not by compose label: `docker run -v <name>:…` creates a volume
# without one, and compose uses it all the same.
existing() {
    # shellcheck disable=SC2046
    docker volume inspect -f '{{.Name}} {{if .Options}}{{index .Options "device"}}{{end}}' \
        $(echo "$VOLUMES" | awk -v p="$PROJECT" 'NF {printf "%s_%s ", p, $1}') 2>/dev/null \
        | sed "s/^${PROJECT}_//"
}

prepare() {
    [ -f "$CONF" ] || die "$CONF not found"
    local s v vol d dev want bad="" base subs

    # A volume added to docker-compose.yml but not to VOLUMES would stay in
    # Docker's own storage without anyone noticing.
    for v in $(sed -n '/^volumes:/,/^[^ ]/s/^  \([a-z_]*\):$/\1/p' "$DOCKER_DIR/docker-compose.yml"); do
        echo "$VOLUMES" | awk '{print $1}' | grep -qx "$v" \
            || die "volume $v is in docker-compose.yml but not in scripts/data-dir.sh (VOLUMES) — add it there"
    done

    for s in $SETTINGS; do
        v=$(conf "$s")
        [ -n "$v" ] || continue
        case "$v" in
            /) die "$s must not be / — use a directory of its own" ;;
            */) die "$s must not end with / (got '$v')" ;;
            /*) ;;
            *) die "$s must be an absolute path, got '$v'" ;;
        esac
        case "$v" in
            *[!A-Za-z0-9._/-]*) die "$s may only contain letters, digits and . _ / - (got '$v')" ;;
        esac
        # Not created here: a mistyped path must stop the stack, not start it
        # on a fresh empty directory.
        [ -d "$v" ] || die "$s=$v does not exist — create it first (sudo mkdir -p $v)"
    done

    # A single-volume directory is used as it is. The root of a filesystem
    # brings lost+found along, and MySQL refuses to initialise next to it.
    while read -r vol d kind; do
        [ "$kind" = own ] || continue
        [ -e "$d/lost+found" ] && die "$d is the root of a filesystem (lost+found) — use a directory inside it, e.g. $d/$vol"
    done < <(list)

    # Two volumes in one directory, or one inside another, would mix their data.
    local dirs
    dirs=$(list | awk '{print $2}')
    while read -r d; do
        [ -n "$d" ] || continue
        while read -r v; do
            [ -n "$v" ] && [ "$v" != "$d" ] || continue
            case "$v/" in "$d"/*) die "$v is inside $d — every volume needs a directory of its own" ;; esac
        done <<< "$dirs"
    done <<< "$dirs"
    [ -z "$(echo "$dirs" | sort | uniq -d)" ] \
        || die "two volumes share $(echo "$dirs" | sort | uniq -d | head -1) — every volume needs a directory of its own"

    local own="Docker's own storage"
    while read -r vol dev; do
        [ -n "$vol" ] || continue
        want=$(dir_of "$vol")
        [ "$dev" = "$want" ] && continue
        bad="$bad
  ${PROJECT}_$vol is in ${dev:-$own}, kaltura.conf says ${want:-$own}"
    done < <(existing)
    [ -z "$bad" ] || die "these volumes already exist somewhere else:$bad
Compose would keep using them where they are. A new install with nothing to
keep: 'make -C docker destroy' first. Data to keep: move it (docker/README.md,
section 7), or put the setting back."

    # Subdirectories of KALTURA_ANALYTICS_DIR and KALTURA_DATA_DIR, one alpine
    # run per base directory. Single-volume directories exist already.
    for base in $(list | awk '$3 == "sub" {d=$2; sub(/\/[^\/]*$/, "", d); print d}' | sort -u); do
        subs=$(list | awk -v b="$base" '$3 == "sub" {d=$2; n=d; sub(/\/[^\/]*$/, "", d)} $3 == "sub" && d == b {sub(/.*\//, "", n); print n}' | tr '\n' ' ')
        # shellcheck disable=SC2086
        docker run --rm -v "$base:/d" -w /d alpine mkdir -p $subs \
            || die "could not create the volume directories in $base"
    done
    render >/dev/null
}

wipe() {
    local vol d n=0
    [ -f "$CONF" ] || return 0
    while read -r vol d _; do
        [ -n "$vol" ] || continue
        [ $# -eq 0 ] || printf '%s\n' "$@" | grep -qx "$vol" || continue
        [ -d "$d" ] || continue
        docker run --rm -v "$d:/d" alpine sh -c 'rm -rf /d/* /d/.[!.]* /d/..?*' \
            || die "could not empty $d"
        n=$((n + 1))
    done < <(list)
    [ "$n" -gt 0 ] && [ $# -eq 0 ] && echo "Emptied $n volume director$([ "$n" = 1 ] && echo y || echo ies) (kaltura.conf KALTURA_*_DIR)"
    return 0
}

case "${1:-}" in
    render)  render ;;
    prepare) prepare ;;
    wipe)    shift; wipe "$@" ;;
    path)    [ -n "${2:-}" ] || die "usage: data-dir.sh path <volume>"; dir_of "$2" ;;
    list)    list ;;
    *)       die "usage: data-dir.sh render|prepare|wipe [volume…]|path <volume>|list" ;;
esac
