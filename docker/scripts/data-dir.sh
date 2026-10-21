#!/usr/bin/env bash
# Named volumes in a host directory (KALTURA_DATA_DIR, docker-compose.data.yml).
#
#   data-dir.sh prepare  before compose creates anything: check that every
#                        volume that already exists is where kaltura.conf says,
#                        then create the missing subdirectories
#   data-dir.sh wipe     after `down -v`: empty the volumes' subdirectories
#
# Why prepare refuses instead of repairing: compose reuses an existing volume
# as it is and never moves data. A volume created in Docker's own storage
# before KALTURA_DATA_DIR was set would go on being used, the setting silently
# ignored. One created in a data directory that kaltura.conf no longer names
# keeps working too, until `make destroy` leaves its data behind (wipe does not
# know the directory) and the next `up` starts on empty volumes as a fresh
# install. Moving data is a deliberate step (README, section 7), never a side
# effect.
#
# Why wipe exists: `down -v` removes a bind volume's definition, not its
# directory. Without it `make destroy` would keep every byte and the next `up`
# would start on the old database. Only the volumes' own subdirectories go —
# nothing else under KALTURA_DATA_DIR is touched.
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

die() { echo "data-dir: $*" >&2; exit 1; }

[ -f "$CONF" ] || die "$CONF not found"
DATA_DIR=$(sed -n 's/^KALTURA_DATA_DIR=//p' "$CONF" | tail -1)
VOLUMES=$(sed -n 's/^  \([a-z_]*\):$/\1/p' "$DOCKER_DIR/docker-compose.data.yml")
[ -n "$VOLUMES" ] || die "no volumes found in docker-compose.data.yml"

# Where each existing volume of this project keeps its data: "<volume> <device>",
# device empty for one in Docker's own storage. Missing volumes are not listed.
# By name, not by compose label: `docker run -v <name>:…` (restore.sh) creates
# a volume without one, and compose uses it all the same.
existing() {
    # shellcheck disable=SC2046
    docker volume inspect -f '{{.Name}} {{if .Options}}{{index .Options "device"}}{{end}}' \
        $(printf "${PROJECT}_%s " $VOLUMES) 2>/dev/null | sed "s/^${PROJECT}_//"
}

prepare() {
    local bad="" v dev want
    if [ -z "$DATA_DIR" ]; then
        while read -r v dev; do
            [ -n "$dev" ] && bad="$bad
  ${PROJECT}_$v keeps its data in $dev"
        done < <(existing)
        [ -z "$bad" ] && return 0
        die "KALTURA_DATA_DIR is not set, but these volumes were created in a data directory:$bad
Set KALTURA_DATA_DIR in $CONF to that directory again. Without it, the next
'make destroy' would leave their data behind and 'make up' would start on empty
volumes, as a fresh install."
    fi

    case "$DATA_DIR" in
        /) die "KALTURA_DATA_DIR must not be / — use a directory of its own, e.g. /data/kaltura" ;;
        */) die "KALTURA_DATA_DIR must not end with / (got '$DATA_DIR')" ;;
        /*) ;;
        *) die "KALTURA_DATA_DIR must be an absolute path, got '$DATA_DIR'" ;;
    esac
    # Not created here: a mistyped path must stop the stack, not start it on a
    # fresh empty directory.
    [ -d "$DATA_DIR" ] || die "KALTURA_DATA_DIR=$DATA_DIR does not exist — create it first (sudo mkdir -p $DATA_DIR)"

    # A volume added to docker-compose.yml but not to the data file would stay
    # in Docker's own storage without anyone noticing.
    local base
    base=$(sed -n '/^volumes:/,/^[^ ]/s/^  \([a-z_]*\):$/\1/p' "$DOCKER_DIR/docker-compose.yml")
    for v in $base; do
        echo "$VOLUMES" | grep -qx "$v" || die "volume $v is in docker-compose.yml but not in docker-compose.data.yml — add it there"
    done

    while read -r v dev; do
        echo "$VOLUMES" | grep -qx "$v" || continue
        want="$DATA_DIR/$v"
        [ -n "$dev" ] || dev="Docker's own storage"
        [ "$dev" = "$want" ] || bad="$bad
  ${PROJECT}_$v is in $dev, not $want"
    done < <(existing)
    [ -z "$bad" ] || die "these volumes already exist somewhere else:$bad
Compose would keep using them and ignore KALTURA_DATA_DIR. A new install with
nothing to keep: 'make -C docker destroy' first. Data to keep: move it
(docker/README.md, section 7)."

    # shellcheck disable=SC2086
    docker run --rm -v "$DATA_DIR:/d" -w /d alpine mkdir -p $VOLUMES \
        || die "could not create the volume directories in $DATA_DIR"
}

wipe() {
    [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ] || return 0
    # shellcheck disable=SC2086
    docker run --rm -v "$DATA_DIR:/d" -w /d alpine rm -rf $VOLUMES \
        || die "could not empty the volume directories in $DATA_DIR"
    echo "Emptied the volume directories in $DATA_DIR"
}

case "${1:-}" in
    prepare) prepare ;;
    wipe)    wipe ;;
    *)       die "usage: data-dir.sh prepare|wipe" ;;
esac
