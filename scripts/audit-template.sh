#!/usr/bin/env bash
# Audit Railway's stored serializedConfig against the checked-in contract.
# Compares JSON values, not strings, and never prints variable values.
set -euo pipefail

template_id="${1:?Usage: ./scripts/audit-template.sh TEMPLATE_ID [EXPECTED_STATUS]}"
expected_status="${2:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$(railway api 'query Audit($id:String!){template(id:$id){name status serializedConfig}}' --var "id=${template_id}" --compact)"
graph="$(cd "${root}" && env -i PATH="${PATH}" HOME="${HOME}" ./node_modules/.bin/railway-iac-ts .railway/railway.ts </dev/null)"
failures=0
check() { local label="$1"; shift; if ! "$@"; then echo "mismatch: ${label}" >&2; failures=$((failures + 1)); fi; }
eq() { [[ "$1" == "$2" ]]; }

check "template name" eq "$(jq -r '.data.template.name' <<<"${template}")" "Formbricks Community Surveys"
[[ -z "${expected_status}" ]] || check "template status" eq "$(jq -r '.data.template.status' <<<"${template}")" "${expected_status}"
desired_names="$(jq -r '[.graph.resources[]|select(.type=="service")|.name]|sort|join("\n")' <<<"${graph}")"
check "service set" eq "$(jq -r '.data.template.serializedConfig.services|map(.name)|sort|join("\n")' <<<"${template}")" "${desired_names}"
check "top-level keys" eq "$(jq -c '.data.template.serializedConfig|keys' <<<"${template}")" '["buckets","services"]'
check "no buckets" eq "$(jq -c '.data.template.serializedConfig.buckets // {}|length' <<<"${template}")" 0
check "service set literal" eq "${desired_names}" $'Cube\nFormbricks\nFormbricks Hub\nFormbricks Hub Worker\nPostgreSQL\nSpiceDB\nValkey'

while IFS= read -r name; do
  desired="$(jq -c --arg n "${name}" '.graph.resources[]|select(.type=="service" and .name==$n)' <<<"${graph}")"
  actual="$(jq -c --arg n "${name}" '[.data.template.serializedConfig.services[]|select(.name==$n)][0]' <<<"${template}")"
  # Whole-object comparisons: any extra source field (commit pin, seed image),
  # build option, watch pattern or unmanaged service key fails.
  if [[ "$(jq -r '.source.image // ""' <<<"${desired}")" != "" ]]; then
    check "${name} source" eq "$(jq -cS '.source' <<<"${actual}")" "$(jq -cS '{image:.source.image}' <<<"${desired}")"
    check "${name} no build" eq "$(jq -c '.build // null' <<<"${actual}")" null
    check "${name} service keys" eq "$(jq -c 'keys' <<<"${actual}")" '["deploy","icon","name","networking","source","variables","volumeMounts"]'
  else
    check "${name} source" eq "$(jq -cS '.source' <<<"${actual}")" '{"branch":"release-v1","repo":"tech-progress/railway-template-formbricks","rootDirectory":"/"}'
    check "${name} build" eq "$(jq -cS '.build' <<<"${actual}")" "$(jq -cS '.build' <<<"${desired}")"
    check "${name} build literal" eq "$(jq -cS '.build' <<<"${actual}")" '{"builder":"DOCKERFILE","dockerfilePath":"Dockerfile","watchPatterns":["/Dockerfile","/cube/**"]}'
    check "${name} service keys" eq "$(jq -c 'keys' <<<"${actual}")" '["build","deploy","icon","name","networking","source","variables","volumeMounts"]'
  fi
  for field in startCommand healthcheckPath healthcheckTimeout; do
    check "${name} ${field}" eq "$(jq -c --arg f "${field}" '.deploy[$f] // null' <<<"${actual}")" "$(jq -c --arg f "${field}" '.deploy[$f] // null' <<<"${desired}")"
  done
  check "${name} deploy keys" eq "$(jq -c '[(.deploy//{})|to_entries[]|select(.value!=null)|.key]|sort' <<<"${actual}")" \
    "$(jq -c '[(.deploy//{})|to_entries[]|select(.value!=null)|.key] + ["numReplicas"]|unique' <<<"${desired}")"
  check "${name} one replica" eq "$(jq -c '.deploy.numReplicas' <<<"${actual}")" 1
  check "${name} restart policy" eq "$(jq -c '[.deploy.restartPolicyType, .deploy.restartPolicyMaxRetries]' <<<"${actual}")" '["ON_FAILURE",10]'
  check "${name} variable keys" eq "$(jq -c '(.variables//{})|keys|sort' <<<"${actual}")" "$(jq -c --arg n "${name}" '.[$n]|keys|sort' "${root}/template-defaults.json")"
  while IFS= read -r key; do
    check "${name} ${key} default" eq "$(jq -c --arg k "${key}" '.variables[$k].defaultValue' <<<"${actual}")" "$(jq -c --arg n "${name}" --arg k "${key}" '.[$n][$k]' "${root}/template-defaults.json")"
    check "${name} ${key} required" eq "$(jq -c --arg k "${key}" '.variables[$k].isOptional' <<<"${actual}")" false
    check "${name} ${key} description" eq "$(jq -c --arg k "${key}" '.variables[$k].description' <<<"${actual}")" "$(jq -c --arg n "${name}" --arg k "${key}" '.[$n][$k]' "${root}/template-descriptions.json")"
  done < <(jq -r --arg n "${name}" '.[$n]|keys[]' "${root}/template-defaults.json")
  if jq -e --arg n "${name}" '.[$n]!=null' "${root}/template-volumes.json" >/dev/null; then
    check "${name} volume" eq "$(jq -c '[((.volumeMounts//{})|length), ((.volumeMounts//{})|to_entries[0].value|{mountPath,sizeMB})]' <<<"${actual}")" "$(jq -c --arg n "${name}" '[1, .[$n]]' "${root}/template-volumes.json")"
  else
    check "${name} no volume" eq "$(jq -r '(.volumeMounts//{})|length' <<<"${actual}")" 0
  fi
  if jq -e --arg n "${name}" '.[$n].publicPort!=null' "${root}/template-networking.json" >/dev/null; then
    check "${name} domain" eq "$(jq -c '[((.networking.serviceDomains//{})|length), .networking.serviceDomains["<hasDomain>"].port]' <<<"${actual}")" "$(jq -c --arg n "${name}" '[1, .[$n].publicPort]' "${root}/template-networking.json")"
  else
    check "${name} private" eq "$(jq -r '(.networking.serviceDomains//{})|length' <<<"${actual}")" 0
  fi
  check "${name} no tcp proxy" eq "$(jq -r '(.networking.tcpProxies//{})|length' <<<"${actual}")" 0
  # Any other networking entry (custom domains or a future ingress type) fails.
  check "${name} no other ingress" eq "$(jq -r '[(.networking//{})|to_entries[]|select(.key!="serviceDomains" and .key!="tcpProxies")|select(.value!=null and .value!={} and .value!=[])]|length' <<<"${actual}")" 0
done <<<"${desired_names}"

(( failures == 0 )) || { echo "Formbricks template audit failed with ${failures} mismatch(es)." >&2; exit 1; }
echo "Template ${template_id} matches the Formbricks source, start, variable, volume, and networking contract."
