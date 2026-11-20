# Publishing

The current template release is `v1.0.0`. The `Cube` service builds `tech-progress/railway-template-formbricks` from `release-v1` with root directory `/`; every other service runs a pinned upstream image.

1. `bun install --frozen-lockfile` and `./scripts/verify.sh`.
2. Clean local stack and smoke: `docker compose down -v`, `docker compose up -d --build`, `SMOKE_STATE=<file> SMOKE_PHASE=initial ./scripts/smoke.sh`, restart every service, `SMOKE_STATE=<file> SMOKE_PHASE=restart ./scripts/smoke.sh`, then `docker compose down -v`.
3. Sync the public distribution repository (everything except `FINDINGS.md` and `node_modules`), run `./scripts/check-standalone.sh <checkout>`, tag `v<version>`, and fast-forward `release-v1`.
4. Create a project named `formbricks-community-surveys`, link it, and run `FORMBRICKS_IAC_CUBE_SEED=1` plus fresh `FORMBRICKS_IAC_<NAME>` values (see `.railway/railway.ts`) with `railway config apply --yes`. Do not attach a domain to the source project.
5. `railway templates create --project <PROJECT_ID> --environment <ENVIRONMENT_ID> --json`, then `./scripts/restore-template-draft.sh <TEMPLATE_ID> <WORKSPACE_ID>` and `./scripts/audit-template.sh <TEMPLATE_ID>`.
6. Deploy the stored `serializedConfig` with `templateDeployV2` into a disposable project with `FORMBRICKS_OWNER_EMAIL` set. Read `FORMBRICKS_OWNER_PASSWORD` from the deployed `Formbricks` service into a 0600 file, then run both smoke phases with `BASE_URL=https://<formbricks domain>` and `PRIVATE_PROBE_HOST=<PostgreSQL private domain>` around a restart of every service. Check replicas, metrics, and that no credential appears in the logs.
7. Publish:

```bash
railway templates publish <TEMPLATE_ID> \
  --category Analytics \
  --description "Formbricks 6 surveys with Hub, Cube, SpiceDB, pgvector and Valkey" \
  --readme-file MARKETPLACE.md \
  --json
```

8. `./scripts/audit-template.sh <TEMPLATE_ID> PUBLISHED`, then from the repository root `scripts/sync-template-marketplace.sh formbricks-surveys` and `scripts/audit-template-marketplace.sh formbricks-surveys`.
9. Stop and delete the source and verification projects, prove zero running instances, and tag `formbricks-surveys-v<version>` in the monorepo.
