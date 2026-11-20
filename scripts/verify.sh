#!/usr/bin/env bash
# Static verification: files, version, pins, start contracts, IaC graph, and
# Compose/Railway parity. Needs bun's node_modules, jq and python3; never
# prints secret values.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

for file in .dockerignore .env.example .gitignore .railway/railway.ts CHANGELOG.md Dockerfile LICENSE_REVIEW.md MARKETPLACE.md PUBLISHING.md README.md SUPPORT.md UPGRADE.md VERSION bun.lock compose.yaml package.json \
  cube/LICENSE cube/cube.js cube/model/FeedbackRecords.js template-defaults.json template-descriptions.json template-networking.json template-volumes.json \
  scripts/audit-template.sh scripts/check-standalone.sh scripts/restore-template-draft.sh scripts/smoke.sh \
  scripts/formbricks-start.sh scripts/hub-start.sh scripts/hub-worker-start.sh scripts/postgres-start.sh scripts/spicedb-start.sh; do
  [[ -f "${root}/${file}" ]] || fail "missing ${file}"
done

version="$(<"${root}/VERSION")"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION is not SemVer"
grep -Eq "^## ${version//./\\.} - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "${root}/CHANGELOG.md" || fail "CHANGELOG has no entry for ${version}"
for file in README.md PUBLISHING.md; do grep -Fq "current template release is \`v${version}\`" "${root}/${file}" || fail "${file} does not name v${version}"; done

