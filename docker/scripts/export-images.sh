#!/usr/bin/env bash
# Pack every image the stack needs into one tar, for a host with no internet.
#
# Run on an x86_64 Linux host WITH internet, from the same code package that
# will be delivered. Analytics is always included: which services run is
# decided on the target by COMPOSE_PROFILES, the images must all be there.
#
# Writes to $OUT (default ~/kaltura-images):
#   kaltura-images.tar         every image, tagged the way docker-compose.offline.yml names them
#   kaltura-images.tar.sha256  checksum of the tar (import verifies it before loading)
#   images.lst                 "<image ID> <name>" per image — IDs survive save/load,
#                              so import can prove each image is the one built here
#   BUILD_INFO                 when, where and with what it was built
#
# Usage:  make -C docker export-images            (OUT=/path to change the destination)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$DOCKER_DIR/.." && pwd)"
CONF="${KALTURA_CONF:-$DOCKER_DIR/kaltura.conf}"
OFFLINE_YML="$DOCKER_DIR/docker-compose.offline.yml"
OUT="${OUT:-$HOME/kaltura-images}"
# Not part of any service: backup.sh and restore.sh archive volumes with it.
EXTRA_IMAGES=(alpine:latest)

die() { echo "export-images: $*" >&2; exit 1; }
say() { printf '  %-34s %s\n' "$1" "${2:-}"; }

[ -f "$CONF" ] || die "$CONF not found — run 'make -C docker config' first"
arch=$(docker info -f '{{.Architecture}}' 2>/dev/null) || die "docker is not running"
# The customer hosts are x86_64. Images built on an ARM machine (a Mac) start
# there only under emulation, if at all.
[ "$arch" = x86_64 ] || die "this host is $arch — build on an x86_64 Linux host"

COMPOSE=(docker compose --env-file "$CONF" --profile analytics -f "$DOCKER_DIR/docker-compose.yml")

echo "1. Building images"
"${COMPOSE[@]}" build
echo "2. Pulling registry images"
"${COMPOSE[@]}" pull --ignore-buildable
docker pull -q "${EXTRA_IMAGES[@]}" >/dev/null

echo "3. Tagging"
# Captured first, not read from a process substitution: a failing `config`
# there would silently yield an empty list and an incomplete tar.
REFS=$("${COMPOSE[@]}" config --images | sort -u)
[ -n "$REFS" ] || die "compose returned no images"
NAMES=()
while IFS= read -r ref; do
    case "$ref" in
        *@sha256:*)
            tag="${ref%@sha256:*}"
            grep -qxF "    image: $tag" "$OFFLINE_YML" \
                || die "$tag (from docker-compose.yml) is missing in docker-compose.offline.yml — update it"
            docker tag "$ref" "$tag"
            NAMES+=("$tag") ;;
        *)  NAMES+=("$ref") ;;
    esac
done <<< "$REFS"
NAMES+=("${EXTRA_IMAGES[@]}")
say "images" "${#NAMES[@]}"

echo "4. Saving (several GB, takes a few minutes)"
mkdir -p "$OUT"
docker save -o "$OUT/kaltura-images.tar" "${NAMES[@]}"
for n in "${NAMES[@]}"; do
    printf '%s %s\n' "$(docker image inspect -f '{{.Id}}' "$n")" "$n"
done > "$OUT/images.lst"
( cd "$OUT" && sha256sum kaltura-images.tar > kaltura-images.tar.sha256 )
{
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(hostname)"
    echo "arch=$arch"
    echo "docker=$(docker version -f '{{.Server.Version}}')"
    echo "git_commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
} > "$OUT/BUILD_INFO"

say "written to" "$OUT"
say "kaltura-images.tar" "$(du -h "$OUT/kaltura-images.tar" | cut -f1)"
say "sha256" "$(cut -d' ' -f1 "$OUT/kaltura-images.tar.sha256")"
echo
echo "Deliver the whole $OUT directory together with the code package."
