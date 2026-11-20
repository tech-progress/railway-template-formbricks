# SpiceDB start contract (joined like postgres-start.sh). Runs on the -debug
# image, which adds a BusyBox shell to the same spicedb binary.
# 1. Apply SpiceDB's schema migrations, retrying while PostgreSQL starts (the migrate command does not retry by itself).
n=0; until spicedb datastore migrate head; do n=$((n + 1)); if [ "$n" -ge 60 ]; then echo "SpiceDB could not migrate its datastore." >&2; exit 1; fi; echo "Waiting for PostgreSQL"; sleep 5; done
# 2. Serve gRPC on 50051 for Formbricks and /healthz on 8443 for Railway, with the preshared key from SPICEDB_GRPC_PRESHARED_KEY and telemetry off (upstream sets an empty endpoint).
exec spicedb serve --telemetry-endpoint=""
