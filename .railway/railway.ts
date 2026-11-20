import { readFileSync } from "node:fs";
import { defineRailway, github, group, project, service, volume } from "railway/iac";
import defaults from "../template-defaults.json" with { type: "json" };

// Formbricks, Hub and Cube are released together upstream (Helm chart pins at tag
// 6.2.1). Move every pin in one release and keep compose.yaml in step;
// scripts/verify.sh checks both.
export const FORMBRICKS_IMAGE =
  "ghcr.io/formbricks/formbricks:6.2.1@sha256:0da58d1bf3ea86d355d8e682851fdb74b4cb19ed7d7436a82ab069db7ba2b992";
export const HUB_IMAGE =
  "ghcr.io/formbricks/hub:0.14.3@sha256:63b85da9a0eb4346dd9350cd2bc82e9fe00b195756ad9a4bd50195ba874d10bc";
export const CUBE_BASE_IMAGE =
  "ghcr.io/formbricks/cube:1.8.8-3@sha256:dbe4b87e37e54e634e8cb3e8b6fd1d5cb9e2d84fe6225abbec9cb715c71fe50e";
export const SPICEDB_IMAGE =
  "authzed/spicedb:v1.57.0-debug@sha256:fdeb87ac0cbc31dc977b4d6c334ae3cae708069873706099c9d350089e85fd6d";
export const POSTGRES_IMAGE =
  "pgvector/pgvector:0.8.7-pg18@sha256:38681dc6eaf55308e2a4c6de392d131652dcfac70e1263e35cd9b5ea3fe39782";
export const VALKEY_IMAGE =
  "valkey/valkey:9.1.2@sha256:418652cfb58ef879d4978c33553735d7147016032d5aefaa14c828e611eb9dfd";
// Cube needs Formbricks' model files, which Railway cannot mount, so it builds the
// root Dockerfile of the public distribution repository.
const CUBE_SOURCE = github("tech-progress/railway-template-formbricks", { branch: "release-v1", rootDirectory: "/" });

// Each start contract lives in scripts/<name>-start.sh so Compose runs the same
// file. Every non-comment line is a complete command; they are joined with "; ".
const startScript = (name: string): string => {
  const lines = readFileSync(new URL(`../scripts/${name}-start.sh`, import.meta.url), "utf8")
    .split("\n")
    .filter((line) => line.trim() !== "" && !line.trimStart().startsWith("#"));
  const script = lines.join("; ");
  if (script.includes("'")) throw new Error(`scripts/${name}-start.sh must not contain single quotes`);
  return `/bin/sh -ec '${script}'`;
};
export const FORMBRICKS_START = startScript("formbricks");
export const HUB_START = startScript("hub");
export const HUB_WORKER_START = startScript("hub-worker");
export const SPICEDB_START = startScript("spicedb");
export const POSTGRES_START = startScript("postgres");
export const VALKEY_START =
  "/bin/sh -ec 'exec valkey-server --appendonly yes --maxmemory-policy noeviction --requirepass \"$VALKEY_PASSWORD\"'";

// Credentials are never derived here: the IaC random-string helper is a public
// hash of its label. A disposable source project takes fresh values from
// FORMBRICKS_IAC_<NAME> in the applying shell; without them they are empty and
// the services refuse to start. The marketplace draft is restored to the
// ${{secret()}} defaults in template-defaults.json.
const hostSecret = (key: string): string => (globalThis as any).process?.env?.[`FORMBRICKS_IAC_${key}`] ?? "";
// `railway templates create` rejects a repository source the Railway GitHub App
// cannot read, so the draft is generated from the Cube base image
// (FORMBRICKS_IAC_CUBE_SEED=1) and restore-template-draft.sh puts the repository back.
const cubeSeed = (globalThis as any).process?.env?.FORMBRICKS_IAC_CUBE_SEED === "1";

const restart = { restartPolicyType: "ON_FAILURE", restartPolicyMaxRetries: 10 } as const;

export default defineRailway(() => {
  const postgresData = volume("PostgreSQL Data", { sizeMB: 5_000 });
  const valkeyData = volume("Valkey Data", { sizeMB: 1_000 });

  const postgres = service("PostgreSQL", {
    source: { image: POSTGRES_IMAGE },
    start: POSTGRES_START,
    volumeMounts: { "/var/lib/postgresql": postgresData },
    deploy: restart,
    env: {
      ...defaults.PostgreSQL,
      POSTGRES_PASSWORD: hostSecret("POSTGRES_PASSWORD"),
      SPICEDB_DATABASE_PASSWORD: hostSecret("SPICEDB_DATABASE_PASSWORD"),
    },
  });

  const valkey = service("Valkey", {
    source: { image: VALKEY_IMAGE },
    start: VALKEY_START,
    volumeMounts: { "/data": valkeyData },
    deploy: restart,
    env: { ...defaults.Valkey, VALKEY_PASSWORD: hostSecret("VALKEY_PASSWORD") },
  });

  const spicedb = service("SpiceDB", {
    source: { image: SPICEDB_IMAGE },
    start: SPICEDB_START,
    healthcheck: "/healthz",
    healthcheckTimeout: 600,
    deploy: restart,
    env: { ...defaults.SpiceDB, SPICEDB_GRPC_PRESHARED_KEY: hostSecret("SPICEDB_GRPC_PRESHARED_KEY") },
  });

  const hub = service("Formbricks Hub", {
    source: { image: HUB_IMAGE },
    start: HUB_START,
    healthcheck: "/health",
    healthcheckTimeout: 900,
    deploy: restart,
    env: { ...defaults["Formbricks Hub"], API_KEY: hostSecret("HUB_API_KEY") },
  });

  const hubWorker = service("Formbricks Hub Worker", {
    source: { image: HUB_IMAGE },
    start: HUB_WORKER_START,
    deploy: restart,
    env: { ...defaults["Formbricks Hub Worker"] },
  });

  const cube = service("Cube", {
    ...(cubeSeed
      ? { source: { image: CUBE_BASE_IMAGE } }
      : {
          source: CUBE_SOURCE,
          build: { builder: "DOCKERFILE", dockerfilePath: "Dockerfile", watchPatterns: ["/Dockerfile", "/cube/**"] },
        }),
    healthcheck: "/readyz",
    healthcheckTimeout: 600,
    deploy: restart,
    env: { ...defaults.Cube, CUBEJS_API_SECRET: hostSecret("CUBEJS_API_SECRET") },
  });

  const formbricks = service("Formbricks", {
    source: { image: FORMBRICKS_IMAGE },
    start: FORMBRICKS_START,
    healthcheck: "/health/ready",
    healthcheckTimeout: 900,
    deploy: restart,
    env: {
      ...defaults.Formbricks,
      BETTER_AUTH_SECRET: hostSecret("BETTER_AUTH_SECRET"),
      ENCRYPTION_KEY: hostSecret("ENCRYPTION_KEY"),
      CRON_SECRET: hostSecret("CRON_SECRET"),
      FORMBRICKS_OWNER_EMAIL: hostSecret("OWNER_EMAIL"),
      FORMBRICKS_OWNER_PASSWORD: hostSecret("OWNER_PASSWORD"),
    },
  });

  return project("formbricks-surveys", {
    resources: [
      group("Formbricks", [formbricks, hub, hubWorker, cube, spicedb]),
      group("Data", [postgres, postgresData, valkey, valkeyData]),
    ],
  });
});
