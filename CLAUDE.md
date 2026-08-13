# Project context

Fork of [`mmtaee/ocserv-dashboard`](https://github.com/mmtaee/ocserv-dashboard) v4.2,
restructured so the whole stack ships as **one Docker image**. Used for corporate
network access (staff reaching internal networks), not censorship circumvention —
that framing matters when judging trade-offs like PAP over RADIUS.

Repo: `github.com/hznovich/itc_ocserv-dashboard`

## Architecture

One container, `network_mode: host`, everything under supervisord:

| Process | Role | Binds |
|---|---|---|
| `postgres` | PostgreSQL 17, data in `/app/db/postgres` | `127.0.0.1:5432` + Unix socket |
| `ocserv` | OpenConnect VPN 1.4.2, built from source with meson | `OCSERV_TCP_PORT` / `OCSERV_UDP_PORT` |
| `nginx` | serves the Vue bundle, proxies `/api` and `/ws` | `NGINX_HTTP_PORT` 3080, `NGINX_HTTPS_PORT` 3443 |
| `api` | Go/Echo REST API, runs `api migrate` then `api serve` | `API_PORT` 18080 |
| `webhook` | internal bridge to `occtl` | `WEBHOOK_PORT` 18888 |
| `log_stream` | SSE log tail behind `/ws` | `LOG_STREAM_PORT` 18081 |
| `user_expiry` | cron-ish job locking expired VPN users | — |
| `certbot_renew` | 12h renewal loop; no-op when `CERTBOT_ENABLED=false` | `CERTBOT_HTTP_PORT` |

`configs/entrypoint.sh` regenerates `/etc/ocserv/ocserv.conf`, `/etc/nginx/nginx.conf`
and (in RADIUS mode) `/etc/radcli/*` **on every container start** from `.env`.
Never hand-edit those inside the container — changes are lost on restart.

Internal service ports sit in the 1xxxx range deliberately: with host networking
they bind the host's loopback, and 8080/8081/8888 collide with things people
actually run.

## Decisions that look odd but are deliberate

Do not "fix" these without reading why — each cost a debugging session.

- **`POSTGRES_HOST` is rewritten to `/var/run/postgresql`** when it looks like
  `127.0.0.1`/`localhost`. Under host networking a TCP connect to loopback was
  observed leaving via the host's external interface, and Postgres then rejected
  it (`no pg_hba.conf entry for host <external ip>`). The Unix socket sidesteps
  the whole class of problem. pgx accepts a directory path in `host=`.
- **`pg_hba.conf` and `postgresql.conf` are rewritten on every start**, not only
  at initdb. Otherwise a stale data dir keeps old rules forever and the fix above
  can't be rolled out to existing installs.
- **`socket-file = /run/ocserv/ocserv-socket`**, and the entrypoint clears stale
  `ocserv-socket*` before start. Leftover sockets caused
  `error connecting to sec-mod socket ... No such file or directory`; workers
  died instantly and connections dropped right after the PROXY header — looks
  exactly like a network fault, isn't one.
- **ocserv runs with `--log-stderr`.** Without it ocserv logs to syslog, no
  syslogd runs in the image, and everything past the startup banner vanishes.
- **`config-per-group` / `config-per-user` are commented out in RADIUS mode.**
  ocserv aborts at startup otherwise.
- **`/etc/radcli/radiusclient.conf` is generated, not the packaged one.** The
  Debian default sets `authserver localhost`, which silently overrides
  `/etc/radcli/servers` — auth then fails with no packet on the wire.
- **The `authserver` value and the `servers` key must match as literal strings**
  (both with `:port` or both without). radcli does a plain string lookup; a
  mismatch means "no shared secret", which surfaces as an instant IP ban.
- **No `sysctls:` in compose.** `net.ipv4.ip_forward` is namespaced and runc
  refuses it under `network_mode: host`. It must be set on the host.
- **nginx does not bind :80.** On hosts where HAProxy owns :80 nginx would fail
  to start entirely, taking the dashboard down. ACME is handled by certbot
  standalone on `CERTBOT_HTTP_PORT`.
- **ocserv is built with meson**, not autotools — upstream switched in 1.4.2.
  Build deps include `gperf` and `ipcalc-ng`; `meson setup` fails without them.
  Install goes to `DESTDIR=/dist` so the layout is inspectable and `COPY`
  failures surface at build time, not at the final stage.

## Security fixes carried on top of upstream

Applied in `services/`. Don't lose these when merging upstream changes:

- bcrypt (cost 12) replacing MD5 + `math/rand` salt for admin passwords; legacy
  32-char hashes are rejected rather than accepted
- fail-fast startup when `SECRET_KEY` / `JWT_SECRET` / `POSTGRES_PASSWORD` are
  missing or under 16 chars — upstream had hardcoded fallbacks like `secret1234`
- `OcservUser.Password` tagged `json:"-"` — it was serialised in `GET /ocserv/users`
- `loadOwnedByUID` ownership check on every per-record ocserv-user endpoint;
  upstream filtered only the list endpoint, so staff could act on any UID
- customer summary uses `crypto/subtle.ConstantTimeCompare` and one generic
  error for both "no such user" and "wrong password" (was enumerable)
- `home` controller rewritten on `errgroup` — the old buffered channel of 4 with
  7 goroutines deadlocked when 5+ errored
- `Rx` / `Tx` / `TrafficSize` promoted to `int64` to match the `BIGINT` schema

Known gaps, not yet addressed: JWT stored in `localStorage`; no token revocation
(the `UserToken` row is written but never checked); `/system/setup` reopens
whenever the admin table is empty.

## Deployment topologies

**Direct** — ocserv owns 443 TCP+UDP. Nothing special.

**HAProxy on the same host** — see the recipe in `README.md`. Short version:
TCP moves to 8443 with `send-proxy-v2`, ACME moves to 8080, UDP 443 must be
routed to the host directly because HAProxy cannot forward UDP, and
`ip_forward` is set on the host.

If UDP can't be delivered, set `OC_NO_UDP=true` so ocserv stops advertising a
DTLS port nothing listens on — otherwise clients silently degrade to
TCP-over-TCP.

**RADIUS against Windows NPS**: enable *Unencrypted authentication (PAP, SPAP)*
in the Network Policy. ocserv speaks only PAP; without it NPS returns
`Reason Code: 66`. Register the RADIUS client by the **ocserv host's** IP —
that's what lands in `NAS-IP-Address`, not HAProxy's.

## Debugging

`OCSERV_LOG_LEVEL=3` in `.env` exposes the auth chain including RADIUS; set it
back to `1` afterwards, because at 3 every load-balancer health probe writes
several lines.

```bash
docker exec ocserv tail -100 /var/log/supervisor/ocserv.err.log
tcpdump -ni any -vv 'host <radius-ip> and udp port 1812'   # on the ocserv host
docker exec ocserv occtl show users                        # DTLS cipher = UDP works
```

`README.md` has a table of failure signatures worth reading before guessing.

## Housekeeping

- `configs/entrypoint_unified.sh` is the old name of `configs/entrypoint.sh` —
  delete it if it reappears.
- `.env` and `data/` must never be committed: `data/` holds the Postgres cluster
  and issued private keys.
- `install.sh` is idempotent and offers keep / fill-missing / regenerate when a
  `.env` already exists.
- **Line endings are LF, pinned by `.gitattributes` (`* text=auto eol=lf`).**
  The only target is the Linux image, so there is no case for CRLF anywhere in
  the tree. A Windows clone with `core.autocrlf=true` would otherwise check out
  `entrypoint.sh`, `certbot-renew.sh` and `install.sh` with CRLF, and the
  shebang then fails inside the container with a bare
  `no such file or directory` — which reads like a missing file, not a line
  ending. Never add an `eol=crlf` exception.
- **`install.sh` is tracked mode 755; the in-container scripts stay 644.**
  `README.md` documents `./install.sh`, so it needs the exec bit in git.
  `entrypoint.sh`, `postgres-init.sh` and `certbot-renew.sh` don't — the
  `Dockerfile` `chmod +x`es them after `COPY`. On Windows `core.filemode` is
  `false`, so set the bit with `git update-index --chmod=+x <file>`.