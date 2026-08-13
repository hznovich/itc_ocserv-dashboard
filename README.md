# itc_ocserv-dashboard

Self-hosted [OpenConnect (ocserv)](https://ocserv.openconnect-vpn.net/) VPN gateway with a Vue/Go management dashboard, packaged as a **single Docker image** for corporate-network access.

Forked from [`mmtaee/ocserv-dashboard`](https://github.com/mmtaee/ocserv-dashboard) v4.2 with the following changes:

- **Monolithic image** under supervisord: PostgreSQL 17, ocserv 1.4.2, nginx, the Go API + helper services, and (optionally) certbot — one container, no compose juggling.
- **Host network mode** by default — fewer surprises with VPN traffic, direct port binding.
- **Multiple client routes** via `OC_ROUTES` (comma-separated).
- **Split-DNS** via `OC_SPLIT_DNS` (comma-separated domains).
- **PROXY protocol** support via `OC_LISTEN_PROXY_PROTO=true` (for L4 load balancers).
- **RADIUS authentication** via `RADIUS_ENABLED`.
- **Optional in-container certbot** (`CERTBOT_ENABLED=true`) or BYO certs from `/opt/certs`.
- **install.sh detects existing `.env`** — keep / fill missing / regenerate.
- Multiple **security fixes** (see [Security changes](#security-changes-vs-upstream)).

## Quick start

```bash
git clone <this repo>
cd itc_ocserv-dashboard
./install.sh        # interactive: detects .env if present
```

Then open `https://<HOST>:3443` and complete first-run setup (creates the initial admin).

## install.sh modes

When you re-run the installer with a `.env` already present, it asks:

| Mode | Behaviour |
|---|---|
| **Keep as-is** | No questions, no rewrite. Validates required keys are present, then proceeds to `docker compose build && up`. |
| **Fill missing** | Keeps every existing value. Only prompts for keys absent from `.env`. Generates fresh secrets only if those specific keys are missing. |
| **Regenerate** | Walks through every option, showing existing values as defaults. Asks before rotating secrets. |

The original `.env` is backed up to `.env.<timestamp>.bak` whenever it gets rewritten.

## Configuration

All knobs live in `.env`. See [`.env.sample`](./.env.sample) for the annotated reference.

### VPN networking

| Variable | Effect |
|---|---|
| `OC_NET` | VPN client subnet, e.g. `172.16.24.0/24`. |
| `OC_ROUTES` | Comma-separated networks pushed to clients. Empty = none. `0.0.0.0/0` = full tunnel. |
| `OCSERV_DNS` | DNS server pushed to clients. |
| `OC_SPLIT_DNS` | Comma-separated domains for split-DNS. Empty = no split-DNS. |
| `OC_TUNNEL_ALL_DNS` | `true`/`false`/empty. Empty = auto (true if no split-DNS, false otherwise). |
| `OC_LISTEN_PROXY_PROTO` | `true` to enable HAProxy PROXY protocol on the listener. |
| `OC_CAMOUFLAGE` | Camouflage word. Empty = camouflage off. |
| `SKIP_NAT` | `true` to skip MASQUERADE setup (manage host NAT yourself). |

### Authentication

| Variable | Effect |
|---|---|
| `RADIUS_ENABLED` | `true` switches `auth = …` to RADIUS. The dashboard's UI keeps working as a local user inventory. |
| `RADIUS_SERVER`, `RADIUS_SECRET`, `RADIUS_*_PORT`, `RADIUS_NAS_ID` | RADIUS upstream. |

When RADIUS is on, the entrypoint **comments out** `config-per-group` and `config-per-user` lines in `ocserv.conf` — otherwise ocserv 1.4.x aborts at startup looking for per-user files that don't exist.

### TLS

Two supported modes:

1. **In-container certbot** (`CERTBOT_ENABLED=true`).
   - Entrypoint runs `certbot certonly --standalone -d $SSL_CN` on first start.
   - Port 80 must be reachable from the public internet during issuance.
   - A renewal loop runs every 12 h. On success it sends `SIGHUP` to ocserv and `nginx -s reload`.

2. **Centralised host-side certbot** (`CERTBOT_ENABLED=false`, default).
   - Mount `/opt/certs:/opt/certs:ro` (already in `docker-compose.yml`).
   - Container expects `/opt/certs/live/$SSL_CN/{fullchain,privkey}.pem`.
   - On host renewal, restart the container so ocserv re-reads the chain. The `certbot.restart=true` Docker label simplifies a deploy-hook one-liner:
     ```
     docker ps --filter label=certbot.restart=true --format '{{.Names}}' | xargs -r docker restart
     ```

If neither cert files nor certbot is available, the entrypoint generates a self-signed pair so the stack still starts (lab use only).

### Internal service ports

The container runs with **`network_mode: host`**. That means every listening port binds directly on the host. To minimise the chance of clashing with other services on your host, internal ports are bumped to the 1xxxx range:

| Port | Service |
|---|---|
| `API_PORT=18080` | Go API (loopback only) |
| `LOG_STREAM_PORT=18081` | SSE log tail (loopback only) |
| `WEBHOOK_PORT=18888` | internal occtl webhook (loopback only) |
| `POSTGRES_PORT=5432` | embedded PostgreSQL (loopback only) |
| `NGINX_HTTP_PORT=3080` | dashboard HTTP → HTTPS redirect |
| `NGINX_HTTPS_PORT=3443` | dashboard HTTPS |
| `OCSERV_PORT=443` | VPN (TCP+UDP) |
| `80` | only used when `CERTBOT_ENABLED=true` |

Override any of them in `.env` if needed.

## Recipe: HAProxy on the same host

This is the trickiest supported topology, and every step below exists because
skipping it produces a confusing failure. HAProxy terminates nothing (TCP mode),
forwards TLS to ocserv with a PROXY v2 header, and both run on one machine in
host-network mode — so they compete for ports.

**1. Host: enable IP forwarding.** The container cannot set this itself —
`net.ipv4.ip_forward` is a namespaced sysctl and runc refuses to touch it from
a host-network container (`sysctl not allowed in host network namespace`).

```bash
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-ocserv.conf
sysctl --system
```

**2. `.env`** — move ocserv's TCP listener off 443 (HAProxy owns it), and move
the ACME challenge off 80 (HAProxy owns that too):

```ini
OCSERV_TCP_PORT=8443        # HAProxy forwards here
OCSERV_UDP_PORT=443         # DTLS must reach the host directly
OC_LISTEN_PROXY_PROTO=true  # accept HAProxy's PROXY v2 header
CERTBOT_ENABLED=true
CERTBOT_HTTP_PORT=8080      # certbot binds this during issuance/renewal
```

**3. `docker-compose.yml`** — with `CERTBOT_ENABLED=true`, `/opt/certs` must be
writable (certbot creates `live/`, `archive/`, `accounts/` there):

```yaml
- /opt/certs:/opt/certs     # no :ro
```

**4. HAProxy** — TCP passthrough by SNI, plus an ACME route:

```haproxy
frontend https_in
    mode tcp
    bind *:443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    acl host_oc req.ssl_sni -i oc.example.com
    use_backend https_ocserv if host_oc

backend https_ocserv
    mode tcp
    server ocserv 127.0.0.1:8443 check send-proxy-v2

frontend http_in
    mode http
    bind *:80
    acl is_acme path_beg -i /.well-known/acme-challenge/
    acl host_oc hdr(host) -i oc.example.com
    use_backend acme_ocserv if host_oc is_acme

backend acme_ocserv
    mode http
    server acme 127.0.0.1:8080
```

Two things to get right in that config:

- The ACME backend must **not** point at `127.0.0.1:80` — that is HAProxy
  itself, and the request loops forever.
- Do **not** put `check` on the ACME backend. Certbot binds 8080 only for the
  few seconds an issuance takes, so a health check would flap constantly.

**5. UDP/DTLS bypasses HAProxy entirely.** HAProxy cannot forward generic UDP.
Route UDP 443 from the perimeter straight to this host — ocserv listens on it
directly. Without this, clients still connect but silently fall back to
TCP-over-TCP, which degrades badly on lossy links. If UDP genuinely cannot be
delivered, set `OC_NO_UDP=true` so ocserv stops advertising a dead DTLS port.

Verify DTLS came up after connecting:

```bash
docker exec ocserv occtl show users     # look for a DTLS cipher on the session
```

**6. If authenticating against Windows NPS:** enable
**Unencrypted authentication (PAP, SPAP)** under Network Policy → Constraints →
Authentication Methods. ocserv speaks only PAP over RADIUS; without this NPS
rejects every attempt with `Reason Code: 66`, and the ocserv log shows the
request reaching RADIUS but coming back rejected.

Register the RADIUS client in NPS by the **ocserv host's IP**, not HAProxy's —
that is what lands in `NAS-IP-Address`.

## Troubleshooting

Turn up ocserv logging first — it defaults to `1`, which hides almost
everything useful. Level `3` shows the auth chain including RADIUS:

```ini
OCSERV_LOG_LEVEL=3
```

```bash
docker compose down && docker compose up -d
docker exec ocserv tail -100 /var/log/supervisor/ocserv.err.log
```

Set it back to `1` once things work — at level 3 every load-balancer health
probe writes several lines and the log grows fast.

Failure signatures worth recognising:

| Symptom | Cause |
|---|---|
| `sysctl "net.ipv4.ip_forward" not allowed in host network namespace` | A `sysctls:` block in compose under `network_mode: host`. Set it on the host instead. |
| `no configuration file provided: not found` | `docker-compose.yml` missing from the working directory. |
| `/opt/certs is read-only but CERTBOT_ENABLED=true` | Drop `:ro` from the certs mount. |
| `Address already in use` from certbot | Something else owns `CERTBOT_HTTP_PORT`. Move it and route ACME through your proxy. |
| nginx won't start, `bind() to 0.0.0.0:80 failed` | Another process owns :80. This image no longer binds :80 — check for a stale `nginx.conf.tmpl`. |
| `error connecting to sec-mod socket ... No such file` | ocserv IPC path problem. Workers die instantly and connections drop right after the PROXY header. |
| `radius-auth: communicating username` then an immediate IP ban, no UDP on the wire | radcli found no shared secret: the key in `/etc/radcli/servers` must match the `authserver` value in `radiusclient.conf` **exactly**, port included or excluded on both sides. |
| Client shows `requested Basic authentication which is disabled` | Camouflage is on and the client didn't append `/?<OC_CAMOUFLAGE>` to the URL. |
| `no pg_hba.conf entry for host <external ip>` | A TCP connect to 127.0.0.1 left via the host interface. The entrypoint rewrites `POSTGRES_HOST` to the Unix socket to avoid this. |

Tracing RADIUS end to end — run this on the ocserv host while attempting a
login. It immediately separates "packet never left" from "server rejected":

```bash
tcpdump -ni any -vv 'host <radius-ip> and udp port 1812'
```

## Networking model

`network_mode: host` means:

- The container **shares the host's network namespace**. ocserv binds 443 directly on the host's interface, no docker-proxy in the path.
- iptables operations from the entrypoint **modify the host's iptables**. The container needs `cap_add: NET_ADMIN` for that.
- If your host already manages MASQUERADE/forwarding for the VPN subnet (e.g. firewalld, ufw, custom nftables), set `SKIP_NAT=true` in `.env` so the entrypoint doesn't fight it.

## Volumes

The compose file mounts four directories under `./data/`:

| Mount | Purpose |
|---|---|
| `./data/ocserv` → `/etc/ocserv` | ocserv config, per-group/per-user overrides, ocpasswd. |
| `./data/db` → `/app/db` | Embedded PostgreSQL data dir (`/app/db/postgres`). |
| `./data/logs` → `/var/log` | supervisord, nginx, ocserv, postgres logs. |
| `/opt/certs` → `/opt/certs` (ro) | Host-managed certificates (`CERTBOT_ENABLED=false`). |

Wipe and start over: `docker compose down && rm -rf data/`.

## Security changes vs upstream

| Issue | Fix |
|---|---|
| Admin passwords hashed with **MD5 + `math/rand` salt**. | Replaced with `bcrypt` (cost 12). Old MD5 hashes are detected and rejected, forcing a reset for legacy admins. |
| `SECRET_KEY` and `JWT_SECRET` had hardcoded fallbacks (`"secret1234"`). | API **fails fast** on startup if either is missing or shorter than 16 chars. Same for `POSTGRES_PASSWORD`. |
| Camouflage secret in upstream entrypoint was a literal string `"OC_CAMOUFLAGE:-mysecretkey"` (missing `${…}`), so every install used the same publicly known prefix. | Properly substituted; empty `OC_CAMOUFLAGE` disables camouflage entirely. |
| `OcservUser.Password` (plaintext VPN password) serialised in JSON via `GET /ocserv/users`. | Tagged `json:"-"`. |
| **IDOR**: any authenticated staff user could `GET/PATCH/DELETE/lock/unlock/disconnect/statistics` any UID. | New `loadOwnedByUID` helper enforces ownership on every per-record endpoint. |
| Customer summary endpoint had separate errors for "user not found" vs "wrong password" (username enumeration), non-constant-time compare. | Unified to a single generic error and `crypto/subtle.ConstantTimeCompare`. |
| `home` controller deadlocked when more than 4 of 7 background goroutines errored simultaneously. | Rewritten with `errgroup.WithContext`. |
| `c.Param("userUID")` in `system/controller.go` always returned `""`. | Replaced with `c.Get("userUID").(string)`. |
| `Rx`, `Tx`, `TrafficSize` were `int` in Go but `BIGINT` in the migration — risk of 32-bit truncation. | Promoted to `int64` end-to-end. |

What's not yet addressed (carry-over from upstream):
- JWT in `localStorage` (XSS exposure).
- No JWT revocation list.
- `/system/setup` reopens whenever the admin table is empty.

## ocserv version

Builds **ocserv 1.4.2** from source using meson + ninja. Notable changes adopted from 1.4.1/1.4.2:

- `min-reauth-time` renamed to `ban-time` (handled in `ocserv.conf` template).
- HTTP body limit (256 KB) for unauthenticated workers.
- Authentication-bypass fix when combining cert + password auth with `SAN(rfc822name)` cert-user-OID.
- IPC message validation hardening.

## Project layout

```
.
├── Dockerfile                 # 4-stage monolith (vue / go / ocserv / final)
├── docker-compose.yml         # network_mode: host
├── install.sh                 # interactive setup
├── .env.sample                # annotated reference
├── configs/
│   ├── supervisord.conf
│   ├── entrypoint.sh
│   ├── nginx.conf.tmpl
│   ├── postgres-init.sh
│   └── certbot-renew.sh
├── services/
│   ├── api/                   # Echo + GORM REST API + cobra CLI
│   ├── common/                # shared models, config, logger
│   ├── webhook/               # internal occtl bridge
│   ├── log_stream/            # SSE log tail
│   └── user_expiry/           # background expiry locker
└── web/                       # Vue 3 + Vuetify dashboard
```

## License

Inherited from upstream — MIT (see [LICENSE](./LICENSE)).
