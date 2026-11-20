# Formbricks start contract. .railway/railway.ts joins the non-comment lines with
# "; " into the Railway start command and compose.yaml runs this file, so every
# line must be a complete command and no command line may contain a single quote.
# It replaces the image's /home/nextjs/start.sh and keeps its steps in order.
# 1. Validate the owner address and the generated owner password before they reach JSON. Formbricks requires a capital letter and a digit.
owner=$(printf "%s" "${FORMBRICKS_OWNER_EMAIL:-}" | tr -d " \t\r" | tr "A-Z" "a-z")
case "$owner" in ""|*[!a-z0-9._%+@-]*) echo "Refusing to start: set FORMBRICKS_OWNER_EMAIL to the email address of the first administrator." >&2; exit 64;; esac
if ! printf "%s" "$owner" | grep -Eq "^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,}$"; then echo "Refusing to start: FORMBRICKS_OWNER_EMAIL is not a plain email address." >&2; exit 64; fi
case "${FORMBRICKS_OWNER_PASSWORD:-}" in ""|*[!A-Za-z0-9]*) echo "Refusing to start: FORMBRICKS_OWNER_PASSWORD must be letters and digits." >&2; exit 64;; esac
case "$FORMBRICKS_OWNER_PASSWORD" in *[A-Z]*) ;; *) echo "Refusing to start: FORMBRICKS_OWNER_PASSWORD needs a capital letter." >&2; exit 64;; esac
case "$FORMBRICKS_OWNER_PASSWORD" in *[0-9]*) ;; *) echo "Refusing to start: FORMBRICKS_OWNER_PASSWORD needs a digit." >&2; exit 64;; esac
if [ "${#FORMBRICKS_OWNER_PASSWORD}" -lt 16 ] || [ "${#FORMBRICKS_OWNER_PASSWORD}" -gt 128 ]; then echo "Refusing to start: FORMBRICKS_OWNER_PASSWORD must have 16 to 128 characters." >&2; exit 64; fi
# 2. Upstream environment validation, as in start.sh.
export NODE_ENV=production
node /home/nextjs/validate-env.mjs --server
# 3. Wait for PostgreSQL, then run the migration and SAML steps of start.sh.
db_host=$(printf "%s" "$DATABASE_URL" | sed -E "s#^[a-z]+://[^@]*@([^:/?]+).*#\1#")
until nc -z -w 3 "$db_host" 5432; do echo "Waiting for PostgreSQL"; sleep 2; done
timeout 300 node packages/database/dist/scripts/apply-migrations.js
timeout 60 node packages/database/dist/scripts/create-saml-database.js
# 4. Write the Formbricks authorization schema to SpiceDB (upstream authzed-initialize), retrying while SpiceDB starts.
n=0; until formbricks-authzed upgrade prepare; do n=$((n + 1)); if [ "$n" -ge 60 ]; then echo "Formbricks could not prepare SpiceDB." >&2; exit 1; fi; echo "Waiting for SpiceDB"; sleep 5; done
# 5. Provisioning boot: Formbricks listens on loopback only, unreachable by Railway's proxy, health check and other services.
HOSTNAME=127.0.0.1 env -u FORMBRICKS_OWNER_PASSWORD node apps/web/online-server.js & pid=$!
trap "kill -TERM $pid 2>/dev/null; exit 143" TERM INT
until wget -q -O /dev/null "http://127.0.0.1:${PORT}/health/ready"; do if ! kill -0 "$pid" 2>/dev/null; then echo "Formbricks exited during the provisioning boot." >&2; exit 1; fi; sleep 2; done
# 6. Create the owner through Formbricks own sign-up action, found by name in the build manifest. A fresh instance admits exactly one uninvited sign-up.
action=$(node -e "const [file, name, source] = process.argv.slice(1); const actions = require(file).node; const ids = Object.keys(actions).filter((id) => actions[id].exportedName === name && actions[id].filename === source); if (ids.length !== 1) process.exit(1); console.log(ids[0]);" /home/nextjs/apps/web/.next/server/server-reference-manifest.json createUserAction apps/web/modules/auth/signup/actions.ts)
umask 077
printf "[{\"name\":\"Owner\",\"email\":\"%s\",\"password\":\"%s\"}]" "$owner" "$FORMBRICKS_OWNER_PASSWORD" > /tmp/formbricks-owner.json
wget -q -O /tmp/formbricks-owner.out --header "Next-Action: $action" --header "Accept: text/x-component" --header "Content-Type: text/plain;charset=UTF-8" --header "Origin: http://127.0.0.1:${PORT}" --post-file /tmp/formbricks-owner.json "http://127.0.0.1:${PORT}/setup/signup" || true
rm -f /tmp/formbricks-owner.json
# 7. The public listener never opens before the owner exists, so a closed sign-up on a later boot means this step already ran.
if grep -q "\"success\":true" /tmp/formbricks-owner.out 2>/dev/null; then echo "Created the Formbricks owner account for $owner."; elif grep -q "signup_disabled" /tmp/formbricks-owner.out 2>/dev/null; then echo "Formbricks already has an owner account."; else echo "Owner bootstrap failed; stopping." >&2; kill -TERM "$pid"; wait "$pid" || true; exit 1; fi
rm -f /tmp/formbricks-owner.out
kill -TERM "$pid" 2>/dev/null || true; wait "$pid" || true
trap - TERM INT
# 8. Public boot on HOSTNAME (::) without the owner password.
exec env -u FORMBRICKS_OWNER_PASSWORD node apps/web/online-server.js
