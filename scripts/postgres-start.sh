# PostgreSQL start contract. .railway/railway.ts joins the non-comment lines with
# "; " into the Railway start command and compose.yaml runs this file, so every
# line must be a complete command and no command line may contain a single quote.
# 1. SpiceDB gets its own role and database (upstream docker/authzed-postgres-bootstrap.sh). Check the password before it reaches SQL.
case "${SPICEDB_DATABASE_PASSWORD:-}" in ""|*[!A-Za-z0-9]*) echo "Refusing to start: SPICEDB_DATABASE_PASSWORD must be letters and digits." >&2; exit 64;; esac
if [ "${#SPICEDB_DATABASE_PASSWORD}" -lt 24 ]; then echo "Refusing to start: SPICEDB_DATABASE_PASSWORD must have at least 24 characters." >&2; exit 64; fi
# 2. The official entrypoint runs this file only while it initializes an empty data directory.
mkdir -p /docker-entrypoint-initdb.d
printf "CREATE ROLE spicedb LOGIN PASSWORD \$spicedb\$%s\$spicedb\$;\nCREATE DATABASE spicedb OWNER spicedb;\n" "$SPICEDB_DATABASE_PASSWORD" > /docker-entrypoint-initdb.d/10-spicedb.sql
chown postgres:postgres /docker-entrypoint-initdb.d/10-spicedb.sql
chmod 0600 /docker-entrypoint-initdb.d/10-spicedb.sql
# 3. Hand over to the official entrypoint.
exec docker-entrypoint.sh postgres
