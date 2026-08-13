#!/bin/bash
# =============================================================================
# install.sh — interactive setup for itc_ocserv-dashboard
# =============================================================================
# Behaviour:
#   - If a .env already exists, asks whether to keep it as-is, edit only
#     missing keys, or regenerate from scratch.
#   - In "regenerate" mode, generates strong random secrets and walks the
#     operator through every option.
#   - In "fill-missing" mode, only prompts for keys not already present in
#     the existing .env.
#   - In "keep" mode, validates that all required keys are present and
#     proceeds straight to build/up.
#
# All modes leave a backup at .env.<timestamp>.bak whenever the file is
# rewritten.
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$REPO_DIR/.env"

c_ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_info() { printf '\033[1;34m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }

ask() {
    local prompt="$1" default="${2:-}" reply
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " reply || true
        printf '%s' "${reply:-$default}"
    else
        read -r -p "$prompt: " reply || true
        printf '%s' "$reply"
    fi
}

ask_yn() {
    local prompt="$1" default="${2:-n}" reply def_label
    case "$default" in
        y|Y|yes|YES|true) def_label="Y/n" ;;
        *)                def_label="y/N" ;;
    esac
    while :; do
        read -r -p "$prompt [$def_label]: " reply || true
        reply="${reply:-$default}"
        case "$reply" in
            y|Y|yes|YES|true)  printf 'true';  return 0 ;;
            n|N|no|NO|false|"") printf 'false'; return 0 ;;
        esac
    done
}

random_secret() {
    head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32
}

# Returns the value of $1 from $ENV_FILE, or empty if missing/file absent.
env_get() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return 0
    # Match "KEY=value" with optional surrounding whitespace.
    sed -n "s/^[[:space:]]*${key}=//p" "$ENV_FILE" | head -n 1
}

# Returns the env value if present, otherwise interactively asks with the
# given default. In "fill-missing" mode this avoids re-prompting for every
# key the user already configured.
env_or_ask() {
    local key="$1" prompt="$2" default="${3:-}"
    local existing
    existing="$(env_get "$key")"
    if [ -n "$existing" ] && [ "$MODE" = "fill" ]; then
        printf '%s' "$existing"
        return 0
    fi
    # In "regenerate" mode, surface the existing value as the default so the
    # user can confirm with Enter.
    if [ -n "$existing" ] && [ -z "$default" ]; then
        default="$existing"
    fi
    ask "$prompt" "$default"
}

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    c_warn "Not running as root. Docker commands will use sudo where needed."
fi

if ! command -v docker >/dev/null 2>&1; then
    c_err "docker is not installed. Install Docker Engine first: https://docs.docker.com/engine/install/"
    exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
    c_err "Docker Compose v2 plugin not found. Install docker-compose-plugin."
    exit 1
fi

# -----------------------------------------------------------------------------
# Mode selection
# -----------------------------------------------------------------------------
MODE="regenerate"
if [ -f "$ENV_FILE" ]; then
    c_info "Existing .env detected at $ENV_FILE"
    echo "  1) Keep as-is — only validate and proceed to build/up"
    echo "  2) Fill missing keys only — keep existing values, ask for new ones"
    echo "  3) Regenerate from scratch (existing file backed up)"
    EXISTING_CHOICE="$(ask 'Choice' '2')"
    case "$EXISTING_CHOICE" in
        1) MODE="keep"      ;;
        2) MODE="fill"      ;;
        3) MODE="regenerate" ;;
        *) c_err "Invalid choice"; exit 1 ;;
    esac
fi

# -----------------------------------------------------------------------------
# Backup existing .env if we'll be writing
# -----------------------------------------------------------------------------
if [ -f "$ENV_FILE" ] && [ "$MODE" != "keep" ]; then
    BACKUP="$ENV_FILE.$(date +%Y%m%d_%H%M%S).bak"
    cp "$ENV_FILE" "$BACKUP"
    c_warn "Backed up existing .env to $(basename "$BACKUP")"
fi

