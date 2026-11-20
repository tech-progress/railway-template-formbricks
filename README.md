# Formbricks Community Surveys on Railway

The current template release is `v1.0.0`. It runs the AGPL-3.0 community edition of [Formbricks](https://github.com/formbricks/formbricks) `6.2.1` with [Formbricks Hub](https://hub.formbricks.com) `0.14.3`, [Cube](https://cube.dev) `1.8.8` (Formbricks' build), [SpiceDB](https://github.com/authzed/spicedb) `1.57.0`, PostgreSQL 18 with [pgvector](https://github.com/pgvector/pgvector) `0.8.7` and [Valkey](https://valkey.io) `9.1.2`, every image pinned by digest.

Formbricks is an open-source survey and experience-management platform: link surveys, website and in-app surveys, NPS and CSAT, response analysis, webhooks and a management API. This template deploys the same service set as upstream's Docker Compose file for Formbricks 6, adapted to Railway's private networking and volumes.

## Topology

| Service | Public | Source | Purpose |
| --- | --- | --- | --- |
| `Formbricks` | yes, port 3000 | `ghcr.io/formbricks/formbricks:6.2.1` by digest | Web app, public survey pages, client and management APIs, and the in-process background worker (response pipeline, webhooks, survey auto-close). Runs database migrations and prepares SpiceDB on start. |
| `Formbricks Hub` | no | `ghcr.io/formbricks/hub:0.14.3` by digest | Feedback-record API that Formbricks 6 requires. Applies its own migrations after Formbricks'. |
| `Formbricks Hub Worker` | no | same Hub image | Processes Hub's asynchronous jobs. |
| `Cube` | no | this repository, `release-v1` branch, `Dockerfile` | `ghcr.io/formbricks/cube:1.8.8-3` by digest plus Formbricks' Cube configuration and data model (`cube/`, copied unchanged from Formbricks 6.2.1), because Railway cannot mount files. |
| `SpiceDB` | no | `authzed/spicedb:v1.57.0-debug` by digest | Authorization service Formbricks 6 requires. The `-debug` variant adds a shell so the start command can retry the schema migration while PostgreSQL starts. |
| `PostgreSQL` | no | `pgvector/pgvector:0.8.7-pg18` by digest | One server, two databases: `formbricks` (Formbricks and Hub) and `spicedb` (its own role). 5 GB volume at `/var/lib/postgresql`. |
| `Valkey` | no | `valkey/valkey:9.1.2` by digest | Password-protected sessions, rate limits and the background job queue, with append-only persistence on a 1 GB volume at `/data`. |

Only `Formbricks` has a public domain. Every other service is reachable only over Railway's private network, and each one has its own generated credential.

### The owner account is created before the app goes public

A fresh Formbricks instance lets whoever signs up first become its administrator. This template closes that race: on every start, Formbricks first boots bound to `127.0.0.1` only, where Railway's proxy, health check and other services cannot reach it, and creates the owner account for `FORMBRICKS_OWNER_EMAIL` with the generated `FORMBRICKS_OWNER_PASSWORD` through Formbricks' own sign-up action. Only then does it restart on its public listener. From that moment Formbricks itself refuses uninvited sign-ups. On later starts the sign-up is refused because the owner exists, and the app starts normally. The password is removed from the environment of both Formbricks processes.

## Deploy on Railway

1. Deploy the template and enter your email address as `FORMBRICKS_OWNER_EMAIL` on the `Formbricks` service. That is the only value you have to provide.
2. Wait until `Formbricks` is healthy. The first start runs migrations and takes a few minutes.
3. Copy `FORMBRICKS_OWNER_PASSWORD` from the `Formbricks` service variables and store it in a password manager. Email is not configured, so password reset is off.
4. Open the `Formbricks` domain, sign in with your email and that password, and create your organization. Formbricks creates the first workspace with it.
5. Create a survey. Link surveys are served at `https://<your-domain>/s/<survey-id>`; website and app surveys use the Formbricks SDKs with your workspace ID.

To add teammates, invite them from Organization settings. Without email, copy the invite link Formbricks shows and send it yourself; an invited person can sign up, uninvited people cannot.

## Environment variables

`Formbricks` (you set `FORMBRICKS_OWNER_EMAIL`; everything else is generated or referenced):

| Variable | Default | Meaning |
| --- | --- | --- |
| `FORMBRICKS_OWNER_EMAIL` | empty, required | Email of the owner account created at first start. Formbricks refuses to start while it is empty or not a plain address. |
| `FORMBRICKS_OWNER_PASSWORD` | `Fb7` + 29 generated letters and digits | Owner password. Formbricks requires a capital letter and a digit; the fixed prefix guarantees both. Changing it later does not change the existing account. |
| `WEBAPP_URL`, `BETTER_AUTH_URL` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` | Public URL for links, cookies and authentication. Set both to your custom domain if you add one. |
| `DATABASE_URL` | private PostgreSQL reference | Formbricks database. |
| `BETTER_AUTH_SECRET`, `ENCRYPTION_KEY`, `CRON_SECRET` | 64 generated hex characters each | Session signing, encryption of stored secrets and single-use links, and the cron API secret. Do not change `ENCRYPTION_KEY` after first use. |
| `REDIS_URL` | private Valkey reference with password | Sessions, rate limits and the job queue. |
| `HUB_API_KEY`, `HUB_API_URL` | references to `Formbricks Hub` | Hub access. |
| `CUBEJS_API_URL`, `CUBEJS_API_SECRET`, `CUBEJS_JWT_ISSUER`, `CUBEJS_JWT_AUDIENCE` | references to `Cube` | Cube access. |
| `AUTHZED_ENABLED`, `AUTHZED_ENDPOINT`, `AUTHZED_TOKEN`, `AUTHZED_SYSTEM_KEY`, `AUTHZED_INSECURE`, `AUTHZED_CONSISTENCY` | `true`, SpiceDB reference, SpiceDB key, `formbricks`, `true`, `fully_consistent` | SpiceDB access over the private network (plaintext gRPC with a preshared key, as upstream's Compose file). |
| `EMAIL_VERIFICATION_DISABLED`, `PASSWORD_RESET_DISABLED` | `1`, `1` | No email provider is configured. Set both to `0` after adding SMTP variables. |
| `TELEMETRY_DISABLED` | `1` | Turns off Formbricks' anonymous usage telemetry. |
| `TRUSTED_PROXY_HOP_COUNT` | `1` | Number of `X-Forwarded-For` hops Formbricks trusts for the client IP behind Railway's edge. Rate limits and captured IPs depend on it. |
| `PORT`, `HOSTNAME` | `3000`, `::` | Listener on Railway's IPv4 and IPv6 networks. |

`Formbricks Hub`: `API_KEY` (generated), `DATABASE_URL`, `PORT=8080`, and `FORMBRICKS_READY_URL`, the private Formbricks readiness URL it waits for before migrating. `Formbricks Hub Worker`: `DATABASE_URL` and `HUB_HEALTH_URL`.

`Cube`: `CUBEJS_API_SECRET` (generated), the `CUBEJS_DB_*` connection to PostgreSQL, `PORT=4000`, `CUBEJS_TELEMETRY=false`, and upstream's settings `CUBEJS_DEFAULT_API_SCOPES=meta,data`, `CUBEJS_EXTERNAL_DEFAULT=false`, `CUBEJS_CACHE_AND_QUEUE_DRIVER=memory` and `CUBEJS_DB_QUERY_TIMEOUT=60s`.

`SpiceDB`: `SPICEDB_GRPC_PRESHARED_KEY` (generated), `SPICEDB_DATASTORE_ENGINE=postgres`, `SPICEDB_DATASTORE_CONN_URI` (the `spicedb` role and database), `SPICEDB_HTTP_ENABLED=true` and `PORT=8443` for Railway's `/healthz` check, connection pools capped at 8 read and 4 write connections, `SPICEDB_SKIP_RELEASE_CHECK=true`, and JSON logs at `warn`. Telemetry is off through the start command.

`PostgreSQL`: `POSTGRES_PASSWORD` and `SPICEDB_DATABASE_PASSWORD` (generated, letters and digits), `POSTGRES_DB=formbricks`. The SpiceDB role and database are created when the volume is first initialized.

`Valkey`: `VALKEY_PASSWORD` (generated).

Optional upstream settings such as SMTP (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `MAIL_FROM`), S3 file uploads (`S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_REGION`, `S3_BUCKET_NAME`, `S3_ENDPOINT_URL`) and OAuth providers can be added to the `Formbricks` service; see the [Formbricks configuration reference](https://formbricks.com/docs/self-hosting/configuration/environment-variables).

## Community edition boundary

The template deploys Formbricks without an `ENTERPRISE_LICENSE_KEY`, so only community-edition features are active. Features under Formbricks' separate Enterprise license (for example SSO, multiple organizations, roles, dashboards and feedback directories) stay locked until you add a license key you have obtained from Formbricks. Hub and Cube are deployed because Formbricks 6 refuses to start without their configuration and upstream ships them as required services, even though most of what they power is enterprise functionality.

## Persistence, limits and support boundary

PostgreSQL holds accounts, organizations, surveys, responses, API keys, Hub records and SpiceDB's authorization data. Valkey persists sessions and queued jobs with append-only files. A restart or redeploy keeps all of it.

File uploads (survey images and file-upload questions) need S3-compatible storage; without the `S3_*` variables Formbricks has no place to keep uploaded files. Email features (verification, password reset, invitations by mail, response notifications) need SMTP.

This is a single-instance deployment for individuals and small teams, not a high-availability setup. Back up the PostgreSQL volume before upgrades. Formbricks' webhook validation refuses private, loopback and metadata addresses, so a user cannot point a webhook at the other services in the project.

## Local verification

```bash
bun install --frozen-lockfile
./scripts/verify.sh
cp .env.example .env   # replace every placeholder
set -a; . ./.env; set +a
docker compose up -d --build
SMOKE_STATE=/tmp/formbricks-smoke.json SMOKE_PHASE=initial ./scripts/smoke.sh
docker compose restart
SMOKE_STATE=/tmp/formbricks-smoke.json SMOKE_PHASE=restart ./scripts/smoke.sh
docker compose down -v
```

The smoke test checks that sign-up is closed (the setup pages, Better Auth's raw sign-up route and Formbricks' sign-up action sent through several pages), that wrong passwords and anonymous management API calls are refused, signs in as the owner, creates the organization and a workspace API key, checks that webhooks to private, loopback and metadata addresses are refused, creates a link survey that closes itself after one response, answers it anonymously through the public client API, and waits for the background worker to close it. The restart phase checks that the owner, survey and response survived and runs a new survey through the same path. Set `BASE_URL` (and `PRIVATE_PROBE_HOST` to the PostgreSQL private domain) to run it against a Railway deployment.

## Source and forks

The Railway template builds the `Cube` service from `tech-progress/railway-template-formbricks` on the `release-v1` branch with root directory `/`; every other service uses an upstream image. To run your own fork, change the repository in `.railway/railway.ts`, create a `release-v1` branch, and authorize Railway's GitHub App for it.

## License

`cube/cube.js` and `cube/model/FeedbackRecords.js` are copied unchanged from Formbricks (`docker/cube/` at tag `6.2.1`) and remain under the AGPL-3.0 license, whose text is in `cube/LICENSE`. Formbricks, Hub, Cube, SpiceDB, PostgreSQL, pgvector and Valkey run as their unmodified upstream images under their own licenses; see `LICENSE_REVIEW.md`.

## Upstream projects

- [Formbricks](https://github.com/formbricks/formbricks) ([website](https://formbricks.com), [self-hosting docs](https://formbricks.com/docs/self-hosting/overview))
- [Formbricks Hub](https://hub.formbricks.com)
- [Cube](https://github.com/cube-js/cube)
- [SpiceDB](https://github.com/authzed/spicedb)
- [pgvector](https://github.com/pgvector/pgvector) on [PostgreSQL](https://www.postgresql.org)
- [Valkey](https://github.com/valkey-io/valkey)
