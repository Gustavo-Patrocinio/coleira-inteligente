import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";
import { createPool, migrate } from "./db.js";
import { runAlertsJob } from "./jobs.js";
import { FcmSender } from "./push.js";

const config = loadConfig();
const pool = createPool(config.DATABASE_URL);
await migrate(pool, (m) => console.log(m));

const app = await buildApp({
  pool,
  jwtSecret: config.JWT_SECRET,
  logger: true,
  trustProxy: config.TRUST_PROXY,
});
await app.listen({ port: config.PORT, host: config.HOST });

const push = config.FCM_SERVICE_ACCOUNT_FILE ? FcmSender.fromFile(config.FCM_SERVICE_ACCOUNT_FILE) : undefined;
app.log.info(push ? "push notifications on (FCM)" : "push notifications off (no FCM_SERVICE_ACCOUNT_FILE)");

if (config.ALERTS_EVERY_MIN > 0) {
  const tick = async () => {
    try {
      app.log.info({ job: "alerts", ...(await runAlertsJob(pool, new Date(), 3, push)) }, "alerts job done");
    } catch (err) {
      app.log.error(err, "alerts job failed");
    }
  };
  setInterval(tick, config.ALERTS_EVERY_MIN * 60_000).unref();
  void tick();
}
