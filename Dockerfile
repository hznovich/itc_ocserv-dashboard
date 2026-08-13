# =============================================================================
# itc_ocserv-dashboard — single-image build
# =============================================================================
# Stages:
#   1. vue-builder     — build the Vue/Vuetify frontend
#   2. go-builder      — build all four Go binaries (api, webhook, log_stream,
#                        user_expiry) using go.work
#   3. ocserv-builder  — compile ocserv 1.4.2 from source (meson + ninja)
#   4. final           — Debian trixie-slim with postgres-17, nginx, certbot,
#                        radcli, supervisord, all binaries copied in
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Build Frontend (Vue)
# -----------------------------------------------------------------------------
FROM node:20 AS vue-builder
ARG LANGUAGES="en:English,ru:Русский"
WORKDIR /app
COPY web/package*.json web/yarn.lock ./
RUN yarn install --frozen-lockfile
COPY ./web .
RUN NODE_ENV=production VITE_I18N_LANGUAGES="${LANGUAGES}" yarn run build

# -----------------------------------------------------------------------------
# Stage 2: Build Backend (Go)
# -----------------------------------------------------------------------------
FROM golang:1.25.0 AS go-builder
ENV CGO_ENABLED=1 GOOS=linux GOARCH=amd64
WORKDIR /src

# Copy module files first for layer caching.
COPY services/go.work .
COPY services/go.work.sum .
COPY services/api/go.mod        services/api/go.sum        ./api/
COPY services/common/go.mod     services/common/go.sum     ./common/
COPY services/log_stream/go.mod services/log_stream/go.sum ./log_stream/
COPY services/user_expiry/go.mod services/user_expiry/go.sum ./user_expiry/
COPY services/webhook/go.mod    services/webhook/go.sum    ./webhook/

RUN go mod download

# Copy source.
COPY services/ ./

# Build all four binaries. Each `cd` resets to /src/<svc> via &&-chain so a
# single failure aborts the whole RUN (and `set -e` is implicit in /bin/sh -c).
RUN cd api          && go build -ldflags="-s -w" -o ../bin/api          main.go && \
    cd ../webhook   && go build -ldflags="-s -w" -o ../bin/webhook      main.go && \
    cd ../log_stream && go build -ldflags="-s -w" -o ../bin/log_stream  main.go && \
    cd ../user_expiry && go build -ldflags="-s -w" -o ../bin/user_expiry main.go

# -----------------------------------------------------------------------------
# Stage 3: Build ocserv 1.4.2 from source (meson + ninja)
# -----------------------------------------------------------------------------
# 1.4.2 dropped autoconf/automake in favour of meson (#699). The dep list is
# trimmed accordingly: meson + ninja-build replace autogen/autoconf/automake/
# gperf. The new binary `ocserv-fw` (nftables firewall helper) requires
# ipcalc-ng at runtime — installed in the final stage, not here.
FROM debian:trixie-slim AS ocserv-builder

ARG OCSERV_VERSION=1.4.2

RUN apt-get update && apt-get install -y --no-install-recommends \
        wget xz-utils ca-certificates \
        meson ninja-build pkg-config build-essential \
        gperf ipcalc-ng \
        libgnutls28-dev libev-dev libreadline-dev libpam0g-dev \
        liblz4-dev libseccomp-dev libcrypt-dev libradcli-dev \
        liboath-dev libnl-route-3-dev libkrb5-dev \
        libcurl4-gnutls-dev libcjose-dev libjansson-dev \
        libprotobuf-c-dev libtalloc-dev libllhttp-dev \
        protobuf-c-compiler libgeoip-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
# Build ocserv into a staging directory under DESTDIR=/dist. This pattern has
# two big advantages over installing into the builder's real /usr:
#   1. We can `find /dist -type f -executable` to surface the exact install
#      layout — previously our COPY assumed /usr/{bin,sbin}/oc* paths but a
#      meson change or build option could move binaries; with DESTDIR a wrong
#      assumption is visible in the build log instead of failing later at
#      `COPY --from=ocserv-builder` with a cryptic "not found".
#   2. The final stage can copy /dist/* and inherit whatever paths meson chose,
#      so we don't have to track them by hand.
#
# Every step is hard-checked: no `|| true` masks here. If meson fails to
# produce one of the expected binaries the RUN aborts immediately and the
# log makes it obvious why.
RUN wget -q "https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz" && \
    tar -xf "ocserv-${OCSERV_VERSION}.tar.xz" && \
    cd "ocserv-${OCSERV_VERSION}" && \
    meson setup build --prefix=/usr --sysconfdir=/etc && \
    ninja -C build && \
    DESTDIR=/dist ninja -C build install && \
    echo "=== ocserv install layout under /dist ===" && \
    find /dist -type f \( -executable -o -name '*.so*' \) | sort && \
    test -x /dist/usr/sbin/ocserv && \
    test -x /dist/usr/bin/occtl && \
    test -x /dist/usr/bin/ocpasswd && \
    strip /dist/usr/sbin/ocserv /dist/usr/bin/occtl /dist/usr/bin/ocpasswd && \
    if [ -x /dist/usr/sbin/ocserv-worker ]; then strip /dist/usr/sbin/ocserv-worker; fi

