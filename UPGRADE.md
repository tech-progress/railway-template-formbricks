# Upgrades

1. Back up the PostgreSQL volume. It holds the `formbricks` database (Formbricks and Hub) and the `spicedb` database.
2. Read the [Formbricks release notes](https://github.com/formbricks/formbricks/releases) and the self-hosting upgrade guide for the target version. Formbricks, Hub and Cube are released as a set: take the Hub and Cube versions from `charts/formbricks/values.yaml` and the SpiceDB version from `docker/docker-compose.yml` at the new Formbricks tag.
3. Update every image tag and digest together in `.railway/railway.ts`, `compose.yaml` and the `Dockerfile`. If upstream changed `docker/cube/`, copy its `cube.js` to `cube/cube.js` and its `schema/FeedbackRecords.js` to `cube/model/FeedbackRecords.js` (the Dockerfile copies `cube/model/` to Cube's default model directory), and update the hashes in `scripts/verify.sh`. Recheck the start steps in the image's `/home/nextjs/start.sh` against `scripts/formbricks-start.sh`, the `User`, `Account` and `Membership` columns `scripts/formbricks-guard.cjs` uses, and the `createUserAction` ID in `scripts/smoke.sh` against the image's `server-reference-manifest.json`. Bump `VERSION` and `CHANGELOG.md`.
4. Recheck `LICENSE_REVIEW.md` against the new release.
5. Run `./scripts/verify.sh`, then the local stack from empty volumes with `SMOKE_STATE=/tmp/formbricks-smoke.json SMOKE_PHASE=initial ./scripts/smoke.sh`, restart every service, and run `SMOKE_STATE=/tmp/formbricks-smoke.json SMOKE_PHASE=restart ./scripts/smoke.sh` with the same state file.
6. Tag the release, fast-forward `release-v1` (Cube rebuilds from it), and update the image digests in the published Railway template.

Formbricks, Hub and SpiceDB migrate their schemas on start and cannot be downgraded in place; restore the volume backup to roll back. Formbricks documents extra steps for upgrades that cross a major version (for example the SpiceDB migration in 6.0); follow them before deploying a new major release.
