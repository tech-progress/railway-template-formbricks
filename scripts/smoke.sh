#!/usr/bin/env bash
# Application-level smoke test through the public Formbricks URL.
#
#   SMOKE_PHASE=initial  sign-up is closed, the owner created at boot can sign in,
#                        the setup organization, an API key, webhook SSRF refusal,
#                        a link survey answered anonymously, and the background
#                        worker closing the survey after its first response.
#   SMOKE_PHASE=restart  after restarts: the owner, organization, survey and stored
#                        response are still there, and a new survey goes through
#                        the same response and worker path.
#
# Credentials come from the environment and never appear in output or process
# arguments. Non-secret IDs are kept in SMOKE_STATE between phases.
set -euo pipefail

base_url="${BASE_URL:-http://localhost:13300}"
base_url="${base_url%/}"
phase="${SMOKE_PHASE:-initial}"
owner_email="${FORMBRICKS_OWNER_EMAIL:?Set FORMBRICKS_OWNER_EMAIL}"
: "${FORMBRICKS_OWNER_PASSWORD:?Set FORMBRICKS_OWNER_PASSWORD}"
state_file="${SMOKE_STATE:?Set SMOKE_STATE to a file path that both phases share}"
# A private host on the same network: "postgres" in Compose, the PostgreSQL
# service's railway.internal name on Railway.
private_host="${PRIVATE_PROBE_HOST:-postgres}"
# createUserAction in ghcr.io/formbricks/formbricks:6.2.1 (server-reference-manifest.json).
signup_action="7f9dce4cf2d0ebdc663e166e1b242121d198adcd03"
question_id="smokeq1aaaaaaaaaaaaaaaaa"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir:?}"' EXIT
jar="${work_dir}/cookies"
chunks="${work_dir}/chunks"
mkdir -p "${chunks}"
touch "${jar}"
chmod 600 "${jar}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }
status() { curl --silent --output /dev/null --write-out '%{http_code}' "$@"; }
redirect_of() { curl --silent --output /dev/null --write-out '%{redirect_url}' -b "${jar}" "$1"; }
# Server actions use Next.js' action protocol; the answer is an RSC payload whose
# line "1:" holds the action result.
action() {
  local id="$1" page="$2"
  curl --fail --silent --show-error -b "${jar}" -c "${jar}" -H "Next-Action: ${id}" -H 'Accept: text/x-component' \
    -H 'Content-Type: text/plain;charset=UTF-8' -H "Origin: ${base_url}" --data-binary @- "${base_url}${page}" |
    sed -n 's/^1://p'
}
# Find a server action ID by its exported name in the page's client chunks.
action_id() {
  local page="$1" name="$2" url file
  curl --fail --silent --show-error -b "${jar}" "${base_url}${page}" -o "${work_dir}/page.html"
  for url in $(grep -o '/_next/static/chunks/[^"]*\.js' "${work_dir}/page.html" | sort -u); do
    file="${chunks}/$(basename "${url}")"
    [[ -f "${file}" ]] || curl --fail --silent --show-error "${base_url}${url}" -o "${file}"
  done
  grep -ho "createServerReference)(\"[0-9a-f]\{40,\}\",[^)]*\"${name}\")" "${chunks}"/*.js 2>/dev/null |
    sed -E 's/^createServerReference\)\("([0-9a-f]+)".*/\1/' | sort -u | head -n 2 > "${work_dir}/ids"
  [[ "$(wc -l <"${work_dir}/ids")" == 1 ]] || fail "could not find exactly one ${name} on ${page}"
  cat "${work_dir}/ids"
}
# The API key reaches curl through a config descriptor, not argv.
api() { curl --fail --silent --show-error --config <(printf 'header = "x-api-key: %s"\n' "${api_key}") -H 'Content-Type: application/json' "$@"; }
owner_credentials() { jq -nc '{email:env.FORMBRICKS_OWNER_EMAIL, password:env.FORMBRICKS_OWNER_PASSWORD}'; }

wait_ready() {
  for _ in $(seq 1 150); do
    [[ "$(status "${base_url}/health/ready")" == 200 ]] && return 0
    sleep 2
  done
  fail "Formbricks /health/ready did not return 200 within 300 seconds"
}