# -----------------------------------------------------------------------------
# "Keep" mode: validate the existing file then jump to build/up
# -----------------------------------------------------------------------------
if [ "$MODE" = "keep" ]; then
    REQUIRED=(SECRET_KEY JWT_SECRET POSTGRES_PASSWORD HOST OC_NET)
    MISSING=()
    for k in "${REQUIRED[@]}"; do
        v="$(env_get "$k")"
        [ -z "$v" ] && MISSING+=("$k")
    done
    if [ ${#MISSING[@]} -gt 0 ]; then
        c_err "Existing .env is missing required keys: ${MISSING[*]}"
        c_err "Re-run install.sh and choose option 2 (fill missing) or 3 (regenerate)."
        exit 1
    fi
    c_ok ".env validation passed."
else
    # ---------------------------------------------------------------------
    # Interactive questions (regenerate or fill modes)
    # ---------------------------------------------------------------------
    c_info "=== itc_ocserv-dashboard installer ==="
    echo
    if [ "$MODE" = "fill" ]; then
        echo "Mode: fill missing keys only. Pre-existing values are kept."
    elif [ -f "$ENV_FILE" ] || [ -n "${BACKUP:-}" ]; then
        echo "Mode: regenerate. Existing values shown as defaults — press Enter to keep."
    else
        echo "Fresh install — no .env found. Press Enter to accept the suggested"
        echo "default shown in [brackets], or type your own value."
    fi
    echo

    HOST="$(env_or_ask 'HOST'         'Public hostname or IP'        'oc.example.com')"
    OCSERV_PORT="$(env_or_ask 'OCSERV_PORT' 'Ocserv port (TCP+UDP)'   '443')"

    echo
    echo "Is a TCP-only load balancer (HAProxy, nginx stream, AWS NLB) in front"
    echo "of this server? Those cannot forward UDP, so DTLS has to reach this"
    echo "host directly and the TCP listener usually moves to another port."
    EXIST_TCP_PORT="$(env_get OCSERV_TCP_PORT)"
    EXIST_UDP_PORT="$(env_get OCSERV_UDP_PORT)"
    if [ "$MODE" = "fill" ] && [ -n "$EXIST_TCP_PORT" ]; then
        OCSERV_TCP_PORT="$EXIST_TCP_PORT"
        OCSERV_UDP_PORT="${EXIST_UDP_PORT:-$OCSERV_PORT}"
        echo "Keeping OCSERV_TCP_PORT=$OCSERV_TCP_PORT / OCSERV_UDP_PORT=$OCSERV_UDP_PORT from existing .env."
    else
        SPLIT_DEFAULT="n"
        [ -n "$EXIST_TCP_PORT" ] && [ "$EXIST_TCP_PORT" != "$OCSERV_PORT" ] && SPLIT_DEFAULT="y"
        SPLIT_PORTS="$(ask_yn 'Use separate TCP and UDP ports?' "$SPLIT_DEFAULT")"
        if [ "$SPLIT_PORTS" = "true" ]; then
            OCSERV_TCP_PORT="$(env_or_ask 'OCSERV_TCP_PORT' 'TCP port (load balancer forwards here)' '8443')"
            OCSERV_UDP_PORT="$(env_or_ask 'OCSERV_UDP_PORT' 'UDP/DTLS port (must reach this host directly)' "$OCSERV_PORT")"
            echo
            c_warn "Remember: forward UDP $OCSERV_UDP_PORT straight to this host, bypassing the load balancer."
            c_warn "Point the load balancer backend at TCP $OCSERV_TCP_PORT (add send-proxy-v2 if using PROXY protocol)."
        else
            OCSERV_TCP_PORT="$OCSERV_PORT"
            OCSERV_UDP_PORT="$OCSERV_PORT"
        fi
    fi

    echo
    echo "DTLS (UDP) gives much better throughput on lossy or mobile links."
    echo "Disable it only if UDP cannot reach this host at all."
    EXIST_NO_UDP="$(env_get OC_NO_UDP)"
    if [ "$MODE" = "fill" ] && [ -n "$EXIST_NO_UDP" ]; then
        OC_NO_UDP="$EXIST_NO_UDP"
    else
        OC_NO_UDP="$(ask_yn 'Disable DTLS entirely (TCP only)?' "${EXIST_NO_UDP:-n}")"
    fi
    OC_NET="$(env_or_ask 'OC_NET'     'VPN client subnet (CIDR)'      '172.16.24.0/24')"
    OCSERV_DNS="$(env_or_ask 'OCSERV_DNS' 'DNS pushed to clients'     '8.8.8.8')"

    echo
    echo "Routes pushed to clients (corporate networks reachable via VPN)."
    echo "Comma-separated. Empty = no extra routes."
    OC_ROUTES="$(env_or_ask 'OC_ROUTES' 'Routes' '192.168.0.0/24')"

    echo
    echo "Split-DNS: domains whose lookups should be forwarded through the VPN's DNS."
    echo "Comma-separated. Empty = no split-DNS (every lookup tunnelled if tunnel-all-dns)."
    OC_SPLIT_DNS="$(env_or_ask 'OC_SPLIT_DNS' 'Split-DNS domains' '')"

    echo
    echo "tunnel-all-dns: forces every client DNS query through the VPN."
    echo "Default behaviour: true if no split-DNS, false if split-DNS is set."
    echo "Leave blank for auto. Type true/false to override."
    OC_TUNNEL_ALL_DNS="$(env_or_ask 'OC_TUNNEL_ALL_DNS' 'OC_TUNNEL_ALL_DNS (blank for auto)' '')"

    echo
    OC_LISTEN_PROXY_PROTO_DEFAULT="$(env_get OC_LISTEN_PROXY_PROTO)"
    [ -z "$OC_LISTEN_PROXY_PROTO_DEFAULT" ] && OC_LISTEN_PROXY_PROTO_DEFAULT="false"
    if [ "$MODE" = "fill" ] && [ -n "$(env_get OC_LISTEN_PROXY_PROTO)" ]; then
        OC_LISTEN_PROXY_PROTO="$(env_get OC_LISTEN_PROXY_PROTO)"
    else
        OC_LISTEN_PROXY_PROTO="$(ask_yn 'Enable HAProxy PROXY protocol on the listener?' "$OC_LISTEN_PROXY_PROTO_DEFAULT")"
    fi

    echo
    OC_CAMOUFLAGE_DEFAULT="$(env_get OC_CAMOUFLAGE)"
    [ -z "$OC_CAMOUFLAGE_DEFAULT" ] && OC_CAMOUFLAGE_DEFAULT="$(random_secret | head -c 16)"
    echo "Camouflage word — clients must connect to https://$HOST/?<word>."
    echo "Empty = camouflage off."
    OC_CAMOUFLAGE="$(env_or_ask 'OC_CAMOUFLAGE' 'Camouflage' "$OC_CAMOUFLAGE_DEFAULT")"

    echo
    c_info "--- TLS certificates ---"
    EXIST_CERTBOT="$(env_get CERTBOT_ENABLED)"
    if [ "$MODE" = "fill" ] && [ -n "$EXIST_CERTBOT" ]; then
        CERTBOT_ENABLED="$EXIST_CERTBOT"
        CERTBOT_EMAIL="$(env_get CERTBOT_EMAIL)"
        echo "Keeping CERTBOT_ENABLED=$CERTBOT_ENABLED from existing .env."
    else
        echo "  1) Container runs certbot itself (port 80 must be reachable)"
        echo "  2) Mount certs from host (centralised certbot)"
        echo "  3) Self-signed (lab/testing)"
        DEFAULT_CHOICE="2"
        [ "$EXIST_CERTBOT" = "true" ] && DEFAULT_CHOICE="1"
        CERT_CHOICE="$(ask 'Choice' "$DEFAULT_CHOICE")"
        CERTBOT_ENABLED="false"
        CERTBOT_EMAIL=""
        case "$CERT_CHOICE" in
            1)
                CERTBOT_ENABLED="true"
                CERTBOT_EMAIL="$(env_or_ask 'CERTBOT_EMAIL' 'Email for Let'"'"'s Encrypt' '')"
                [ -n "$CERTBOT_EMAIL" ] || { c_err "Email is required for certbot"; exit 1; }
                ;;
            2) echo "Expecting /opt/certs/live/$HOST/{fullchain,privkey}.pem on the host." ;;
            3) c_warn "Self-signed certs will be generated automatically — not for production." ;;
            *) c_err "Invalid choice"; exit 1 ;;
        esac
    fi

    echo
    c_info "--- Authentication ---"
    EXIST_RADIUS="$(env_get RADIUS_ENABLED)"
    if [ "$MODE" = "fill" ] && [ -n "$EXIST_RADIUS" ]; then
        RADIUS_ENABLED="$EXIST_RADIUS"
        RADIUS_SERVER="$(env_get RADIUS_SERVER)"
        RADIUS_AUTH_PORT="$(env_get RADIUS_AUTH_PORT)"
        RADIUS_ACCT_PORT="$(env_get RADIUS_ACCT_PORT)"
        RADIUS_SECRET="$(env_get RADIUS_SECRET)"
        RADIUS_NAS_ID="$(env_get RADIUS_NAS_ID)"
        : "${RADIUS_AUTH_PORT:=1812}" "${RADIUS_ACCT_PORT:=1813}" "${RADIUS_NAS_ID:=ocserv-vpn}"
        echo "Keeping RADIUS_ENABLED=$RADIUS_ENABLED from existing .env."
    else
        RADIUS_ENABLED="$(ask_yn 'Use RADIUS for VPN user authentication?' "${EXIST_RADIUS:-n}")"
        RADIUS_SERVER=""
        RADIUS_AUTH_PORT="1812"
        RADIUS_ACCT_PORT="1813"
        RADIUS_SECRET=""
        RADIUS_NAS_ID="ocserv-vpn"
        if [ "$RADIUS_ENABLED" = "true" ]; then
            RADIUS_SERVER="$(env_or_ask 'RADIUS_SERVER'    'RADIUS server hostname/IP' '')"
            [ -n "$RADIUS_SERVER" ] || { c_err "RADIUS server is required"; exit 1; }
            RADIUS_AUTH_PORT="$(env_or_ask 'RADIUS_AUTH_PORT' 'RADIUS auth port' '1812')"
            RADIUS_ACCT_PORT="$(env_or_ask 'RADIUS_ACCT_PORT' 'RADIUS acct port' '1813')"
            RADIUS_SECRET="$(env_or_ask 'RADIUS_SECRET'    'RADIUS shared secret' '')"
            [ -n "$RADIUS_SECRET" ] || { c_err "RADIUS secret is required"; exit 1; }
            RADIUS_NAS_ID="$(env_or_ask 'RADIUS_NAS_ID'    'RADIUS NAS-Identifier' "$RADIUS_NAS_ID")"
        fi
    fi

    echo
    TZ_VAL="$(env_or_ask 'TZ' 'Container time zone' "${TZ:-Asia/Vladivostok}")"

    # ---------------------------------------------------------------------
    # Secrets — preserve existing values unless regenerating from scratch
    # ---------------------------------------------------------------------
    SECRET_KEY="$(env_get SECRET_KEY)"
    JWT_SECRET="$(env_get JWT_SECRET)"
    POSTGRES_PASSWORD="$(env_get POSTGRES_PASSWORD)"

    if [ "$MODE" = "regenerate" ]; then
        if [ -n "$SECRET_KEY" ]; then
            REGEN_SECRETS="$(ask_yn 'Regenerate SECRET_KEY/JWT_SECRET/POSTGRES_PASSWORD?' 'n')"
        else
            REGEN_SECRETS="true"
        fi
        if [ "$REGEN_SECRETS" = "true" ]; then
            c_info "Generating fresh secrets..."
            SECRET_KEY="$(random_secret)"
            JWT_SECRET="$(random_secret)"
            POSTGRES_PASSWORD="$(random_secret)"
            if [ -d "$REPO_DIR/data/db/postgres" ] && [ "$(ls -A "$REPO_DIR/data/db/postgres" 2>/dev/null)" ]; then
                c_warn "An existing PostgreSQL data directory was found at data/db/postgres."
                c_warn "Rotating POSTGRES_PASSWORD will refresh the role on next start (no data loss)."
            fi
        fi
    else
        # fill mode: generate any missing secret silently
        [ -z "$SECRET_KEY" ]        && { c_info "Generating SECRET_KEY";        SECRET_KEY="$(random_secret)"; }
        [ -z "$JWT_SECRET" ]        && { c_info "Generating JWT_SECRET";        JWT_SECRET="$(random_secret)"; }
        [ -z "$POSTGRES_PASSWORD" ] && { c_info "Generating POSTGRES_PASSWORD"; POSTGRES_PASSWORD="$(random_secret)"; }
    fi

    # ---------------------------------------------------------------------
    # Write .env
    # ---------------------------------------------------------------------
    cat > "$ENV_FILE" <<EOF
