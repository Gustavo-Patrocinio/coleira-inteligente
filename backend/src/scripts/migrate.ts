import { createPool, migrate } from "../db.js";

const pool = createPool(process.env.DATABASE_URL ?? "postgres://collar:collar@localhost:54329/collar");
const applied = await migrate(pool, (m) => console.log(m));
console.log(applied.length ? `${applied.length} migration(s) applied` : "database is up to date");
await pool.end();
