#!/bin/bash
set -e

# Defaults
DOMAIN="oc.example.com"
EMAIL="admin@itconsvl.com"
CERT_PATH="/opt/certs"
OC_NET="172.16.24.0/24"
OCSERV_DNS="192.168.200.254"
OC_ROUTE="192.168.200.0/255.255.255.0"
OC_CAMOUFLAGE="someword"
CONTAINER_NAME="ocserv"

read -rp "Enter container_name [$CONTAINER_NAME]: " input_name
    CONTAINER_NAME=${input_name:-$CONTAINER_NAME}

read -rp "Enter subnet [$OC_NET]: " input_subnet
    OC_NET=${input_subnet:-$OC_NET}

read -rp "Enter VPN dns server [$OCSERV_DNS]: " input_dns
    OCSERV_DNS=${input_dns:-$OCSERV_DNS}

read -rp "Enter routes to be forwarded to the client [$OC_ROUTE]: " input_route
    OC_ROUTE=${input_route:-$OC_ROUTE}

read -rp "Enter camouflage_secret. The URL prefix that should be set on the client (after ? sign) to pass through the camouflage check. e.g. URL should be like https://example.com/?mysecretkey. [$OC_CAMOUFLAGE]: " input_secret
    OC_CAMOUFLAGE=${input_secret:-$OC_CAMOUFLAGE}

print_info() { echo -e "\e[34m[INFO] $1\e[0m"; }
print_warn() { echo -e "\e[33m[WARN] $1\e[0m"; }

# 1. SSL Selection
echo "========================================="
echo " SSL Certificate Configuration"
echo "========================================="
echo "1) Use existing certificates (Mount folder)"
echo "2) Use Certbot (Generate Let's Encrypt certs via sidecar)"
read -rp "Select option [1-2]: " ssl_choice

if [ "$ssl_choice" = "2" ]; then
    read -rp "Enter Domain [$DOMAIN]: " input_domain
    DOMAIN=${input_domain:-$DOMAIN}
    read -rp "Enter Email [$EMAIL]: " input_email
    EMAIL=${input_email:-$EMAIL}

    # Path where certbot will save files. We will mount this to /opt/certs in the main container
    # Certbot saves to /etc/letsencrypt/live/$DOMAIN/
    # We need a trick to map it uniformly to /opt/certs/fullchain.pem inside the container.
    # The simplest way for this script is to let Certbot manage /etc/letsencrypt/archive 
    # and map the specific domain folder to the container.

    CERT_VOLUME_SRC="/opt/certs/live/$DOMAIN"
    print_info "Certbot selected. Certificates will be in /opt/certs/live/$DOMAIN"
else
    read -rp "Enter absolute path to certificates folder [$CERT_PATH]: " input_path
    CERT_PATH=${input_path:-$CERT_PATH}
    read -rp "Enter Domain [$DOMAIN]: " input_domain
    DOMAIN=${input_domain:-$DOMAIN}

    # Check for files
    if [ ! -f "$CERT_PATH/live/$DOMAIN/fullchain.pem" ] || [ ! -f "$CERT_PATH/live/$DOMAIN/privkey.pem" ]; then
        print_warn "Files fullchain.pem or privkey.pem not found in $CERT_PATH."
        print_warn "Please ensure they exist and are named exactly so."
    fi
    CERT_VOLUME_SRC="$CERT_PATH/live/$DOMAIN"
fi

# 2. Generate Secret Keys
#SECRET_KEY=$(openssl rand -hex 32)
#JWT_SECRET=$(openssl rand -hex 32)

# 2. Generate Secret Keys (preserve existing keys if .env exists)
SECRET_KEY=""
JWT_SECRET=""

# Check if SECRET_KEY and JWT_SECRET exists in .env
if [ -f ".env" ]; then
    EXISTING_SECRET_KEY=$(grep -E "^SECRET_KEY=" .env 2>/dev/null | cut -d'=' -f2-)
    EXISTING_JWT_SECRET=$(grep -E "^JWT_SECRET=" .env 2>/dev/null | cut -d'=' -f2-)

    if [ -n "$EXISTING_SECRET_KEY" ]; then
        SECRET_KEY="$EXISTING_SECRET_KEY"
        echo "[INFO] Using existing SECRET_KEY from .env"
    fi

    if [ -n "$EXISTING_JWT_SECRET" ]; then
        JWT_SECRET="$EXISTING_JWT_SECRET"
        echo "[INFO] Using existing JWT_SECRET from .env"
    fi