for file in "${root}"/template-*.json "${root}/package.json"; do jq empty "${file}"; done
for file in "${root}"/scripts/*.sh; do bash -n "${file}"; done
for name in formbricks hub hub-worker postgres spicedb; do
  ! grep -v '^[[:space:]]*#' "${root}/scripts/${name}-start.sh" | grep -q "'" || fail "a command line in scripts/${name}-start.sh contains a single quote"
done

# Cube's configuration is upstream's docker/cube at Formbricks 6.2.1, unchanged.
(cd "${root}/cube" && sha256sum --check --quiet) <<'EOF' || fail "cube/ differs from Formbricks 6.2.1 docker/cube"
767beed28f34be588e91bc3699f55f7a12ec8aa4512bc56dca4ae515160f8b83  cube.js
cedd5ab92c4315178686a199f0eaaa15da1e5d34c3a28c7c1501b3aef7e9a4cd  model/FeedbackRecords.js
EOF
grep -q 'GNU AFFERO GENERAL PUBLIC LICENSE' "${root}/cube/LICENSE" || fail "cube/LICENSE is not the Formbricks AGPL license text"
! grep -Eq '^VOLUME' "${root}/Dockerfile" || fail "Railway rejects Dockerfile VOLUME"

graph="$(cd "${root}" && env -u FORMBRICKS_IAC_CUBE_SEED ./node_modules/.bin/railway-iac-ts .railway/railway.ts </dev/null)"
jq -e '.ok==true' <<<"${graph}" >/dev/null || fail "IaC graph did not compile"
svc() { jq -c --arg n "$1" '.graph.resources[]|select(.type=="service" and .name==$n)' <<<"${graph}"; }
jq -e '([.graph.resources[]|select(.type=="service")|.name]|sort)==["Cube","Formbricks","Formbricks Hub","Formbricks Hub Worker","PostgreSQL","SpiceDB","Valkey"]' <<<"${graph}" >/dev/null || fail "IaC service set"
jq -e '([.graph.resources[]|select(.type=="volume")]|length)==2' <<<"${graph}" >/dev/null || fail "IaC volume count"
jq -e '[.graph.resources[]|select(.type=="service")|(.domains // .networking // empty)]|length==0' <<<"${graph}" >/dev/null || fail "the source graph must not create domains"

# Every image in the graph is pinned by digest and matches compose.yaml.
pin() { grep -A1 "^export const $1 =\$" "${root}/.railway/railway.ts" | tail -n 1 | sed -E 's/^ *"(.*)";$/\1/'; }
for const in FORMBRICKS_IMAGE HUB_IMAGE CUBE_BASE_IMAGE SPICEDB_IMAGE POSTGRES_IMAGE VALKEY_IMAGE; do
  image="$(pin "${const}")"
  [[ "${image}" =~ :[^@]+@sha256:[0-9a-f]{64}$ ]] || fail "${const} is not pinned by tag and digest"
  if [[ "${const}" == CUBE_BASE_IMAGE ]]; then
    grep -Fxq "FROM ${image}" "${root}/Dockerfile" || fail "Dockerfile does not build on ${const}"
  else
    grep -Eq "image: (docker\.io/)?${image//./\\.}\$" "${root}/compose.yaml" || fail "compose.yaml does not use ${const}"
  fi
done
for name in Formbricks "Formbricks Hub" "Formbricks Hub Worker" PostgreSQL SpiceDB Valkey; do
  jq -e '.source.image|test("@sha256:[0-9a-f]{64}$")' <<<"$(svc "${name}")" >/dev/null || fail "${name} image is not pinned"
done
jq -e '.source.repo=="tech-progress/railway-template-formbricks" and .source.branch=="release-v1" and .source.rootDirectory=="/" and .build.builder=="DOCKERFILE" and .build.dockerfilePath=="Dockerfile" and .deploy.healthcheckPath=="/readyz"' <<<"$(svc Cube)" >/dev/null || fail "Cube source or health check"
seeded="$(cd "${root}" && FORMBRICKS_IAC_CUBE_SEED=1 ./node_modules/.bin/railway-iac-ts .railway/railway.ts </dev/null)"
jq -e --arg img "$(pin CUBE_BASE_IMAGE)" '.graph.resources[]|select(.name=="Cube")|.source.image==$img and .build==null' <<<"${seeded}" >/dev/null || fail "seeded Cube must use the base image only"

# Start commands are the joined scripts, and Compose runs the same files.
for pair in "Formbricks:formbricks" "Formbricks Hub:hub" "Formbricks Hub Worker:hub-worker" "PostgreSQL:postgres" "SpiceDB:spicedb"; do
  name="${pair%%:*}"; script="${pair#*:}"
  expected="/bin/sh -ec '$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${root}/scripts/${script}-start.sh" | awk 'NR > 1 { printf "; " } { printf "%s", $0 }')'"
  [[ "$(jq -r '.deploy.startCommand' <<<"$(svc "${name}")")" == "${expected}" ]] || fail "${name} start command is not scripts/${script}-start.sh"
  grep -Fq "command: [\". /template/scripts/${script}-start.sh\"]" "${root}/compose.yaml" || fail "compose.yaml does not run scripts/${script}-start.sh"
done
for pair in "Formbricks:/health/ready" "Formbricks Hub:/health" "SpiceDB:/healthz" "Cube:/readyz"; do
  [[ "$(jq -r '.deploy.healthcheckPath' <<<"$(svc "${pair%%:*}")")" == "${pair#*:}" ]] || fail "${pair%%:*} health check"
done
for name in Cube Formbricks "Formbricks Hub" "Formbricks Hub Worker" PostgreSQL SpiceDB Valkey; do
  jq -e '.deploy.restartPolicyType=="ON_FAILURE" and .deploy.restartPolicyMaxRetries==10' <<<"$(svc "${name}")" >/dev/null || fail "${name} restart policy"
done

# The source graph never derives a credential; the draft defaults generate them.
for pair in "Formbricks:BETTER_AUTH_SECRET" "Formbricks:ENCRYPTION_KEY" "Formbricks:CRON_SECRET" "Formbricks:FORMBRICKS_OWNER_PASSWORD" "Formbricks Hub:API_KEY" \
  "Cube:CUBEJS_API_SECRET" "SpiceDB:SPICEDB_GRPC_PRESHARED_KEY" "PostgreSQL:POSTGRES_PASSWORD" "PostgreSQL:SPICEDB_DATABASE_PASSWORD" "Valkey:VALKEY_PASSWORD"; do
  name="${pair%%:*}"; key="${pair#*:}"
  [[ "$(jq -r --arg k "${key}" '.variables[$k].value' <<<"$(svc "${name}")")" == "" ]] || fail "IaC derives ${name} ${key} without FORMBRICKS_IAC_*"
  jq -e --arg n "${name}" --arg k "${key}" '.[$n][$k]|test("\\$\\{\\{secret\\(")' "${root}/template-defaults.json" >/dev/null || fail "${name} ${key} default is not generated"
done
jq -e '.Formbricks.FORMBRICKS_OWNER_PASSWORD|test("^Fb7\\$\\{\\{secret\\(29, \"[A-Za-z0-9]+\"\\)\\}\\}$")' "${root}/template-defaults.json" >/dev/null || fail "owner password default must guarantee a capital and a digit"
jq -e '.Formbricks.FORMBRICKS_OWNER_EMAIL==""' "${root}/template-defaults.json" >/dev/null || fail "the deployer must supply FORMBRICKS_OWNER_EMAIL"
jq -e '[.[]|to_entries[]|select(.value=="")]|map(.key)==["FORMBRICKS_OWNER_EMAIL"]' "${root}/template-defaults.json" >/dev/null || fail "only FORMBRICKS_OWNER_EMAIL may default to empty"
! grep -q 'ENTERPRISE_LICENSE_KEY' "${root}/template-defaults.json" "${root}/compose.yaml" || fail "the community template must not set ENTERPRISE_LICENSE_KEY"
python3 -I - "${root}" <<'EOF' || fail "template-defaults.json and template-descriptions.json keys differ"
import json, sys
root = sys.argv[1]
d = json.load(open(f"{root}/template-defaults.json")); s = json.load(open(f"{root}/template-descriptions.json"))
sys.exit(0 if all(set(d[k]) == set(s.get(k, {})) for k in d) and set(d) == set(s) else 1)
EOF
jq -e 'keys==["Formbricks"] and .Formbricks.publicPort==3000' "${root}/template-networking.json" >/dev/null || fail "only Formbricks may be public"
for name in PostgreSQL Valkey; do
  mount="$(jq -r --arg n "${name}" '.[$n].mountPath' "${root}/template-volumes.json")"
  size="$(jq -r --arg n "${name}" '.[$n].sizeMB' "${root}/template-volumes.json")"
  jq -e --arg s "service.${name}" --arg m "${mount}" --argjson size "${size}" \
    '[.graph.edges[]|select(.from==$s and .type=="mount")] as $e | ($e|length)==1 and $e[0].key==$m and ([.graph.resources[]|select(.address==$e[0].to)][0].config.sizeMB==$size)' \
    <<<"${graph}" >/dev/null || fail "${name} volume mount differs from template-volumes.json"
done

# Literal (non-secret, non-reference) values match between Compose and the template.
compose_json="$(cd "${root}" && python3 -I -c '
import json, re, sys
try:
    import yaml
except ImportError:
    sys.exit(3)
print(json.dumps(yaml.safe_load(open("compose.yaml"))))' 2>/dev/null || true)"
if [[ -n "${compose_json}" ]]; then
  for pair in "Formbricks:formbricks" "Formbricks Hub:hub" "Cube:cube" "SpiceDB:spicedb" "PostgreSQL:postgres"; do
    name="${pair%%:*}"; svc_key="${pair#*:}"
    while IFS= read -r key; do
      expected="$(jq -r --arg n "${name}" --arg k "${key}" '.[$n][$k]' "${root}/template-defaults.json")"
      [[ "${expected}" == *'${{'* ]] && continue
      actual="$(jq -r --arg s "${svc_key}" --arg k "${key}" '.services[$s].environment[$k] // "__MISSING__"' <<<"${compose_json}")"
      [[ "${actual}" == "${expected}" || "${actual}" == *'${'* ]] || fail "compose ${svc_key} ${key} differs from the template"
    done < <(jq -r --arg n "${name}" '.[$n]|keys[]' "${root}/template-defaults.json")
  done
else
  echo "note: PyYAML is not installed; skipped the Compose literal-variable parity check" >&2
fi

for heading in '# Deploy and Host' '## About Hosting' '## Why Deploy' '## Common Use Cases' '## Dependencies for' '### Deployment Dependencies'; do
  grep -q "^${heading}" "${root}/MARKETPLACE.md" || fail "MARKETPLACE.md lacks ${heading}"
done
! grep -q '<[A-Za-z_-]*>' "${root}/MARKETPLACE.md" || fail "MARKETPLACE.md has angle-bracket placeholders the renderer removes"
description="$(sed -n 's/^  --description "\(.*\)" \\$/\1/p' "${root}/PUBLISHING.md")"
(( ${#description} >= 45 && ${#description} <= 75 )) || fail "marketplace description must be 45-75 characters"
for link in https://github.com/formbricks/formbricks https://hub.formbricks.com https://github.com/authzed/spicedb https://github.com/pgvector/pgvector; do
  grep -Fq "${link}" "${root}/README.md" || fail "README.md does not link ${link}"
done

# The smoke test's createUserAction ID belongs to the pinned image (checked when the image is present locally).
if command -v podman >/dev/null && podman image exists "$(pin FORMBRICKS_IMAGE)" 2>/dev/null; then
  action="$(sed -n 's/^signup_action="\(.*\)"$/\1/p' "${root}/scripts/smoke.sh")"
  podman run --rm --memory 256m --entrypoint node "$(pin FORMBRICKS_IMAGE)" -e \
    'const m=require("/home/nextjs/apps/web/.next/server/server-reference-manifest.json").node[process.argv[1]]; process.exit(m && m.exportedName==="createUserAction" ? 0 : 1)' "${action}" ||
    fail "scripts/smoke.sh signup_action is not createUserAction in the pinned image"
fi
echo "Formbricks template structure, pins, start contracts, IaC graph and marketplace copy are valid."
