# Formbricks Hub API start contract (joined like postgres-start.sh).
# 1. Upstream runs Formbricks migrations before Hub's, because both write the same database. Formbricks reports ready only after its migrations.
until wget -q -O /dev/null "$FORMBRICKS_READY_URL"; do echo "Waiting for Formbricks migrations"; sleep 3; done
# 2. Hub's own migrations (upstream hub-migrate), then the API on PORT.
/usr/local/bin/goose -dir /app/migrations postgres "$DATABASE_URL" up
/usr/local/bin/river migrate-up --database-url "$DATABASE_URL"
exec /app/hub-api