# -----------------------------------------------------------------------------
# Stage 4: Final monolith
# -----------------------------------------------------------------------------
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

# Runtime dependencies for every component the image bundles.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        # process supervisor
        supervisor \
        # web tier
        nginx-light \
        # ocserv runtime libs (note: 1.4.2 BUNDLES llhttp/inih/protobuf-c
        # statically, so no libllhttp runtime package is needed)
        gnutls-bin libev4 libnl-route-3-200 libseccomp2 libprotobuf-c1 \
        libtalloc2 libopts25 libgeoip1 liblz4-1 \
        libradcli4 liboath0 \
        # ocserv-fw helper (nftables-based) needs ipcalc-ng (1.4.2+)
        ipcalc-ng nftables \
        # postgres
        postgresql-17 postgresql-client-17 \
        # certbot (always available; only invoked if CERTBOT_ENABLED=true)
        certbot \
        # tooling for entrypoint, healthchecks, networking
        iptables iproute2 net-tools procps curl gettext-base sqlite3 \
        tzdata cron jq \
        # diagnostics: radtest (probe RADIUS from inside the container),
        # netcat-openbsd (raw UDP/TCP probes), tcpdump (in-container packet
        # capture when host-side capture is awkward)
        freeradius-utils netcat-openbsd tcpdump dnsutils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Create runtime directories.
RUN mkdir -p \
        /etc/ocserv \
        /etc/radcli \
        /opt/certs \
        /var/www/site \
        /var/www/certbot \
        /var/log/supervisor \
        /var/log/nginx \
        /app/db \
        /app/db/postgres \
    && chown -R postgres:postgres /app/db/postgres

# ocserv binaries from the DESTDIR=/dist staging area. Paths now mirror what
# `find /dist` showed in the builder stage. ocserv-worker is copied via a
# wildcard glob so the build still succeeds if a future ocserv release ever
# drops it (the fork/exec model has shipped it as a separate binary since
# ocserv 1.0, but we shouldn't tie ourselves to that forever).
COPY --from=ocserv-builder /dist/usr/sbin/ocserv          /usr/sbin/ocserv
COPY --from=ocserv-builder /dist/usr/sbin/ocserv-worker*  /usr/sbin/
COPY --from=ocserv-builder /dist/usr/bin/occtl            /usr/bin/occtl
COPY --from=ocserv-builder /dist/usr/bin/ocpasswd         /usr/bin/ocpasswd
COPY --from=go-builder     /src/bin/api                   /usr/local/bin/api
COPY --from=go-builder     /src/bin/webhook               /usr/local/bin/webhook
COPY --from=go-builder     /src/bin/log_stream            /usr/local/bin/log_stream
COPY --from=go-builder     /src/bin/user_expiry           /usr/local/bin/user_expiry

# Built frontend.
COPY --from=vue-builder    /app/dist                 /var/www/site

# Configs and entrypoints.
COPY configs/supervisord.conf  /etc/supervisor/conf.d/supervisord.conf
COPY configs/entrypoint.sh     /entrypoint.sh
COPY configs/nginx.conf.tmpl   /etc/nginx/nginx.conf.tmpl
COPY configs/postgres-init.sh  /usr/local/bin/postgres-init.sh
COPY configs/certbot-renew.sh  /usr/local/bin/certbot-renew.sh

RUN chmod +x \
        /entrypoint.sh \
        /usr/local/bin/api \
        /usr/local/bin/webhook \
        /usr/local/bin/log_stream \
        /usr/local/bin/user_expiry \
        /usr/local/bin/postgres-init.sh \
        /usr/local/bin/certbot-renew.sh

# Healthcheck — uses the API port (configurable via API_PORT, default 18080).
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${API_PORT:-18080}/health" || exit 1

VOLUME ["/etc/ocserv", "/app/db", "/opt/certs", "/var/log"]

# Note: with network_mode=host (recommended in docker-compose.yml), EXPOSE is
# informational only; the host binds the ports directly.
EXPOSE 443/tcp 443/udp 80/tcp 3080/tcp 3443/tcp

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