# Auto-generated by install.sh on $(date -Iseconds)
# Do NOT commit this file. Re-run install.sh to regenerate or update.

# --- secrets ---
SECRET_KEY=$SECRET_KEY
JWT_SECRET=$JWT_SECRET

# --- server identity ---
HOST=$HOST
OCSERV_PORT=$OCSERV_PORT
OCSERV_TCP_PORT=$OCSERV_TCP_PORT
OCSERV_UDP_PORT=$OCSERV_UDP_PORT
OC_NO_UDP=$OC_NO_UDP

# --- VPN network ---
OC_NET=$OC_NET
OCSERV_DNS=$OCSERV_DNS
OC_ROUTES=$OC_ROUTES
OC_SPLIT_DNS=$OC_SPLIT_DNS
OC_TUNNEL_ALL_DNS=$OC_TUNNEL_ALL_DNS
OC_LISTEN_PROXY_PROTO=$OC_LISTEN_PROXY_PROTO
OC_CAMOUFLAGE=$OC_CAMOUFLAGE

# --- TLS ---
CERTBOT_ENABLED=$CERTBOT_ENABLED
CERTBOT_EMAIL=$CERTBOT_EMAIL
SSL_CN=$HOST
SSL_ORG=itc
SSL_EXPIRE=3650

