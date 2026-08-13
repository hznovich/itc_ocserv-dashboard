#!/bin/bash
# =============================================================================
# Container entrypoint
# =============================================================================
# Runs once at container start, then execs supervisord. Responsibilities:
#   1. Sanity-check required env vars and apply sane defaults.
#   2. Initialise PostgreSQL data dir on first run (idempotent).
#   3. Generate /etc/ocserv/ocserv.conf reflecting current env (multi-route,
#      RADIUS toggle, camouflage, split-dns, proxy-proto, etc.).
#   4. Generate /etc/radcli/radiusclient.conf when RADIUS is enabled.
#   5. If CERTBOT_ENABLED=true and certs are missing, obtain them now.
#      Otherwise expect mounted certs at /opt/certs/live/$SSL_CN/.
#   6. Render /etc/nginx/nginx.conf from template.
#   7. Set up TUN, IP forwarding, NAT (skippable via SKIP_NAT=true).
#   8. exec supervisord.
#
# IMPORTANT: with network_mode=host the container shares the host's network
# namespace. iptables/sysctl operations affect the host. Set SKIP_NAT=true if
# you manage host NAT externally.
# =============================================================================

set -euo pipefail

log()  { printf '\033[1;34m[entrypoint]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[entrypoint]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[entrypoint]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Required env + defaults
# -----------------------------------------------------------------------------
[ -n "${SECRET_KEY:-}" ]        || fail "SECRET_KEY is required"
[ -n "${JWT_SECRET:-}" ]        || fail "JWT_SECRET is required"
[ -n "${POSTGRES_PASSWORD:-}" ] || fail "POSTGRES_PASSWORD is required"

if [ "${#SECRET_KEY}" -lt 16 ];  then fail "SECRET_KEY must be at least 16 characters"; fi
if [ "${#JWT_SECRET}" -lt 16 ];  then fail "JWT_SECRET must be at least 16 characters"; fi

: "${HOST:=127.0.0.1}"
: "${OCSERV_PORT:=443}"
# TCP and UDP listeners can differ. This matters when a TCP-only load
# balancer (HAProxy, AWS NLB, nginx stream) fronts the TCP port while DTLS
# traffic reaches the host directly:
#
#   client --TCP 443--> HAProxy --TCP 8443 (+PROXY hdr)--> ocserv
#   client --UDP 443---------------------------------->    ocserv
#
# HAProxy cannot proxy generic UDP, so pointing udp-port at the same
# rewritten port as TCP would make ocserv advertise a DTLS port nothing
# is listening on — clients silently fall back to TCP-over-TCP and the
# tunnel gets noticeably slower on lossy links.
#
# Both default to OCSERV_PORT so existing single-port setups are unchanged.
: "${OCSERV_TCP_PORT:=$OCSERV_PORT}"
: "${OCSERV_UDP_PORT:=$OCSERV_PORT}"

# Set OC_NO_UDP=true to disable DTLS entirely (everything over TCP).
# Simpler behind a TCP-only LB, at the cost of throughput.
: "${OC_NO_UDP:=false}"
: "${OC_NET:=172.16.24.0/24}"
: "${OCSERV_DNS:=8.8.8.8}"
: "${OC_ROUTES:=}"
: "${OC_SPLIT_DNS:=}"
: "${OC_TUNNEL_ALL_DNS:=}"     # auto: true if no split-dns, false if split-dns set
: "${OC_LISTEN_PROXY_PROTO:=false}"
: "${OC_CAMOUFLAGE:=}"
: "${SSL_CN:=$HOST}"
: "${SSL_ORG:=ocserv}"
: "${SSL_EXPIRE:=3650}"
: "${CERTBOT_ENABLED:=false}"
: "${CERTBOT_EMAIL:=}"
# Port certbot binds for the HTTP-01 challenge.
#
# Default 80 works when nothing else owns it. If a reverse proxy / load
# balancer already listens on :80 of this host (common when HAProxy runs
# on the same box as this container in host-network mode), certbot cannot
# bind and issuance fails with "Address already in use". Set this to e.g.
# 8080 and have the proxy forward /.well-known/acme-challenge/ there:
#
#   HAProxy:
#     acl is_acme  path_beg -i /.well-known/acme-challenge/
#     acl host_oc  hdr(host) -i oc.example.com
#     use_backend  acme_backend if host_oc is_acme
#   backend acme_backend
#     mode http
#     server acme 127.0.0.1:8080
#
# Certbot only binds this port for a few seconds during issuance/renewal,
# so do NOT put a health `check` on that backend — it would flap.
: "${CERTBOT_HTTP_PORT:=80}"
: "${RADIUS_ENABLED:=false}"
: "${POSTGRES_HOST:=127.0.0.1}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_DB:=ocserv_db}"
: "${POSTGRES_USER:=ocserv}"
: "${POSTGRES_SSLMODE:=disable}"

# ocserv log-level. Supported values:
#   0/1 = basic   2 = info   3 = debug (auth + sec-mod IPC)
#   4 = http      8 = sensitive (request bodies)   9 = TLS
# We default to 3 when RADIUS is on so any RADIUS / sec-mod / worker
# failures (the most common diagnosis target) are visible. Set
# OCSERV_LOG_LEVEL=1 in .env once auth works to silence the noise.
if [ "$RADIUS_ENABLED" = "true" ]; then
    : "${OCSERV_LOG_LEVEL:=3}"
else
    : "${OCSERV_LOG_LEVEL:=1}"
fi

# In network_mode=host the container shares the host's netns, but the
# embedded Postgres is configured to listen on 127.0.0.1 only. We've seen
# cases where a TCP connect to 127.0.0.1 actually leaves through the host's
# default-route interface (usually due to host-side iptables/SNAT or kernel
# net.ipv4.conf.* policies on the operator's machine), and Postgres then
# rejects the peer with "no pg_hba.conf entry for host <external_ip>".
#
# The simplest, most robust fix — without forcing the operator to debug
# their host firewall — is to bypass TCP entirely by using the Unix socket.
# pgx accepts a directory path in `host=…` and switches to the unix socket
# at <dir>/.s.PGSQL.<port>. We point at /var/run/postgresql, the standard
# Debian/postgres-17 socket directory, which is also where postgres-init.sh
# tells the daemon to bind.
#
# We only override a default-looking value; if the operator explicitly set
# POSTGRES_HOST to something else (a remote DB?), we trust them.
if [ "$POSTGRES_HOST" = "127.0.0.1" ] || [ "$POSTGRES_HOST" = "localhost" ]; then
    POSTGRES_HOST="/var/run/postgresql"
    log "POSTGRES_HOST rewritten to Unix socket $POSTGRES_HOST (avoids host-network TCP routing quirks)"
fi
: "${LANGUAGES:=en:English,ru:Русский}"
: "${ALLOW_ORIGINS:=https://${HOST}:3443,http://${HOST}:3080}"
: "${TZ:=UTC}"
: "${SKIP_NAT:=false}"

# Internal service ports — bumped into the 1xxxx range to minimise the chance
# of clashing with something else listening on the host (because we run with
# network_mode=host, 127.0.0.1:8080 etc. would be the host's loopback). Each
# is overridable via .env if you need a specific value.
: "${API_PORT:=18080}"
: "${LOG_STREAM_PORT:=18081}"
: "${WEBHOOK_PORT:=18888}"
: "${NGINX_HTTP_PORT:=3080}"
: "${NGINX_HTTPS_PORT:=3443}"

# Make all the above visible to child processes.
export SECRET_KEY JWT_SECRET HOST OCSERV_PORT OCSERV_TCP_PORT OCSERV_UDP_PORT OC_NO_UDP \
       OC_NET OCSERV_DNS OC_ROUTES \
       OC_SPLIT_DNS OC_TUNNEL_ALL_DNS OC_LISTEN_PROXY_PROTO OC_CAMOUFLAGE \
       SSL_CN SSL_ORG SSL_EXPIRE CERTBOT_ENABLED CERTBOT_EMAIL CERTBOT_HTTP_PORT \
       RADIUS_ENABLED POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER \
       POSTGRES_PASSWORD POSTGRES_SSLMODE LANGUAGES ALLOW_ORIGINS TZ SKIP_NAT \
       API_PORT LOG_STREAM_PORT WEBHOOK_PORT NGINX_HTTP_PORT NGINX_HTTPS_PORT

# Apply timezone if provided.
if [ -f "/usr/share/zoneinfo/$TZ" ]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
fi

log "config: HOST=$HOST TCP=$OCSERV_TCP_PORT UDP=$OCSERV_UDP_PORT CERTBOT=$CERTBOT_ENABLED RADIUS=$RADIUS_ENABLED PROXY_PROTO=$OC_LISTEN_PROXY_PROTO"

# -----------------------------------------------------------------------------
# 1b. Re-create log directories AFTER volumes are mounted
# -----------------------------------------------------------------------------
# /var/log is a bind-mounted volume in docker-compose.yml. The image's
# Dockerfile creates /var/log/{supervisor,nginx} during build, but that work
# is invisible at runtime: Docker overlays the host-side directory on top of
# /var/log, hiding everything we put there. On a fresh deploy that host dir
# is empty, so supervisord/nginx fail with "directory does not exist".
# Re-creating here is idempotent and cheap.
mkdir -p /var/log/supervisor /var/log/nginx /var/log/letsencrypt
# nginx-light's default user is www-data; logs need to be writable by it.
chown -R www-data:www-data /var/log/nginx 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. PostgreSQL initialisation (idempotent)
# -----------------------------------------------------------------------------
log "initialising postgres if needed..."
/usr/local/bin/postgres-init.sh

# -----------------------------------------------------------------------------
# 3. ocserv configuration
# -----------------------------------------------------------------------------
mkdir -p /etc/ocserv/defaults /etc/ocserv/groups /etc/ocserv/users
[ -f /etc/ocserv/ocpasswd ]               || touch /etc/ocserv/ocpasswd
[ -f /etc/ocserv/defaults/group.conf ]    || touch /etc/ocserv/defaults/group.conf

# --- Auth method block — RADIUS or local plain auth ---
AUTH_BLOCK='auth = "plain[passwd=/etc/ocserv/ocpasswd]"'
# Default: per-user/per-group config files are referenced. With RADIUS we
# COMMENT OUT these lines: ocserv 1.4.x in radius mode tries to look up
# per-user files by username under /etc/ocserv/users/, fails on missing
# files and exits with an error during startup. The user reported this
# explicitly. Authoritative user/group attributes come from RADIUS replies
# instead, so the local lookups are not just unnecessary but actively
# harmful here.
PER_USER_GROUP_BLOCK="config-per-group = /etc/ocserv/groups/
config-per-user  = /etc/ocserv/users/"

if [ "$RADIUS_ENABLED" = "true" ]; then
    [ -n "${RADIUS_SERVER:-}" ] || fail "RADIUS_ENABLED=true but RADIUS_SERVER is not set"
    [ -n "${RADIUS_SECRET:-}" ] || fail "RADIUS_ENABLED=true but RADIUS_SECRET is not set"
    : "${RADIUS_AUTH_PORT:=1812}"
    : "${RADIUS_ACCT_PORT:=1813}"
    : "${RADIUS_NAS_ID:=ocserv-vpn}"

    log "radius: configuring upstream $RADIUS_SERVER:$RADIUS_AUTH_PORT"

    # Why we re-generate radiusclient.conf instead of reusing the package
    # default:
    #
    # The libradcli4 Debian package ships /etc/radcli/radiusclient.conf with
    #     authserver  localhost
    #     acctserver  localhost
    # — directives that override the `servers` file. So even though our
    # /etc/radcli/servers correctly lists 192.168.x.x, radcli silently sends
    # auth requests to 127.0.0.1:1812. Nothing answers, the operator sees
    # "invalid credentials" without any visible error in ocserv.err.log.
    # This was the silent root cause of the previous "auth doesn't work but
    # ocserv has no errors" symptom.
    #
    # We follow the minimal-config pattern from the official ocserv RADIUS
    # recipe (https://docs.openconnect-vpn.net/recipes/ocserv-authentication-radius-radcli/):
    # only the directives ocserv actually consults.
    #
    # CRITICAL detail about `authserver` / `acctserver` and the `servers`
    # file: radcli looks up the shared secret by string-matching the
    # authserver value against the first column of /etc/radcli/servers.
    # This match is LITERAL — "192.168.12.7" does not match "192.168.12.7:1812".
    # The reference config in the official recipe shows the pattern:
    #     authserver  1.2.3.4          (no port)
    #     servers entry: 1.2.3.4 SECRET (no port)
    # radcli then resolves the actual UDP port from /etc/services
    # (radius=1812, radacct=1813), or from a compiled-in default.
    #
    # We follow that pattern unchanged: authserver/acctserver carry only
    # the host, and the servers file uses the same bare host as the key.
    # The RADIUS_AUTH_PORT / RADIUS_ACCT_PORT env vars are honoured only
    # if they DIFFER from defaults — in that case we tack the :port onto
    # both lines so they still match.
    [ -f /etc/radcli/dictionary ] || \
        fail "/etc/radcli/dictionary missing — libradcli4 package not installed correctly"

    AUTH_HOST="${RADIUS_SERVER}"
    ACCT_HOST="${RADIUS_SERVER}"
    if [ "${RADIUS_AUTH_PORT}" != "1812" ]; then
        AUTH_HOST="${RADIUS_SERVER}:${RADIUS_AUTH_PORT}"
    fi
    if [ "${RADIUS_ACCT_PORT}" != "1813" ]; then
        ACCT_HOST="${RADIUS_SERVER}:${RADIUS_ACCT_PORT}"
    fi

    cat > /etc/radcli/radiusclient.conf <<EOF
# Auto-generated by entrypoint.sh — rebuild the container to change.
# Format reference: https://radcli.github.io/radcli/manual/radiusclient_8conf-example.html
nas-identifier  ${RADIUS_NAS_ID}
authserver      ${AUTH_HOST}
acctserver      ${ACCT_HOST}
servers         /etc/radcli/servers
dictionary      /etc/radcli/dictionary
default_realm
radius_timeout  10
radius_retries  3
bindaddr        *
EOF
    chmod 644 /etc/radcli/radiusclient.conf
    chown root:root /etc/radcli/radiusclient.conf

    # /etc/radcli/servers — first column must be EXACTLY equal to the
    # authserver/acctserver value above. If both ports are 1812/1813 we
    # write a single bare-host entry; if either port is custom, the auth
    # and acct keys may differ and we write both lines.
    {
        echo "# Auto-generated by entrypoint.sh — do not edit"
        echo "${AUTH_HOST}     ${RADIUS_SECRET}"
        if [ "${ACCT_HOST}" != "${AUTH_HOST}" ]; then
            echo "${ACCT_HOST}     ${RADIUS_SECRET}"
        fi
    } > /etc/radcli/servers
    chmod 600 /etc/radcli/servers
    chown root:root /etc/radcli/servers

    # Dump the effective RADIUS config to the entrypoint log so support
    # tickets can include it without needing an interactive shell into the
    # container. The shared secret is masked.
    log "==== effective RADIUS config ===="
    log "  /etc/radcli/radiusclient.conf:"
    sed 's/^/    /' /etc/radcli/radiusclient.conf | while IFS= read -r line; do log "$line"; done
    log "  /etc/radcli/servers (secrets masked):"
    sed -E 's/(^[^#[:space:]]+[[:space:]]+).+$/\1<SECRET>/' /etc/radcli/servers | \
        sed 's/^/    /' | while IFS= read -r line; do log "$line"; done
    log "==============================="

    AUTH_BLOCK="auth = \"radius[config=/etc/radcli/radiusclient.conf,nas-identifier=${RADIUS_NAS_ID}]\""
    PER_USER_GROUP_BLOCK="# config-per-group / config-per-user disabled in RADIUS mode
# (ocserv aborts on startup when these are set without per-user files)
# config-per-group = /etc/ocserv/groups/
# config-per-user  = /etc/ocserv/users/"
fi

# --- Routes pushed to clients ---
ROUTES_BLOCK=""
if [ -n "$OC_ROUTES" ]; then
    IFS=',' read -ra _routes <<< "$OC_ROUTES"
    for r in "${_routes[@]}"; do
        r="$(echo "$r" | xargs)"
        [ -z "$r" ] && continue
        ROUTES_BLOCK="${ROUTES_BLOCK}route = ${r}
"
    done
fi

# --- Split-DNS domains ---
# The domains over which the provided DNS should be used. Setting any value
# auto-disables tunnel-all-dns unless the user explicitly set OC_TUNNEL_ALL_DNS.
SPLIT_DNS_BLOCK=""
if [ -n "$OC_SPLIT_DNS" ]; then
    IFS=',' read -ra _domains <<< "$OC_SPLIT_DNS"
    for d in "${_domains[@]}"; do
        d="$(echo "$d" | xargs)"
        [ -z "$d" ] && continue
        SPLIT_DNS_BLOCK="${SPLIT_DNS_BLOCK}split-dns = ${d}
"
    done
fi

# --- tunnel-all-dns decision ---
# Explicit env overrides everything. Otherwise: split-dns set => false, else true.
if [ -n "$OC_TUNNEL_ALL_DNS" ]; then
    TUNNEL_ALL_DNS_VALUE="$OC_TUNNEL_ALL_DNS"
elif [ -n "$OC_SPLIT_DNS" ]; then
    TUNNEL_ALL_DNS_VALUE="false"
else
    TUNNEL_ALL_DNS_VALUE="true"
fi

# --- Camouflage block ---
# Empty OC_CAMOUFLAGE => disabled. An empty secret would let everyone through
# the camouflage check, defeating its purpose entirely.
CAMOUFLAGE_BLOCK="camouflage = false"
if [ -n "$OC_CAMOUFLAGE" ]; then
    CAMOUFLAGE_BLOCK="camouflage = true
camouflage_secret = \"${OC_CAMOUFLAGE}\"
camouflage_realm = \"Restricted Content\""
fi

# --- Pre-create /run/ocserv for the IPC sockets ocserv-main <-> sec-mod <-> workers ---
# /var/run is symlink to /run on Debian. /run itself is tmpfs and writeable.
# Cleaning stale .pid / sockets from previous runs is critical: when
# isolate-workers=true the workers fork+exec under random suffixes
# (ocserv-socket.<hex>) and a leftover socket from a previous instance
# with the same hash makes the new worker fail to connect with the exact
# error we saw: "error connecting to sec-mod socket: No such file".
mkdir -p /run/ocserv
chmod 0755 /run/ocserv
# Clean only files we own (don't nuke things like /run/postgresql).
rm -f /run/ocserv/ocserv-socket* /run/ocserv/ocserv.pid 2>/dev/null || true

# --- UDP / DTLS listener ---
# no-udp disables DTLS server-wide; otherwise we advertise udp-port.
if [ "$OC_NO_UDP" = "true" ]; then
    UDP_PORT_BLOCK="no-udp = true"
    log "DTLS disabled (OC_NO_UDP=true) — all traffic will use TCP"
else
    UDP_PORT_BLOCK="udp-port = ${OCSERV_UDP_PORT}"
    if [ "$OCSERV_UDP_PORT" != "$OCSERV_TCP_PORT" ]; then
        log "listeners split: TCP=${OCSERV_TCP_PORT} UDP=${OCSERV_UDP_PORT} (make sure UDP ${OCSERV_UDP_PORT} reaches this host directly — TCP load balancers do not forward UDP)"
    fi
fi

# --- listen-proxy-proto ---
PROXY_PROTO_BLOCK="# listen-proxy-proto disabled"
if [ "$OC_LISTEN_PROXY_PROTO" = "true" ]; then
    PROXY_PROTO_BLOCK="listen-proxy-proto = true"
fi

# Cert paths inside the container — always under /opt/certs.
CERT_DIR="/opt/certs/live/${SSL_CN}"
SERVER_CERT="${CERT_DIR}/fullchain.pem"
SERVER_KEY="${CERT_DIR}/privkey.pem"

log "writing /etc/ocserv/ocserv.conf"
cat > /etc/ocserv/ocserv.conf <<EOT
# =====================================================================
# Managed by itc_ocserv-dashboard entrypoint. Manual edits will be
# overwritten on next container start. Use group/user configs in
# /etc/ocserv/{groups,users} for per-tenant overrides instead.
#
# Built for ocserv >= 1.4.2: uses ban-time (renamed from min-reauth-time
# in 1.4.1).
# =====================================================================

${AUTH_BLOCK}

tcp-port = ${OCSERV_TCP_PORT}
${UDP_PORT_BLOCK}

${PROXY_PROTO_BLOCK}

run-as-user = root
run-as-group = root
# socket-file: ocserv uses this to communicate between the main process,
# the security module (sec-mod), and per-client workers. We point it at
# /run (tmpfs in modern Debian) to ensure the directory:
#   (a) is always writable by the ocserv process,
#   (b) is NOT shadowed by any docker volume,
#   (c) survives the entrypoint deleting stale state on every start.
# A misconfigured socket-file path manifests as
# "error connecting to sec-mod socket '/path/.<hash>': No such file or
# directory" in ocserv.err.log, with workers immediately closing TCP
# connections — a confusing failure mode that looks like a network or
# auth issue but is really IPC.
socket-file = /run/ocserv/ocserv-socket
isolate-workers = true
use-occtl = true
pid-file = /run/ocserv/ocserv.pid

server-cert = ${SERVER_CERT}
server-key  = ${SERVER_KEY}

max-clients = 1024
max-same-clients = 4
keepalive = 32400
dpd = 90
mobile-dpd = 1800
switch-to-tcp-timeout = 5
try-mtu-discovery = true
auth-timeout = 40
ban-time = 300
max-ban-score = 80
ban-reset-time = 300
cookie-timeout = 86400
deny-roaming = false
rekey-time = 172800
rekey-method = ssl

tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-RSA:-VERS-SSL3.0:-ARCFOUR-128"

device = vpns
predictable-ips = true
ipv4-network = ${OC_NET}
tunnel-all-dns = ${TUNNEL_ALL_DNS_VALUE}
dns = ${OCSERV_DNS}
${SPLIT_DNS_BLOCK}
ping-leases = false
mtu = 1420
log-level = ${OCSERV_LOG_LEVEL}

cisco-client-compat = true
dtls-legacy = true

${PER_USER_GROUP_BLOCK}

${ROUTES_BLOCK}

${CAMOUFLAGE_BLOCK}
EOT

# -----------------------------------------------------------------------------
# 4. TLS certificates
# -----------------------------------------------------------------------------
# /opt/certs is typically mounted read-only when CERTBOT_ENABLED=false (the
# common "BYO certs from host certbot" path). In that case we must NOT try
# to mkdir or write anything under /opt/certs — even an mkdir on an existing
# dir fails with EROFS. So:
#   - CERTBOT_ENABLED=true  → we own this volume, must be mounted rw, mkdir OK.
#   - CERTBOT_ENABLED=false → we expect certs already present at $CERT_DIR.
#                             Read-only mount is fine; we just verify and exit.
#   - Self-signed fallback → only triggers when CERTBOT_ENABLED=false AND certs
#                             are missing. Requires writable /opt/certs;
#                             surfaced as a clear error if it isn't.
if [ "$CERTBOT_ENABLED" = "true" ]; then
    # certbot mode requires writable /opt/certs. mkdir -p is idempotent.
    if ! mkdir -p "$CERT_DIR" 2>/dev/null; then
        fail "/opt/certs is read-only but CERTBOT_ENABLED=true. Either remove ':ro' from the /opt/certs mount in docker-compose.yml, or set CERTBOT_ENABLED=false in .env."
    fi
fi

if [ ! -f "$SERVER_CERT" ] || [ ! -f "$SERVER_KEY" ]; then
    if [ "$CERTBOT_ENABLED" = "true" ]; then
        [ -n "$CERTBOT_EMAIL" ] || fail "CERTBOT_ENABLED=true but CERTBOT_EMAIL is empty"
        log "certbot: requesting cert for $SSL_CN (standalone, HTTP-01 on port $CERTBOT_HTTP_PORT)"
        certbot certonly --standalone --non-interactive --agree-tos \
            --http-01-port "$CERTBOT_HTTP_PORT" \
            --email "$CERTBOT_EMAIL" -d "$SSL_CN" \
            --config-dir /opt/certs --work-dir /var/lib/letsencrypt \
            --logs-dir /var/log/letsencrypt \
            || fail "certbot failed. Check that http://${SSL_CN}/.well-known/acme-challenge/ reaches port ${CERTBOT_HTTP_PORT} on this host (directly, or forwarded by your reverse proxy)."
    else
        # CERTBOT_ENABLED=false and certs are missing. Try the self-signed
        # fallback, but only if /opt/certs is actually writable — otherwise
        # we give the operator a clear, actionable error.
        if ! mkdir -p "$CERT_DIR" 2>/dev/null; then
            fail "no certs found at $CERT_DIR and /opt/certs is read-only. Either provide fullchain.pem/privkey.pem there from your host certbot, or remove ':ro' to allow self-signed fallback."
        fi
        warn "no cert at $SERVER_CERT — generating a self-signed pair (NOT for production)"
        certtool --generate-privkey --outfile "$CERT_DIR/privkey.pem" 2>/dev/null
        cat > /tmp/cert.tmpl <<EOF
cn = "${SSL_CN}"
organization = "${SSL_ORG}"
expiration_days = ${SSL_EXPIRE}
signing_key
encryption_key
tls_www_server
EOF
        certtool --generate-self-signed \
            --load-privkey "$CERT_DIR/privkey.pem" \
            --template /tmp/cert.tmpl \
            --outfile "$CERT_DIR/fullchain.pem" 2>/dev/null
        rm -f /tmp/cert.tmpl
    fi
fi

# -----------------------------------------------------------------------------
# 5. nginx configuration (envsubst on template)
# -----------------------------------------------------------------------------
log "rendering nginx config"
export NGINX_SERVER_CERT="$SERVER_CERT"
export NGINX_SERVER_KEY="$SERVER_KEY"
envsubst '${NGINX_SERVER_CERT} ${NGINX_SERVER_KEY} ${API_PORT} ${LOG_STREAM_PORT} ${NGINX_HTTP_PORT} ${NGINX_HTTPS_PORT}' \
    < /etc/nginx/nginx.conf.tmpl > /etc/nginx/nginx.conf

# Don't fail the container on nginx -t; supervisord will surface real errors.
nginx -t || warn "nginx -t reported errors; check /var/log/supervisor/nginx.err.log after start"

# -----------------------------------------------------------------------------
# 6. Networking — TUN + IP forwarding + NAT
# -----------------------------------------------------------------------------
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200 || true
fi
chmod 600 /dev/net/tun || true

# IP forwarding. With network_mode=host this affects the host's sysctl —
# usually fine on a server hosting only this VPN. With NET_ADMIN cap and
# without privileged mode, this works.
if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
    # Expected under network_mode: host — the sysctl belongs to the host's
    # network namespace and the container is not allowed to change it.
    # What matters is the effective value, so check that instead of assuming
    # failure means forwarding is off.
    IPFWD="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"
    if [ "$IPFWD" = "1" ]; then
        log "ip_forward already enabled on the host — nothing to do"
    else
        warn "ip_forward is $IPFWD and cannot be set from inside a host-network container."
        warn "VPN clients will NOT be able to route anywhere. Run this on the HOST:"
        warn "    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-ocserv.conf && sysctl --system"
    fi
fi

if [ "$SKIP_NAT" = "true" ]; then
    log "SKIP_NAT=true — leaving host iptables alone"
else
    ETH=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
    ETH=${ETH:-eth0}
    log "outbound interface: $ETH (set SKIP_NAT=true to manage iptables yourself)"

    if ! iptables -t nat -C POSTROUTING -s "$OC_NET" -o "$ETH" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$OC_NET" -o "$ETH" -j MASQUERADE || \
            warn "could not install NAT rule (need NET_ADMIN cap)"
    fi
    if ! iptables -C FORWARD -s "$OC_NET" -o "$ETH" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -s "$OC_NET" -o "$ETH" -j ACCEPT || true
    fi
    if ! iptables -C FORWARD -d "$OC_NET" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -d "$OC_NET" -m state --state ESTABLISHED,RELATED -j ACCEPT || true
    fi
    if ! iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true
    fi
fi

# -----------------------------------------------------------------------------
# 7. Hand off to supervisord
# -----------------------------------------------------------------------------
log "starting supervisord"
exec "$@"
