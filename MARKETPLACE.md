# Deploy and Host Formbricks Community Surveys on Railway

Formbricks is an open-source survey platform for link surveys, website and in-app surveys, NPS and CSAT. This template runs the AGPL community edition of Formbricks 6.2.1 with the services Formbricks 6 needs: Formbricks Hub, Cube, SpiceDB, PostgreSQL with pgvector, and Valkey, all private except the Formbricks web app.

## About Hosting Formbricks Community Surveys

Formbricks 6 no longer starts as a single container. It needs SpiceDB for authorization, Formbricks Hub for feedback records, Cube for its analytics layer, PostgreSQL and a Redis-compatible store for sessions and its background job queue. This template wires all seven services over Railway's private network, gives each one a generated credential, and runs migrations in the right order on first start.

You enter one value, your email address as `FORMBRICKS_OWNER_EMAIL`. Before Formbricks accepts any outside traffic it boots on loopback only and creates your owner account with the generated `FORMBRICKS_OWNER_PASSWORD`, so nobody can claim the instance before you. Copy that password from the `Formbricks` service variables, sign in, and create your organization.

PostgreSQL (5 GB volume) keeps accounts, surveys, responses and authorization data; Valkey (1 GB volume) keeps sessions and queued jobs. Email and S3 file uploads are optional and can be added with Formbricks' own variables.

## Why Deploy Formbricks Community Surveys on Railway

- The full Formbricks 6 service set, pinned by image digest, with health checks on every web service.
- No first-visit takeover: the owner account exists before the public listener opens, and sign-up then stays closed to uninvited users.
- Only the Formbricks app is public; databases, Hub, Cube and SpiceDB stay on the private network.
- Community edition only: no enterprise license key is set and enterprise features stay locked.

## Common Use Cases

- Link surveys and forms for customers, users or employees, answered without an account.
- NPS, CSAT and product feedback inside your website or app through the Formbricks SDKs.
- Collecting responses through the management API and webhooks into your own tools.

## Dependencies for Formbricks Community Surveys Hosting

The template uses seven services and two Railway volumes. No external account is required; SMTP and S3 storage are optional.

### Deployment Dependencies

- [Formbricks](https://github.com/formbricks/formbricks) provides surveys, the response pipeline, the APIs and the web app.
- [Formbricks Hub](https://hub.formbricks.com) provides the feedback-record API and its worker.
- [Cube](https://github.com/cube-js/cube) provides the analytics query layer Formbricks connects to.
- [SpiceDB](https://github.com/authzed/spicedb) provides Formbricks' authorization checks.
- [pgvector](https://github.com/pgvector/pgvector) on [PostgreSQL](https://www.postgresql.org) stores Formbricks, Hub and SpiceDB data.
- [Valkey](https://github.com/valkey-io/valkey) stores sessions, rate limits and the job queue.
- [Railway](https://railway.com) provides builds, private networking, HTTPS and the volumes.