# POST credentials JSON (stdin) to Better Auth's sign-in. Formbricks allows five
# attempts per minute and client IP, so one 429 waits out the window and retries.
sign_in_status() {
  local body code attempt
  body="$(cat)"
  for attempt in 1 2; do
    code="$(curl --silent --output "${work_dir}/login.json" --write-out '%{http_code}' -c "${jar}" -b "${jar}" \
      -H 'Content-Type: application/json' -H "Origin: ${base_url}" --data-binary @- "${base_url}/api/auth/sign-in/email" <<<"${body}")"
    [[ "${code}" == 429 && "${attempt}" == 1 ]] || break
    echo "sign-in rate limited; retrying in 61 seconds" >&2
    sleep 61
  done
  echo "${code}"
}

sign_in() {
  local code
  code="$(owner_credentials | sign_in_status)"
  [[ "${code}" == 200 ]] || fail "owner sign-in returned ${code}"
  [[ "$(jq -r '.user.email' "${work_dir}/login.json")" == "${owner_email,,}" ]] || fail "sign-in returned another account"
  rm -f "${work_dir}/login.json"
}

create_api_key() {
  local id
  id="$(action_id "/organizations/${organization_id}/settings/api-keys" createApiKeyAction)"
  jq -nc --arg org "${organization_id}" --arg ws "${workspace_id}" --arg label "smoke-${phase}-$(date +%s)" \
    '[{organizationId:$org, apiKeyData:{label:$label, workspacePermissions:[{workspaceId:$ws, permission:"write"}], organizationAccess:{accessControl:{read:false, write:false}}}}]' |
    action "${id}" "/organizations/${organization_id}/settings/api-keys" > "${work_dir}/key.json"
  api_key="$(jq -r '.data.actualKey // empty' "${work_dir}/key.json")"
  rm -f "${work_dir}/key.json"
  [[ -n "${api_key}" ]] || fail "createApiKeyAction returned no key"
  [[ "$(api "${base_url}/api/v1/management/me" | jq -r '.workspace.id')" == "${workspace_id}" ]] || fail "API key is not scoped to the workspace"
}

# Create an in-progress link survey that closes itself after one finished
# response, answer it anonymously through the public client API, and wait for
# the response pipeline (a BullMQ worker inside Formbricks, queued in Valkey)
# to mark it completed.
survey_round() {
  local name="$1" answer="$2" survey_id code
  survey_id="$(jq -nc --arg ws "${workspace_id}" --arg name "${name}" --arg q "${question_id}" \
    '{workspaceId:$ws, type:"link", name:$name, status:"inProgress", autoComplete:1,
      questions:[{id:$q, type:"openText", headline:{default:"How did the deployment go?"}, required:true, inputType:"text", charLimit:{enabled:false}}]}' |
    api --data-binary @- "${base_url}/api/v1/management/surveys" | jq -r '.data.id')"
  [[ "${survey_id}" =~ ^[a-z0-9]{25}$ ]] || fail "survey creation returned no ID"
  [[ "$(status "${base_url}/s/${survey_id}")" == 200 ]] || fail "anonymous link survey page is not served"
  code="$(jq -nc --arg s "${survey_id}" --arg q "${question_id}" --arg a "${answer}" '{surveyId:$s, finished:true, data:{($q):$a}, meta:{source:"link"}}' |
    curl --silent --output "${work_dir}/response.json" --write-out '%{http_code}' -H 'Content-Type: application/json' --data-binary @- \
      "${base_url}/api/v2/client/${workspace_id}/responses")"
  [[ "${code}" == 200 || "${code}" == 201 ]] || fail "anonymous response returned ${code}"
  for _ in $(seq 1 60); do
    [[ "$(api "${base_url}/api/v1/management/surveys/${survey_id}" | jq -r '.data.status')" == completed ]] && break
    sleep 2
  done
  [[ "$(api "${base_url}/api/v1/management/surveys/${survey_id}" | jq -r '.data.status')" == completed ]] ||
    fail "the response pipeline did not close survey ${name} within 120 seconds"
  check_response "${survey_id}" "${answer}"
  echo "${survey_id}"
}

check_response() {
  api "${base_url}/api/v1/management/responses?surveyId=$1" |
    jq -e --arg q "${question_id}" --arg a "$2" '[.data[]|select(.finished==true and .data[$q]==$a)]|length==1' >/dev/null ||
    fail "stored response for survey $1 not found"
}

wait_ready
pass "/health/ready"

# Boundary: sign-up is closed because the owner was created before the public listener opened.
[[ "$(redirect_of "${base_url}/")" == "${base_url}/auth/login"* ]] || fail "/ does not redirect to the login page"
for path in /setup/intro /setup/signup /auth/signup; do
  code="$(status "${base_url}${path}")"
  [[ "${code}" == 404 || "${code}" == 307 ]] || fail "${path} returned ${code}; setup must be closed"
