#!/usr/bin/env bash
# Offline test of restore-template-draft.sh and audit-template.sh. A stub
# `railway` serves scripts/fixtures/draft.json (a restored, audited draft) with
# one mutation applied, and a stub `curl` captures what restore would upload.
# Every mutation must fail the audit, and restoring it must produce a draft that
# passes the audit again. No network access and no Railway credentials are used.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT
mkdir -p "${work}/bin"
printf '{"user":{"accessToken":"offline-test-token"}}\n' > "${work}/config.json"

cat > "${work}/bin/railway" <<'EOF'
#!/usr/bin/env bash
cat "${FIXTURE:?}"
EOF
cat > "${work}/bin/curl" <<'EOF'
#!/usr/bin/env bash
body="$(cat)"
if grep -q templateUpsertConfig <<<"${body}"; then
  jq -c '.variables.input.serializedConfig' <<<"${body}" > "${CAPTURE:?}"
  echo '{"data":{"templateUpsertConfig":{"id":"t","code":"c"}}}'
else
  jq -c '{data:{templateUpsertSettings:{id:"t", name:.variables.input.name}}}' <<<"${body}"
fi
EOF
real_jq="$(command -v jq)"
cat > "${work}/bin/jq" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${work}/jq-argv.log"
exec "${real_jq}" "\$@"
EOF
chmod +x "${work}/bin/railway" "${work}/bin/curl" "${work}/bin/jq"
export PATH="${work}/bin:${PATH}" RAILWAY_CONFIG_PATH="${work}/config.json"

# The fixture is a stored draft; restoring it first applies the current start
# commands and defaults, so the base always reflects the checked-in contract.
FIXTURE="${root}/scripts/fixtures/draft.json" CAPTURE="${work}/base-config.json" "${root}/scripts/restore-template-draft.sh" fixture workspace >/dev/null
jq --slurpfile c "${work}/base-config.json" '.data.template.serializedConfig = $c[0]' "${root}/scripts/fixtures/draft.json" > "${work}/base.json"
base="${work}/base.json"
svc() { printf '(.data.template.serializedConfig.services|to_entries[]|select(.value.name=="%s")|.key) as $k | .data.template.serializedConfig.services[$k]' "$1"; }
mutations=(
  "$(svc Cube).configFile = \"/railway.json\""
  "$(svc Formbricks).configFile = \"/railway.json\""
  "$(svc Cube).build.buildCommand = \"echo extra\""
  "$(svc Cube).build.watchPatterns = [\"/**\"]"
  "$(svc Cube).source.commitSha = \"0123456789abcdef0123456789abcdef01234567\""
  "$(svc Cube).source.image = \"ghcr.io/formbricks/cube:1.8.8-3\""
  "$(svc Formbricks).source.repo = \"tech-progress/railway-template-formbricks\""
  "$(svc Formbricks).build = {\"builder\":\"NIXPACKS\"}"
  "$(svc Formbricks).deploy.preDeployCommand = \"echo pre\""
  "$(svc SpiceDB).deploy.numReplicas = 2"
  "$(svc Formbricks).networking.customDomains = {\"x.example.com\":{\"port\":3000}}"
  "$(svc PostgreSQL).networking.serviceDomains = {\"<hasDomain>\":{\"port\":5432}}"
  "$(svc Valkey).volumeMounts |= with_entries(.value.sizeMB = 5000)"
  "$(svc Formbricks).variables.FORMBRICKS_OWNER_PASSWORD.defaultValue = \"Fb7Known1234567890abcdef12345678\""
  "$(svc Formbricks).variables.ENTERPRISE_LICENSE_KEY = {\"defaultValue\":\"x\",\"isOptional\":false,\"description\":\"\"}"
  ".data.template.serializedConfig.buckets = {\"b\":{\"name\":\"bucket\"}}"
)

FIXTURE="${base}" "${root}/scripts/audit-template.sh" fixture UNPUBLISHED >/dev/null || { echo "FAIL: the unmodified fixture does not pass the audit" >&2; exit 1; }
failures=0
for mutation in "${mutations[@]}"; do
  jq "${mutation}" "${base}" > "${work}/mutated.json"
  if FIXTURE="${work}/mutated.json" "${root}/scripts/audit-template.sh" fixture UNPUBLISHED >/dev/null 2>&1; then
    echo "FAIL: audit accepted: ${mutation##*) }" >&2; failures=$((failures + 1)); continue
  fi
  FIXTURE="${work}/mutated.json" CAPTURE="${work}/restored-config.json" "${root}/scripts/restore-template-draft.sh" fixture workspace >/dev/null
  jq --slurpfile c "${work}/restored-config.json" '.data.template.serializedConfig = $c[0]' "${work}/mutated.json" > "${work}/restored.json"
  if ! FIXTURE="${work}/restored.json" "${root}/scripts/audit-template.sh" fixture UNPUBLISHED >/dev/null 2>&1; then
    echo "FAIL: restore did not repair: ${mutation##*) }" >&2; failures=$((failures + 1))
  fi
done
# A source-project credential exported for `railway config apply` must not reach
# any jq argument list while restore runs.
: > "${work}/jq-argv.log"
FIXTURE="${base}" CAPTURE="${work}/ambient.json" FORMBRICKS_IAC_POSTGRES_PASSWORD=AmbientDummy0123456789 FORMBRICKS_IAC_OWNER_PASSWORD=Fb7AmbientDummy0123456789 \
  "${root}/scripts/restore-template-draft.sh" fixture workspace >/dev/null
if grep -q AmbientDummy "${work}/jq-argv.log" "${work}/ambient.json"; then
  echo "FAIL: an ambient FORMBRICKS_IAC_* value reached jq arguments or the restored draft" >&2; failures=$((failures + 1))
fi
(( failures == 0 )) || exit 1
echo "Draft contract: the fixture passes, ${#mutations[@]} mutations fail the audit, and restore repairs each."
