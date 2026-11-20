# Formbricks Hub worker start contract (joined like postgres-start.sh).
# 1. The Hub API applies Hub's migrations before it answers /health.
until wget -q -O /dev/null "$HUB_HEALTH_URL"; do echo "Waiting for the Hub API"; sleep 3; done
# 2. The worker processes Hub's asynchronous jobs, including webhook deliveries.
exec /app/hub-worker
