import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";
import { createPool, migrate } from "./db.js";
import { runAlertsJob } from "./jobs.js";

const config = loadConfig();
const pool = createPool(config.DATABASE_URL);
await migrate(pool, (m) => console.log(m));

const app = await buildApp({
  pool,
  jwtSecret: config.JWT_SECRET,
  logger: true,
  trustProxy: config.TRUST_PROXY,
});
await app.listen({ port: config.PORT, host: "0.0.0.0" });

if (config.ALERTS_EVERY_MIN > 0) {
  const tick = async () => {
    try {
      app.log.info({ job: "alerts", ...(await runAlertsJob(pool)) }, "alerts job done");
    } catch (err) {
      app.log.error(err, "alerts job failed");
    }
  };
  setInterval(tick, config.ALERTS_EVERY_MIN * 60_000).unref();
  void tick();
}
