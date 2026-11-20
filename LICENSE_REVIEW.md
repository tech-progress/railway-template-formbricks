# License review

Formbricks' [LICENSE](https://github.com/formbricks/formbricks/blob/6.2.1/LICENSE) (checked at tag `6.2.1`) puts everything outside a few directories under AGPL-3.0, the `packages/js`, `packages/android`, `packages/ios`, `packages/api`, `packages/surveys` and `packages/survey-ui` SDK packages under MIT, and `apps/web/modules/ee` under the separate [Formbricks Enterprise Edition license](https://github.com/formbricks/formbricks/blob/6.2.1/apps/web/modules/ee/LICENSE). The EE license allows production use only with a Formbricks Enterprise license, allows copying and modifying for development and testing, and forbids copying, publishing, distributing, sublicensing or selling that code otherwise.

Upstream compiles the `ee` code into the same official image it publishes for every self-hosted deployment and turns enterprise features on only when `ENTERPRISE_LICENSE_KEY` holds a valid key. This template:

- deploys Formbricks' own published images from `ghcr.io/formbricks` pinned by digest, and does not mirror, rebuild, modify or redistribute Formbricks application code;
- sets no `ENTERPRISE_LICENSE_KEY`, so every feature gated by the license check (`apps/web/modules/ee/license-check/lib/utils.ts`: multiple organizations, SSO and SAML, two-factor auth, contacts, roles and access control, audit logs, quotas, dashboards, feedback directories, workflows, data retention, spam protection, whitelabeling and branding removal) stays off;
- does not describe enterprise features as included functionality.

The `Cube` image adds two files copied unchanged from `docker/cube/` at tag `6.2.1` (`cube.js`, kept as `cube/cube.js`, and `schema/FeedbackRecords.js`, kept as `cube/model/FeedbackRecords.js`; both outside the `ee` directory, so AGPL-3.0). The distribution repository keeps them with the upstream LICENSE text in `cube/LICENSE` and links their source. The base image `ghcr.io/formbricks/cube` packages Cube's server packages (Apache-2.0; the Cube repository uses MIT for a few components) and is used unmodified underneath those two files.

Formbricks Hub declares Apache-2.0 in its OpenAPI document. SpiceDB is Apache-2.0. PostgreSQL (PostgreSQL License) with pgvector (PostgreSQL License) and Valkey (BSD-3-Clause) run as unmodified official images.

Recheck the root LICENSE, `apps/web/modules/ee/LICENSE` and the feature gates in `license-check/lib/utils.ts` before every Formbricks upgrade. If a community-edition feature starts to depend on code under the EE license without a key, or the boundary becomes ambiguous, stop the release.
