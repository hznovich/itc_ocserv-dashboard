#!/bin/bash
# =============================================================================
# postgres-init.sh — idempotent first-run setup for the embedded PostgreSQL.
# =============================================================================
# Called from /entrypoint.sh on every container start. If $PGDATA already
# contains a working cluster, this script is essentially a no-op. Otherwise:
#   1. initdb a fresh cluster owned by the postgres user
#   2. write a minimal postgresql.conf (listen on 127.0.0.1 only)
#   3. write pg_hba.conf (allow scram-sha-256 from localhost only)
#   4. start the server briefly, create role + database, stop the server
#
# Then supervisord takes over and runs postgres in foreground.
# =============================================================================

set -euo pipefail

PGDATA="/app/db/postgres"
PG_BIN="/usr/lib/postgresql/17/bin"
PG_USER="${POSTGRES_USER:-ocserv}"
PG_DB="${POSTGRES_DB:-ocserv_db}"
PG_PASS="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set}"

log() { printf '\033[1;36m[postgres-init]\033[0m %s\n' "$*"; }

# Make sure the directory has the right ownership before we touch anything.
mkdir -p "$PGDATA"
chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

# Detect "already initialised" by the presence of PG_VERSION.
if [ -f "$PGDATA/PG_VERSION" ]; then
    log "cluster already initialised at $PGDATA — skipping initdb"
else
    log "running initdb in $PGDATA"
    su - postgres -c "$PG_BIN/initdb -D $PGDATA --auth=scram-sha-256 --encoding=UTF8 --locale=C.UTF-8 --pwfile=<(echo \"$PG_PASS\")"
    # Note: we don't write postgresql.conf / pg_hba.conf here — the
    # unconditional block below does it on every start, including this one.
fi

# Make sure socket dir exists for the running daemon.
mkdir -p /var/run/postgresql
chown -R postgres:postgres /var/run/postgresql

# Always rewrite postgresql.conf and pg_hba.conf on every start (not just at
# initdb). This is a no-op on a healthy install, but recovers if a previous
# attempt left stale rules — and lets us tighten policy in newer image
# versions without forcing operators to wipe the data dir.
#
# pg_hba is intentionally permissive on RFC1918 ranges. With network_mode=host
# we've observed Postgres accepting localhost connects via the host's external
# interface (kernel SNAT for src-route validation, etc.). Since the daemon
# still listens only on 127.0.0.1 (`listen_addresses = '127.0.0.1'`), the
# attack surface remains local: this opens auth, not the listener.
log "rewriting postgresql.conf and pg_hba.conf"
cat > "$PGDATA/postgresql.conf" <<EOF
# Managed by postgres-init.sh; rewritten on every start.
listen_addresses = '127.0.0.1'
port = 5432
unix_socket_directories = '/var/run/postgresql'
max_connections = 100
shared_buffers = 128MB
dynamic_shared_memory_type = posix
log_destination = 'stderr'
logging_collector = off
log_timezone = 'UTC'
datestyle = 'iso, mdy'
timezone = 'UTC'
lc_messages = 'C.UTF-8'
lc_monetary = 'C.UTF-8'
lc_numeric = 'C.UTF-8'
lc_time = 'C.UTF-8'
default_text_search_config = 'pg_catalog.english'
EOF

cat > "$PGDATA/pg_hba.conf" <<EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# Local Unix socket — preferred path used by entrypoint.sh by default.
local   all             postgres                                peer
local   all             all                                     scram-sha-256
# Loopback — kept for backwards compatibility.
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
# RFC1918 ranges — needed when the kernel routes "127.0.0.1" connects via
# the external interface in network_mode=host. The daemon only listens on
# 127.0.0.1, so this only widens AUTH, not exposure.
host    all             all             10.0.0.0/8              scram-sha-256
host    all             all             172.16.0.0/12           scram-sha-256
host    all             all             192.168.0.0/16          scram-sha-256
EOF

chown postgres:postgres "$PGDATA/postgresql.conf" "$PGDATA/pg_hba.conf"

# Reload pg_hba into a running daemon if there is one, so a SIGHUP is enough
# instead of a full restart. pg_ctl reload is a no-op when the daemon is
# stopped, and quietly succeeds when running.
su - postgres -c "$PG_BIN/pg_ctl -D $PGDATA reload" >/dev/null 2>&1 || true

# If the role/db doesn't exist yet, start a temporary instance and create them.
# We detect this by trying a peer-auth psql as the postgres superuser.
log "checking for role $PG_USER and database $PG_DB"
if ! su - postgres -c "$PG_BIN/pg_ctl -D $PGDATA -s -t 5 status" >/dev/null 2>&1; then
    log "starting temporary postgres for bootstrap"
    su - postgres -c "$PG_BIN/pg_ctl -D $PGDATA -l /tmp/pg-bootstrap.log -w start"
    STARTED_FOR_BOOTSTRAP=1
else
    STARTED_FOR_BOOTSTRAP=0
fi

# Idempotent role creation.
ROLE_EXISTS=$(su - postgres -c "$PG_BIN/psql -tA -c \"SELECT 1 FROM pg_roles WHERE rolname='$PG_USER'\"" || true)
if [ -z "$ROLE_EXISTS" ]; then
    log "creating role $PG_USER"
    su - postgres -c "$PG_BIN/psql -c \"CREATE ROLE $PG_USER LOGIN PASSWORD '$PG_PASS';\""
else
    # Always reset the password from env so rotating POSTGRES_PASSWORD works
    # without manual intervention.
    log "role exists — refreshing password from env"
    su - postgres -c "$PG_BIN/psql -c \"ALTER ROLE $PG_USER WITH PASSWORD '$PG_PASS';\""
fi

# Idempotent DB creation.
DB_EXISTS=$(su - postgres -c "$PG_BIN/psql -tA -c \"SELECT 1 FROM pg_database WHERE datname='$PG_DB'\"" || true)
if [ -z "$DB_EXISTS" ]; then
    log "creating database $PG_DB owned by $PG_USER"
    su - postgres -c "$PG_BIN/psql -c \"CREATE DATABASE $PG_DB OWNER $PG_USER ENCODING 'UTF8';\""
fi

# Stop the bootstrap instance — supervisord will start the real one.
if [ "$STARTED_FOR_BOOTSTRAP" = "1" ]; then
    log "stopping bootstrap postgres"
    su - postgres -c "$PG_BIN/pg_ctl -D $PGDATA -s -m fast -w stop"
fi

log "postgres setup complete"
