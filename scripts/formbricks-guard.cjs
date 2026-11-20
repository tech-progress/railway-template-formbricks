"use strict";
// Owner bootstrap guard for scripts/formbricks-start.sh, which embeds this file as
// base64 and explains it. Invariant: every start inserts the sentinel ("post")
// before Formbricks listens publicly, and nothing deletes it. "pre" therefore
// changes nothing once the sentinel exists. Without it no listener has ever been
// public, so rows without credential or membership come only from an interrupted
// bootstrap and are removed; "fresh" means no user is left.
const { createRequire } = require("node:module");
const { randomBytes } = require("node:crypto");
const { Client } = createRequire("/home/nextjs/packages/database/package.json")("pg");

const SENTINEL_EMAIL = "bootstrap-sentinel@formbricks.invalid";
const mode = process.argv[2];

const sentinelRows = (db) =>
  db.query(
    `SELECT u."isActive" AS active,
            EXISTS (SELECT 1 FROM "Account" a WHERE a."userId" = u.id) AS credential,
            EXISTS (SELECT 1 FROM "Membership" m WHERE m."userId" = u.id) AS member
       FROM "User" u WHERE lower(u.email) = $1`,
    [SENTINEL_EMAIL]
  );

const main = async () => {
  if (mode !== "pre" && mode !== "post") throw new Error("usage: formbricks-guard.cjs pre | post");
  const url = new URL(process.env.DATABASE_URL);
  url.searchParams.delete("schema");
  const db = new Client({ connectionString: url.toString() });
  await db.connect();
  try {
    await db.query("BEGIN");
    await db.query('LOCK TABLE "User" IN SHARE ROW EXCLUSIVE MODE');
    const sentinel = await sentinelRows(db);
    if (sentinel.rows.some((row) => row.active || row.credential || row.member)) {
      throw new Error(`${SENTINEL_EMAIL} is a real account; refusing to continue`);
    }
    if (mode === "pre") {
      if (sentinel.rowCount === 1) {
        console.log("initialized");
      } else {
        const orphans = await db.query(
          `DELETE FROM "User" u
            WHERE NOT EXISTS (SELECT 1 FROM "Account" a WHERE a."userId" = u.id)
              AND NOT EXISTS (SELECT 1 FROM "Membership" m WHERE m."userId" = u.id)`
        );
        if (orphans.rowCount > 0) console.error(`Removed ${orphans.rowCount} account row(s) left without a credential by an interrupted bootstrap.`);
        const users = await db.query('SELECT count(*)::int AS n FROM "User"');
        console.log(users.rows[0].n === 0 ? "fresh" : "initialized");
      }
    } else {
      if (sentinel.rowCount === 0) {
        await db.query(
          `INSERT INTO "User" (id, updated_at, name, email, "isActive") VALUES ($1, now(), $2, $3, false)`,
          ["s" + randomBytes(18).toString("hex").slice(0, 24), "Bootstrap sentinel (keeps sign-up closed; do not delete)", SENTINEL_EMAIL]
        );
      }
      const credentialed = await db.query('SELECT count(*)::int AS n FROM "User" u WHERE EXISTS (SELECT 1 FROM "Account" a WHERE a."userId" = u.id)');
      if (credentialed.rows[0].n === 0) console.error("Warning: no account with a credential exists; Formbricks stays closed until one is restored (see README).");
    }
    await db.query("COMMIT");
  } catch (error) {
    await db.query("ROLLBACK").catch(() => undefined);
    throw error;
  } finally {
    await db.end();
  }
};

main().catch((error) => {
  console.error(`Formbricks bootstrap guard failed: ${error.message}`);
  process.exit(1);
});
