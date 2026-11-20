# Valkey start contract (joined like postgres-start.sh).
# 1. Keep the password out of the process arguments: it goes into a 0600 config file owned by the valkey user.
case "${VALKEY_PASSWORD:-}" in ""|*[!A-Za-z0-9]*) echo "Refusing to start: VALKEY_PASSWORD must be letters and digits." >&2; exit 64;; esac
umask 077
printf "requirepass %s\n" "$VALKEY_PASSWORD" > /tmp/valkey-railway.conf
chown valkey:valkey /tmp/valkey-railway.conf
# 2. The official entrypoint changes the ownership of /data and drops to the valkey user before it starts the server.
cd /data
exec docker-entrypoint.sh /tmp/valkey-railway.conf --appendonly yes --maxmemory-policy noeviction
