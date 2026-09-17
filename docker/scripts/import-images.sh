#!/usr/bin/env bash
# Load the images from `make export-images` on a host with no internet, and
# prove they are exactly the ones that were built and tested.
#
# Three checks, each stops the import:
#   1. the tar matches its checksum (a truncated or corrupted copy)
#   2. every loaded image has the image ID recorded at export (a different image)
#   3. every image the stack references resolves locally with the offline
#      overlay (a name compose would otherwise try to pull, or build)
#
# Usage:  make -C docker import-images IMAGES=/path/to/kaltura-images.tar
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
CONF="${KALTURA_CONF:-$DOCKER_DIR/kaltura.conf}"
TAR="${1:-}"

die() { echo "import-images: $*" >&2; exit 1; }
say() { printf '  %-34s %s\n' "$1" "${2:-}"; }

[ -n "$TAR" ] || die "usage: make -C docker import-images IMAGES=/path/to/kaltura-images.tar"
[ -f "$TAR" ] || die "$TAR not found"
[ -f "$CONF" ] || die "$CONF not found — run 'make -C docker config' first"
DIR="$(cd "$(dirname "$TAR")" && pwd)"
NAME="$(basename "$TAR")"
[ -f "$DIR/$NAME.sha256" ] || die "$DIR/$NAME.sha256 missing — copy the whole export directory"
[ -f "$DIR/images.lst" ]   || die "$DIR/images.lst missing — copy the whole export directory"

echo "1. Checksum"
( cd "$DIR" && sha256sum -c "$NAME.sha256" >/dev/null ) || die "checksum mismatch — the copy is incomplete or corrupted"
say "$NAME" "ok"

echo "2. Loading (takes a few minutes)"
docker load -i "$TAR" >/dev/null
while read -r id name; do
    got=$(docker image inspect -f '{{.Id}}' "$name" 2>/dev/null) || die "$name was not loaded"
    [ "$got" = "$id" ] || die "$name has ID $got, expected $id — not the image that was exported"
done < "$DIR/images.lst"
say "images" "$(wc -l < "$DIR/images.lst" | tr -d ' ') loaded, IDs match"

echo "3. Offline resolution"
# Captured first: an empty list from a failing `config` must not pass as "all resolve".
REFS=$(docker compose --env-file "$CONF" --profile analytics \
        -f "$DOCKER_DIR/docker-compose.yml" -f "$DOCKER_DIR/docker-compose.offline.yml" \
        config --images | sort -u)
[ -n "$REFS" ] || die "compose returned no images"
missing=0
while IFS= read -r ref; do
    docker image inspect "$ref" >/dev/null 2>&1 || { echo "  missing: $ref" >&2; missing=1; }
done <<< "$REFS"
[ "$missing" = 0 ] || die "images above do not resolve — was the stack directory renamed? (compose names built images <project>-<service>)"
say "stack images" "all resolve locally"

grep -qE '^KALTURA_OFFLINE=1' "$CONF" \
    || echo "  NOTE: set KALTURA_OFFLINE=1 in $CONF before 'make up', or compose will try to pull"
