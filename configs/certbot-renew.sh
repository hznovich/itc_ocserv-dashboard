#!/bin/bash
# =============================================================================
# certbot-renew.sh — periodic Let's Encrypt renewal.
# =============================================================================
# Started by supervisord regardless of the toggle. If CERTBOT_ENABLED != true,
# we just sleep forever — supervisor would respawn the script if it exits, so
# blocking on `sleep infinity` is the cleanest no-op. When enabled, we attempt
# a renewal once a day. Certbot's `renew` is itself a no-op until certs are
# within 30 days of expiry, so daily is the canonical recommendation.
#
# After a successful renewal we send SIGHUP to ocserv, which makes it reload
# server-cert/server-key in place without dropping connected clients, and
# `nginx -s reload` to pick up the new chain in the dashboard listener.
# =============================================================================

set -u

if [ "${CERTBOT_ENABLED:-false}" != "true" ]; then
    # Idle forever; supervisor will not respawn rapidly.
    exec sleep infinity
fi

LOG_PREFIX='\033[1;35m[certbot-renew]\033[0m'

while true; do
    printf "${LOG_PREFIX} attempting renewal\n"
    if certbot renew --quiet \
        --http-01-port "${CERTBOT_HTTP_PORT:-80}" \
        --config-dir /opt/certs \
        --work-dir /var/lib/letsencrypt \
        --logs-dir /var/log/letsencrypt; then
        # Reload services on success. We don't care if a particular signal
        # fails — both ocserv and nginx are robust to it.
        #
        # The path must match `pid-file` in the ocserv.conf the entrypoint
        # generates, which is /run/ocserv/ocserv.pid. It is NOT
        # /var/run/ocserv.pid: that resolves to /run/ocserv.pid, one directory
        # short, so the test silently failed and ocserv kept presenting the old
        # chain after a successful renewal while nginx picked up the new one.
        # The dashboard looked correct and only VPN clients saw a stale cert.
        if [ -f /run/ocserv/ocserv.pid ]; then
            kill -HUP "$(cat /run/ocserv/ocserv.pid)" 2>/dev/null || true
        fi
        nginx -s reload 2>/dev/null || true
    else
        printf "${LOG_PREFIX} renewal returned non-zero (often expected when nothing is due)\n"
    fi
    # 12 hours; certbot's own internal threshold prevents over-eager renewals.
    sleep 43200
done