fi

# Generate new keys if they don't exist
if [ -z "$SECRET_KEY" ]; then
    SECRET_KEY=$(openssl rand -hex 32 2>/dev/null || echo "fallback_secret_$(date +%s)_$$")
    echo "[INFO] Generated new SECRET_KEY"
fi

if [ -z "$JWT_SECRET" ]; then
    JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "fallback_jwt_$(date +%s)_$$")
    echo "[INFO] Generated new JWT_SECRET"
fi

# 3. Create .env
cat > .env <<EOL
SECRET_KEY=${SECRET_KEY}
JWT_SECRET=${JWT_SECRET}
OC_NET=${OC_NET}
OCSERV_DNS=${OCSERV_DNS}
OC_ROUTE=${OC_ROUTE}
OC_CAMOUFLAGE=${OC_CAMOUFLAGE}
SSL_CN=${DOMAIN}
CERT_VOLUME_SRC=${CERT_VOLUME_SRC}
# Supported languages (format: code:Name, comma-separated)
LANGUAGES=en:English,zh:中文,ru:Русский,fa:فارسی,ar:العربية
ALLOW_ORIGINS=https://${DOMAIN}:3443,https://${DOMAIN}:3080
EOL

# 4. Generate docker-compose.yml
cat > docker-compose.yml <<EOL
services:
  ocserv:
    build: .
    image: itc_ocserv:latest
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    privileged: true
    ports:
      - "443:443/tcp"
      - "443:443/udp"
      - "3080:3080/tcp"
      - "3443:3443/tcp"
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.ip_forward=1
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./data/ocserv:/etc/ocserv
      - ./data/db:/app/db
      # Mount SSL. Inside container expects /opt/certs/fullchain.pem and privkey.pem
      - ${CERT_PATH}:/opt/certs:ro
      - ./data/logs:/var/log
      - ./data/nginx:/etc/nginx/sites-available
    environment:
      - TZ=Asia/Vladivostok
    env_file:
      - .env
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOL

# 5. Add Certbot Service if selected
if [ "$ssl_choice" = "2" ]; then
    cat >> docker-compose.yml <<EOL
  certbot:
    image: certbot/certbot
    container_name: certbot
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - /opt/certs:/opt/certs
      - ./data/webroot:/var/www/certbot
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew --config-dir /opt/certs --work-dir /opt/certs/work --logs-dir /opt/certs/logs; sleep 12h & wait \$\!; done;'"
    command: certonly --standalone --config-dir /opt/certs --work-dir /opt/certs/work --logs-dir /opt/certs/logs --email ${EMAIL} -d ${DOMAIN} --agree-tos --non-interactive
EOL
fi

BLUE='\033[1;34m'
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() {
    printf "%b[INFO]%b %b%s%b\n" "$BLUE" "$NC" "$GREEN" "$1" "$NC"
}
    
print_success() {
    printf "%b[SUCCESS]%b %b%s%b\n" "$BLUE" "$NC" "$GREEN" "$1" "$NC"
}

print_warning() {
    printf "%b[WARNING]%b %b%s%b\n" "$YELLOW" "$NC" "$GREEN" "$1" "$NC"
}

print_error() {
    printf "%b[ERROR]%b %b%s%b\n" "$RED" "$NC" "$GREEN" "$1" "$NC"
}

print_info "Configuration generated."

print_info "Building and starting container..."

if ! docker compose up -d --build; then
    print_error "Failed to build/start container. Aborting cache cleanup."
fi

if docker compose ps -q $CONTAINER_NAME >/dev/null 2>&1 && \
   [ "$(docker inspect -f '{{.State.Status}}' ocserv 2>/dev/null)" = "running" ]; then

    print_info "Container running successfully. Cleaning up build cache..."
    CLEANUP_OUTPUT=$(docker builder prune -f --filter "until=1h" 2>&1)
    RECLAIMED=$(echo "$CLEANUP_OUTPUT" | grep -oP "Total reclaimed space: \K.*" || echo "0B")
    print_info "Build cache cleaned. Reclaimed: $RECLAIMED"
    print_info "Setup completed! Access panel at: https://${DOMAIN}:3443"
    print_info "Save the SECRET_KEY and JWT_SECRET from the .env file; otherwise, you will lose access to the control panel after rebuilding the container."
else
    print_error "[ERROR] Container failed to start. Skipping cache cleanup."
    exit 1
fi

