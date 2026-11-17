import { createPool } from "../db.js";
import { runAlertsJob } from "../jobs.js";

const pool = createPool(process.env.DATABASE_URL ?? "postgres://collar:collar@localhost:54329/collar");
console.log(await runAlertsJob(pool));
await pool.end();