done
code="$(status -H 'Content-Type: application/json' -H "Origin: ${base_url}" --data '{"email":"probe@example.com","password":"Probe12345678","name":"Probe"}' "${base_url}/api/auth/sign-up/email")"
[[ "${code}" == 404 || "${code}" == 403 ]] || fail "raw Better Auth sign-up returned ${code}"
for page in /auth/login /auth/signup /setup/signup; do
  result="$(printf '%s' '[{"name":"Probe","email":"probe@example.com","password":"Probe12345678"}]' | action "${signup_action}" "${page}" || true)"
  grep -q '"serverError":"signup_disabled"' <<<"${result}" || fail "sign-up action through ${page} was not refused"
done
code="$(printf '%s' '{"email":"probe@example.com","password":"Probe12345678"}' | sign_in_status)"
[[ "${code}" == 401 ]] || fail "probe account sign-in returned ${code}; it must not exist"
code="$(jq -nc '{email:env.FORMBRICKS_OWNER_EMAIL, password:"Wrong-password-0"}' | sign_in_status)"
[[ "${code}" == 401 ]] || fail "wrong owner password returned ${code}"
[[ "$(status "${base_url}/api/v1/management/me")" == 401 ]] || fail "management API answers without a key"
pass "sign-up closed, wrong password and anonymous API refused"

sign_in
pass "owner signs in with the generated password"

if [[ "${phase}" == initial ]]; then
  [[ "$(redirect_of "${base_url}/")" == "${base_url}/setup/organization/create"* ]] || fail "a fresh owner is not sent to organization setup"
  id="$(action_id /setup/organization/create createOrganizationAction)"
  organization_id="$(printf '%s' '[{"organizationName":"Smoke organization"}]' | action "${id}" /setup/organization/create | jq -r '.data.id // empty')"
  [[ "${organization_id}" =~ ^[a-z0-9]{25}$ ]] || fail "organization setup failed"
else
  organization_id="$(jq -r '.organization_id' "${state_file}")"
fi
id="$(action_id "/organizations/${organization_id}/settings/api-keys" getWorkspacesForSwitcherAction)"
workspace_id="$(jq -nc --arg org "${organization_id}" '[{organizationId:$org}]' | action "${id}" "/organizations/${organization_id}/settings/api-keys" | jq -r '.data[0].id // empty')"
[[ "${workspace_id}" =~ ^[a-z0-9]{25}$ ]] || fail "no workspace in organization ${organization_id}"
create_api_key
pass "organization ${organization_id}, workspace ${workspace_id} and a workspace API key"

for url in "http://${private_host}:5432/" http://127.0.0.1:3000/hook http://169.254.169.254/latest/meta-data/; do
  code="$(jq -nc --arg u "${url}" --arg ws "${workspace_id}" '{url:$u, name:"ssrf-probe", source:"user", triggers:["responseFinished"], surveyIds:[], workspaceId:$ws}' |
    curl --silent --output "${work_dir}/webhook.json" --write-out '%{http_code}' --config <(printf 'header = "x-api-key: %s"\n' "${api_key}") \
      -H 'Content-Type: application/json' --data-binary @- "${base_url}/api/v1/webhooks")"
  [[ "${code}" == 400 ]] && grep -q 'private or internal' "${work_dir}/webhook.json" || fail "webhook to ${url} was not refused (${code})"
done
pass "webhooks to private, loopback and metadata addresses are refused"

if [[ "${phase}" == initial ]]; then
  survey_id="$(survey_round "Smoke survey" "Deployed on the first try")"
  umask 077
  jq -nc --arg org "${organization_id}" --arg ws "${workspace_id}" --arg s "${survey_id}" '{organization_id:$org, workspace_id:$ws, survey_id:$s}' > "${state_file}"
  pass "survey ${survey_id} answered anonymously, response stored, closed by the worker"
else
  survey_id="$(jq -r '.survey_id' "${state_file}")"
  [[ "$(jq -r '.workspace_id' "${state_file}")" == "${workspace_id}" ]] || fail "workspace changed across the restart"
  [[ "$(api "${base_url}/api/v1/management/surveys/${survey_id}" | jq -r '.data.status')" == completed ]] || fail "survey ${survey_id} lost its state"
  check_response "${survey_id}" "Deployed on the first try"
  pass "survey ${survey_id} and its response survived the restart"
  second="$(survey_round "Smoke survey after restart" "Still working after a restart")"
  pass "survey ${second} answered and closed by the worker after the restart"
fi
echo "Formbricks smoke (${phase}) passed."
