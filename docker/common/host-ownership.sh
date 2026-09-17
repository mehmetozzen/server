# Shared by the app, batch and scheduler entrypoints (sourced, not executed).
# Must be sourced as root, BEFORE anything is chowned to www-data — a file
# chowned by name before the renumbering keeps the old number.
#
# Both parts exist for media that already lives on the host and is mounted in
# (KALTURA_MEDIA_DIR, see docker-compose.media.yml). With neither variable set
# and no extra mount, behaviour is exactly the image default.
#
# 1. KALTURA_WWW_UID / KALTURA_WWW_GID — renumber the image's www-data (33:33).
#    A bind mount keeps numeric owners. A bare-metal Kaltura on RHEL/CentOS
#    writes media as apache(48) with group kaltura, directories 770 and files
#    640, so uid 33 can open almost none of it (measured: 2 of 283 files).
#    Matching the numbers gives the containers the access the old install had
#    without re-owning a single host file, so the old system still works as a
#    rollback. Apache (APACHE_RUN_USER), gosu, su and cron all resolve
#    www-data by name at run time, so they pick up the new ids.
#
# 2. chown_www — `chown -R www-data:www-data` that does not descend into mount
#    points below its target. The app entrypoint re-owns the whole web tree on
#    every boot; with the host media mounted inside that tree a plain chown -R
#    walks terabytes and takes every file away from the owner the old system
#    needs. `find -xdev` cannot see the boundary — a bind mount from the same
#    filesystem has the same device number — so mounts come from mountinfo.

align_www_data() {
    local uid="${KALTURA_WWW_UID:-}" gid="${KALTURA_WWW_GID:-}"
    case "$uid$gid" in
        *[!0-9]*) echo "[kaltura] FATAL: KALTURA_WWW_UID/KALTURA_WWW_GID must be numbers (got uid='$uid' gid='$gid')" >&2; exit 1 ;;
    esac
    if [ "$uid" = 0 ] || [ "$gid" = 0 ]; then
        echo "[kaltura] FATAL: KALTURA_WWW_UID/KALTURA_WWW_GID must not be 0 — www-data would become root" >&2
        exit 1
    fi
    # Idempotent: a restarted container already carries the new ids, and
    # usermod refuses to renumber a user that has running processes.
    [ -n "$gid" ] && [ "$(id -g www-data)" != "$gid" ] && groupmod -o -g "$gid" www-data
    [ -n "$uid" ] && [ "$(id -u www-data)" != "$uid" ] && usermod -o -u "$uid" www-data
    if [ -n "$uid$gid" ]; then
        echo "[kaltura] www-data runs as uid:gid $(id -u www-data):$(id -g www-data) (KALTURA_WWW_UID/KALTURA_WWW_GID)"
    fi
    return 0
}

chown_www() {
    local target mp
    local -a mounts=() prune=()
    # Field 5 of mountinfo is the mount point; spaces etc. are escaped as \040.
    while read -r _ _ _ _ mp _; do
        mounts+=("$(printf '%b' "$mp")")
    done < /proc/self/mountinfo
    for target in "$@"; do
        [ -e "$target" ] || continue
        prune=()
        for mp in "${mounts[@]}"; do
            case "$mp" in "${target%/}"/*) prune+=(-path "$mp" -prune -o) ;; esac
        done
        # -h: same as chown -R, a symlink itself is re-owned, never its target.
        find "$target" "${prune[@]}" -exec chown -h www-data:www-data {} +
    done
}

align_www_data