# --- RADIUS ---
RADIUS_ENABLED=$RADIUS_ENABLED
RADIUS_SERVER=$RADIUS_SERVER
RADIUS_AUTH_PORT=$RADIUS_AUTH_PORT
RADIUS_ACCT_PORT=$RADIUS_ACCT_PORT
RADIUS_SECRET=$RADIUS_SECRET
RADIUS_NAS_ID=$RADIUS_NAS_ID

# --- PostgreSQL (embedded) ---
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
POSTGRES_DB=ocserv_db
POSTGRES_USER=ocserv
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_SSLMODE=disable

# --- Internal service ports (host network mode — bumped to 1xxxx range) ---
API_PORT=18080
LOG_STREAM_PORT=18081
WEBHOOK_PORT=18888
NGINX_HTTP_PORT=3080
NGINX_HTTPS_PORT=3443

# --- Networking ---
# Set SKIP_NAT=true if you manage host iptables/MASQUERADE for $OC_NET externally.
SKIP_NAT=false

# --- Frontend / API ---
LANGUAGES=en:English,ru:Русский
ALLOW_ORIGINS=https://$HOST:3443,http://$HOST:3080
TZ=$TZ_VAL
EOF

    chmod 600 "$ENV_FILE"
    c_ok ".env written to $ENV_FILE (mode 600)"
fi

# -----------------------------------------------------------------------------
# Final prompt — build & start
# -----------------------------------------------------------------------------
echo
c_info "Setup complete. Next steps:"
echo "  docker compose build && docker compose up -d"
echo "  open https://$(env_get HOST):$(env_get NGINX_HTTPS_PORT 2>/dev/null)"
echo
RUN_NOW="$(ask_yn 'Run docker compose up -d now?' 'y')"
if [ "$RUN_NOW" = "true" ]; then
    cd "$REPO_DIR"
    docker compose build
    docker compose up -d
    c_ok "Stack started. Logs: docker compose logs -f"
fi
