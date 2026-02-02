# ================================
# Stage 1: Build Frontend (Vue)
# ================================
FROM node:20 AS vue-builder
ARG LANGUAGES="en:English,ru:Русский"
WORKDIR /app
COPY web/package*.json web/yarn.lock ./
RUN yarn install
COPY ./web .
# We specify relative paths for the API, since everything now runs on the same port/domain via Nginx.
RUN NODE_ENV=production VITE_I18N_LANGUAGES="${LANGUAGES}" yarn run build

# ================================
# Stage 2: Build Backend (Go Services)
# ================================
FROM golang:1.25.0 AS go-builder
ENV CGO_ENABLED=1 GOOS=linux GOARCH=amd64
WORKDIR /src

# Copy module manifests first
COPY services/go.work .
COPY services/go.work.sum .
COPY services/api/go.mod services/api/go.sum ./api/
COPY services/common/go.mod services/common/go.sum ./common/
COPY services/log_stream/go.mod services/log_stream/go.sum ./log_stream/
COPY services/user_expiry/go.mod services/user_expiry/go.sum ./user_expiry/
COPY services/webhook/go.mod services/webhook/go.sum ./webhook/

RUN go mod download

# Copy source
COPY services/ ./

# Build all binaries
RUN cd api && go build -ldflags="-s -w" -o ../bin/api main.go
RUN cd webhook && go build -ldflags="-s -w" -o ../bin/webhook main.go
RUN cd log_stream && go build -ldflags="-s -w" -o ../bin/log_stream main.go
RUN cd user_expiry && go build -ldflags="-s -w" -o ../bin/user_expiry main.go

# ================================
# Stage 3: Build Ocserv 1.4.0
# ================================
FROM debian:trixie-slim AS ocserv-builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    wget make gcc pkg-config build-essential libgnutls28-dev libev-dev libreadline-dev \
    libpam0g-dev liblz4-dev libseccomp-dev libcrypt-dev libradcli4 liboath0 \
    libnl-route-3-dev libkrb5-dev libradcli-dev \
    libcurl4-gnutls-dev libcjose-dev libjansson-dev liboath-dev \
    libprotobuf-c-dev libtalloc-dev libllhttp-dev protobuf-c-compiler \
    gperf iperf3 lcov libuid-wrapper libpam-wrapper libnss-wrapper \
    libsocket-wrapper gss-ntlmssp haproxy iputils-ping freeradius \
    gawk gnutls-bin iproute2 jq tcpdump ipcalc \
    autogen autoconf automake libgeoip-dev xz-utils

WORKDIR /build
RUN wget https://www.infradead.org/ocserv/download/ocserv-1.4.0.tar.xz && \
    tar -xf ocserv-1.4.0.tar.xz && \
    cd ocserv-1.4.0 && \
    ./configure --prefix=/usr --sysconfdir=/etc --with-local-talloc && \
    make && \
    make install

# ================================
# Stage 4: Final Monolith Image
# ================================
FROM debian:trixie-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    supervisor \
    nginx \
    iptables \
    gnutls-bin \
    libev4 \
    libnl-route-3-200 \
    libseccomp2 \
    libprotobuf-c1 \
    libtalloc2 \
    libhttp-parser2.9 \
#    libpcl1 \
    libopts25 \
    libgeoip1 \
    liblz4-1 \
    procps \
    curl \
    iproute2 \
    net-tools \
    gettext-base \
    sqlite3 \
    tzdata \
    libradcli4 \
    liboath0t64 \
    && rm -rf /var/lib/apt/lists/*

# Setup Directories
WORKDIR /app
RUN mkdir -p /etc/ocserv /opt/certs /var/www/site /var/log/supervisor /app/db /var/log/nginx

# Copy Binaries
COPY --from=ocserv-builder /usr/sbin/ocserv /usr/sbin/ocserv
COPY --from=ocserv-builder /usr/sbin/ocserv-worker /usr/sbin/ocserv-worker
COPY --from=ocserv-builder /usr/bin/occtl /usr/bin/occtl
COPY --from=ocserv-builder /usr/bin/ocpasswd /usr/bin/ocpasswd
COPY --from=go-builder /src/bin/api /usr/local/bin/api
COPY --from=go-builder /src/bin/webhook /usr/local/bin/webhook
COPY --from=go-builder /src/bin/log_stream /usr/local/bin/log_stream
COPY --from=go-builder /src/bin/user_expiry /usr/local/bin/user_expiry

# Copy Frontend
COPY --from=vue-builder /app/dist /var/www/site

# Copy Configs & Scripts
COPY configs/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY configs/entrypoint_unified.sh /entrypoint.sh

# Permissions
RUN chmod +x /entrypoint.sh /usr/local/bin/*

# Env vars
ENV OCSERV_PORT=443

# Volumes
VOLUME ["/etc/ocserv", "/app/db", "/opt/certs"]

# Expose ports (VPN uses 443 TCP/UDP usually)
EXPOSE 443/tcp 443/udp 3080/tcp 3443/tcp

ENTRYPOINT ["/entrypoint.sh"]