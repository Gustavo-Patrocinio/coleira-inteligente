import { createPool } from "../db.js";
import { runAlertsJob } from "../jobs.js";
import { FcmSender } from "../push.js";

const pool = createPool(process.env.DATABASE_URL ?? "postgres://collar:collar@localhost:54329/collar");
const fcm = process.env.FCM_SERVICE_ACCOUNT_FILE;
console.log(await runAlertsJob(pool, new Date(), 3, fcm ? FcmSender.fromFile(fcm) : undefined));
await pool.end();
