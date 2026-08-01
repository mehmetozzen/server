# Shared by the app and batch entrypoints (sourced, not executed).
# Writes /etc/msmtprc from SMTP_* env vars so PHP mail() → msmtp → SMTP relay
# works. Bare-metal Kaltura relies on a local postfix; containers have no MTA,
# so without this every outgoing e-mail (password reset, user invitations,
# bulk-upload results) silently fails.
#
# Env contract (all optional; SMTP_HOST empty = mail disabled with a loud WARN):
#   SMTP_HOST      relay host, e.g. smtp.example.com or a mailpit container
#   SMTP_PORT      default 587
#   SMTP_TLS       on|off, default on  (use off for a local dev relay)
#   SMTP_STARTTLS  on|off, default on  (set off with SMTP_PORT=465 implicit TLS)
#   SMTP_USER/SMTP_PASS  relay credentials (auth off when SMTP_USER empty)
#   SMTP_FROM      envelope sender, default no-reply@$WWW_HOST

setup_msmtp() {
    local _log_dir="${LOG_DIR:-/opt/kaltura/log}"
    if [ -z "${SMTP_HOST:-}" ]; then
        echo "[kaltura] WARN: SMTP_HOST not set — outgoing e-mail (password reset, invitations, bulk-upload results) is DISABLED" >&2
        return 0
    fi
    {
        echo "defaults"
        echo "tls ${SMTP_TLS:-on}"
        echo "tls_starttls ${SMTP_STARTTLS:-on}"
        echo "tls_trust_file /etc/ssl/certs/ca-certificates.crt"
        echo "logfile ${_log_dir}/msmtp.log"
        echo ""
        echo "account default"
        echo "host ${SMTP_HOST}"
        echo "port ${SMTP_PORT:-587}"
        echo "from ${SMTP_FROM:-no-reply@${WWW_HOST:-localhost}}"
        if [ -n "${SMTP_USER:-}" ]; then
            echo "auth on"
            echo "user ${SMTP_USER}"
            echo "password ${SMTP_PASS:-}"
        else
            echo "auth off"
        fi
    } > /etc/msmtprc
    # Contains SMTP_PASS: readable by the PHP user (www-data) but not world.
    chown root:www-data /etc/msmtprc 2>/dev/null || true
    chmod 640 /etc/msmtprc
    echo "[kaltura] Outgoing mail: msmtp → ${SMTP_HOST}:${SMTP_PORT:-587} (from: ${SMTP_FROM:-no-reply@${WWW_HOST:-localhost}})"
}
setup_msmtp
