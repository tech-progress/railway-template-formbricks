# Formbricks Hub API start contract (joined like postgres-start.sh).
# 1. Upstream runs Formbricks migrations before Hub's, because both write the same database. Formbricks reports ready only after its migrations.
until wget -q -O /dev/null "$FORMBRICKS_READY_URL"; do echo "Waiting for Formbricks migrations"; sleep 3; done
# 2. Hub's own migrations (upstream hub-migrate). The connection reaches goose through GOOSE_DBSTRING and river through libpq PG* variables, so the password never appears in a process argument list.
GOOSE_DRIVER=postgres GOOSE_DBSTRING="$DATABASE_URL" /usr/local/bin/goose -dir /app/migrations up
PGUSER=$(printf "%s" "$DATABASE_URL" | sed -E "s#^[a-z]+://([^:@/]+):.*#\1#") PGPASSWORD=$(printf "%s" "$DATABASE_URL" | sed -E "s#^[a-z]+://[^:@/]+:([^@]+)@.*#\1#") PGHOST=$(printf "%s" "$DATABASE_URL" | sed -E "s#^[^@]+@([^:/?]+).*#\1#") PGPORT=$(printf "%s" "$DATABASE_URL" | sed -E "s#^[^@]+@[^:/?]+:([0-9]+).*#\1#") PGDATABASE=$(printf "%s" "$DATABASE_URL" | sed -E "s#^[^@]+@[^/]+/([^?]+).*#\1#") PGSSLMODE=disable /usr/local/bin/river migrate-up
# 3. The API on PORT.
exec /app/hub-api
