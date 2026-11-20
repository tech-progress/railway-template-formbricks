#!/usr/bin/env bash
# Regression test for scripts/formbricks-guard.cjs against a disposable
# PostgreSQL with the User, Account and Membership columns the guard uses.
# Needs podman (or docker as CONTAINER=docker) and the pinned images; removes
# its own containers and network.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="${CONTAINER:-podman}"
formbricks="$(grep -A1 '^export const FORMBRICKS_IMAGE =$' "${root}/.railway/railway.ts" | tail -n 1 | sed -E 's/^ *"(.*)";$/\1/')"
postgres="$(grep -A1 '^export const POSTGRES_IMAGE =$' "${root}/.railway/railway.ts" | tail -n 1 | sed -E 's/^ *"(.*)";$/\1/')"
tag="fb-guard-test-$$"
cleanup() { "${engine}" rm -f -t 2 "${tag}-db" >/dev/null 2>&1 || true; "${engine}" network rm "${tag}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

"${engine}" network create "${tag}" >/dev/null
"${engine}" run -d --name "${tag}-db" --network "${tag}" --memory 256m -e POSTGRES_PASSWORD=guardtest "${postgres}" >/dev/null
for _ in $(seq 1 60); do "${engine}" exec "${tag}-db" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sql() { "${engine}" exec -i "${tag}-db" psql -q -v ON_ERROR_STOP=1 -U postgres -At "$@"; }
reset() {
  sql <<'SQL'
DROP TABLE IF EXISTS "Membership", "Account", "User";
CREATE TABLE "User" (id text PRIMARY KEY, created_at timestamp NOT NULL DEFAULT now(), updated_at timestamp NOT NULL, name text NOT NULL, email text NOT NULL UNIQUE, "isActive" boolean NOT NULL DEFAULT true);
CREATE TABLE "Account" (id text PRIMARY KEY, "userId" text NOT NULL REFERENCES "User"(id) ON DELETE CASCADE, provider text NOT NULL);
CREATE TABLE "Membership" ("userId" text NOT NULL REFERENCES "User"(id) ON DELETE CASCADE, "organizationId" text NOT NULL);
SQL
}
guard() {
  "${engine}" run --rm --network "${tag}" --memory 256m -e DATABASE_URL="postgresql://postgres:guardtest@${tag}-db:5432/postgres?schema=public" \
    -v "${root}/scripts/formbricks-guard.cjs:/tmp/formbricks-guard.cjs:ro" --entrypoint node "${formbricks}" /tmp/formbricks-guard.cjs "$@" 2>/dev/null
}
emails() { sql -c "SELECT coalesce(string_agg(email, ',' ORDER BY email), '') FROM \"User\""; }

# 1. First start: fresh, then the sentinel is inserted and later starts are initialized.
reset
[[ "$(guard pre)" == fresh ]] || fail "empty database is not fresh"
sql -c "INSERT INTO \"User\" (id, updated_at, name, email) VALUES ('owner1', now(), 'Owner', 'owner@example.com'); INSERT INTO \"Account\" VALUES ('a1', 'owner1', 'credential')"
guard post >/dev/null
[[ "$(emails)" == "bootstrap-sentinel@formbricks.invalid,owner@example.com" ]] || fail "post did not add the sentinel"
[[ "$(guard pre)" == initialized ]] || fail "provisioned database is not initialized"

# 2. The owner deletes their account while public: the sentinel stays and pre deletes nothing.
sql -c "DELETE FROM \"User\" WHERE email = 'owner@example.com'"
[[ "$(guard pre)" == initialized ]] || fail "sentinel-only database must stay initialized"
[[ "$(emails)" == "bootstrap-sentinel@formbricks.invalid" ]] || fail "pre removed the sentinel"

# 3. Interrupted first start (user without credential), then the owner email changes: removed, fresh.
reset
sql -c "INSERT INTO \"User\" (id, updated_at, name, email) VALUES ('stale', now(), 'Owner', 'first@example.com')"
[[ "$(guard pre)" == fresh ]] || fail "a credential-less leftover must not count as initialized"
[[ "$(emails)" == "" ]] || fail "the leftover row was not removed"

# 4. Crash after the owner and credential were written but before the sentinel: initialized, nothing removed.
reset
sql -c "INSERT INTO \"User\" (id, updated_at, name, email) VALUES ('owner1', now(), 'Owner', 'owner@example.com'); INSERT INTO \"Account\" VALUES ('a1', 'owner1', 'credential')"
[[ "$(guard pre)" == initialized ]] || fail "an owner with a credential must count as initialized"
[[ "$(emails)" == "owner@example.com" ]] || fail "pre removed a credentialed owner"

# 5. A real account at the reserved sentinel address is refused, not deleted.
reset
sql -c "INSERT INTO \"User\" (id, updated_at, name, email) VALUES ('x', now(), 'Owner', 'bootstrap-sentinel@formbricks.invalid'); INSERT INTO \"Account\" VALUES ('a1', 'x', 'credential')"
if guard pre >/dev/null; then fail "a real account at the sentinel address was accepted"; fi
[[ "$(emails)" == "bootstrap-sentinel@formbricks.invalid" ]] || fail "the account at the sentinel address was removed"

# 6. The start script refuses the reserved address before touching the database.
code=0
"${engine}" run --rm --memory 128m -v "${root}/scripts:/template/scripts:ro" -e FORMBRICKS_OWNER_EMAIL=bootstrap-sentinel@formbricks.invalid \
  -e FORMBRICKS_OWNER_PASSWORD=Fb7Abcdefghijklmnop123 --entrypoint /bin/sh "${formbricks}" -ec '. /template/scripts/formbricks-start.sh' >/dev/null 2>&1 || code=$?
[[ "${code}" == 64 ]] || fail "the start script accepted the reserved owner address (exit ${code})"

echo "Bootstrap guard: fresh start, owner deletion, interrupted bootstrap with a changed email, late crash, and the reserved address all behave."
