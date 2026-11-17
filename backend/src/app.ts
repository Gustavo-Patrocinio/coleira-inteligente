/**
 * HTTP API (Fastify + Zod), Phase 4.
 *
 * Users authenticate with a JWT (Authorization: Bearer <jwt>). Collars upload through the
 * base station or the app with a per-device token (Authorization: Bearer dev_...).
 */
import Fastify, { type FastifyReply, type FastifyRequest } from "fastify";
import jwt from "@fastify/jwt";
import { serializerCompiler, validatorCompiler, type ZodTypeProvider } from "fastify-type-provider-zod";
import type pg from "pg";
import { z } from "zod";
import { CLASS_COLUMNS, decodeRecords } from "./summary.js";
import { hashPassword, hashToken, newDeviceToken, verifyPassword } from "./security.js";
import { localParts } from "./metrics.js";
import { sleepSummary } from "./sleep.js";

export interface AppOptions {
  pool: pg.Pool;
  jwtSecret: string;
  logger?: boolean;
  /** Behind a reverse proxy (Caddy), so req.ip is the client's address. */
  trustProxy?: boolean;
  /** Login/register attempts allowed per IP per 15 minutes. */
  authAttemptsPer15Min?: number;
}

declare module "@fastify/jwt" {
  interface FastifyJWT {
    payload: { sub: string };
    user: { sub: string };
  }
}

const MAX_RECORDS_PER_BATCH = 7 * 1440; // a week of minutes

export async function buildApp({
  pool,
  jwtSecret,
  logger = false,
  trustProxy = false,
  authAttemptsPer15Min = 20,
}: AppOptions) {
  const app = Fastify({ logger, trustProxy, bodyLimit: 1024 * 1024 }).withTypeProvider<ZodTypeProvider>();
  app.setValidatorCompiler(validatorCompiler);
  app.setSerializerCompiler(serializerCompiler);
  await app.register(jwt, { secret: jwtSecret, sign: { expiresIn: "30d" } });

  const requireUser = async (req: FastifyRequest, reply: FastifyReply) => {
    try {
      await req.jwtVerify();
    } catch {
      return reply.code(401).send({ error: "unauthorized" });
    }
  };
  const userId = (req: FastifyRequest) => req.user.sub;

  /** 404 unless the dog belongs to the user (never reveal other users' dogs). */
  async function ownDog(req: FastifyRequest, reply: FastifyReply, dogId: number) {
    const r = await pool.query<{ id: string; name: string; timezone: string }>(
      "SELECT id, name, timezone FROM dogs WHERE id = $1 AND user_id = $2",
      [dogId, userId(req)],
    );
    if (!r.rows[0]) {
      reply.code(404).send({ error: "dog not found" });
      return null;
    }
    return r.rows[0];
  }

  app.get("/health", async () => ({ ok: true }));

  // ------------------------------------------------------------------ auth
  // Small per-IP limiter against password guessing (one process, so memory is enough).
  const attempts = new Map<string, { n: number; resetAt: number }>();
  const limitAuth = async (req: FastifyRequest, reply: FastifyReply) => {
    const now = Date.now();
    const a = attempts.get(req.ip);
    if (!a || a.resetAt <= now) {
      if (attempts.size > 10_000) attempts.clear();
      attempts.set(req.ip, { n: 1, resetAt: now + 15 * 60_000 });
      return;
    }
    if (++a.n > authAttemptsPer15Min) {
      reply.header("retry-after", Math.ceil((a.resetAt - now) / 1000));
      return reply.code(429).send({ error: "too many attempts, try again later" });
    }
  };
  const credentials = z.object({ email: z.string().email().max(200), password: z.string().min(10).max(200) });

  app.post("/v1/auth/register", { preHandler: limitAuth, schema: { body: credentials } }, async (req, reply) => {
    const email = req.body.email.toLowerCase();
    const hash = await hashPassword(req.body.password);
    const r = await pool.query<{ id: string }>(
      "INSERT INTO users (email, password_hash) VALUES ($1, $2) ON CONFLICT (email) DO NOTHING RETURNING id",
      [email, hash],
    );
    if (!r.rows[0]) return reply.code(409).send({ error: "email already registered" });
    return reply.code(201).send({ token: app.jwt.sign({ sub: r.rows[0].id }) });
  });

  app.post("/v1/auth/login", { preHandler: limitAuth, schema: { body: credentials } }, async (req, reply) => {
    const r = await pool.query<{ id: string; password_hash: string }>(
      "SELECT id, password_hash FROM users WHERE email = $1",
      [req.body.email.toLowerCase()],
    );
    const user = r.rows[0];
    if (!user || !(await verifyPassword(req.body.password, user.password_hash))) {
      return reply.code(401).send({ error: "invalid email or password" });
    }
    return { token: app.jwt.sign({ sub: user.id }) };
  });

  // ------------------------------------------------------------------ dogs / devices
  const dogBody = z.object({
    name: z.string().min(1).max(60),
    timezone: z.string().refine(isValidTimeZone, "unknown IANA time zone").default("America/Sao_Paulo"),
    birth_date: z.string().date().optional(),
    weight_kg: z.number().positive().max(150).optional(),
  });
  const idParam = z.object({ id: z.coerce.number().int().positive() });

  app.post("/v1/dogs", { preHandler: requireUser, schema: { body: dogBody } }, async (req, reply) => {
    const b = req.body;
    const r = await pool.query(
      `INSERT INTO dogs (user_id, name, timezone, birth_date, weight_kg) VALUES ($1, $2, $3, $4, $5)
       RETURNING id, name, timezone, birth_date, weight_kg`,
      [userId(req), b.name, b.timezone, b.birth_date ?? null, b.weight_kg ?? null],
    );
    return reply.code(201).send(r.rows[0]);
  });

  app.get("/v1/dogs", { preHandler: requireUser }, async (req) => {
    const r = await pool.query(
      "SELECT id, name, timezone, birth_date, weight_kg FROM dogs WHERE user_id = $1 ORDER BY id",
      [userId(req)],
    );
    return r.rows;
  });

  app.post(
    "/v1/dogs/:id/devices",
    { preHandler: requireUser, schema: { params: idParam, body: z.object({ serial: z.string().min(3).max(64) }) } },
    async (req, reply) => {
      if (!(await ownDog(req, reply, req.params.id))) return;
      const { token, hash } = newDeviceToken();
      const r = await pool.query<{ id: string }>(
        "INSERT INTO devices (dog_id, serial, token_hash) VALUES ($1, $2, $3) ON CONFLICT (serial) DO NOTHING RETURNING id",
        [req.params.id, req.body.serial, hash],
      );
      if (!r.rows[0]) return reply.code(409).send({ error: "device already registered" });
      // The token is returned once; the app hands it to the base station during setup.
      return reply.code(201).send({ device_id: r.rows[0].id, token });
    },
  );

  // ------------------------------------------------------------------ ingest
  app.post(
    "/v1/ingest",
    {
      schema: {
        body: z.object({
          records: z.string().base64().max(MAX_RECORDS_PER_BATCH * 20 + 4),
          via: z.enum(["base_station", "app"]),
        }),
      },
    },
    async (req, reply) => {
      const auth = req.headers.authorization ?? "";
      const token = auth.startsWith("Bearer dev_") ? auth.slice(7) : null;
      const dev = token
        ? (await pool.query<{ id: string }>("SELECT id FROM devices WHERE token_hash = $1", [hashToken(token)])).rows[0]
        : undefined;
      if (!dev) return reply.code(401).send({ error: "invalid device token" });

      let decoded;
      try {
        decoded = decodeRecords(Buffer.from(req.body.records, "base64"));
      } catch (err) {
        return reply.code(400).send({ error: (err as Error).message });
      }
      const { records, rejected } = decoded;
      if (records.length > MAX_RECORDS_PER_BATCH) return reply.code(413).send({ error: "batch too large" });

      let inserted = 0;
      if (records.length) {
        const cols = (c: number) => records.map((r) => r.seconds[c]);
        const res = await pool.query(
          `INSERT INTO activity_minute (device_id, minute_ts, ${CLASS_COLUMNS.join(", ")},
                                        unknown_s, battery_pct, flags, via)
           SELECT $1, to_timestamp(t), s0, s1, s2, s3, s4, s5, s6, u, b, f, $13
             FROM unnest($2::bigint[], $3::int[], $4::int[], $5::int[], $6::int[], $7::int[],
                         $8::int[], $9::int[], $10::int[], $11::int[], $12::int[])
                  AS x(t, s0, s1, s2, s3, s4, s5, s6, u, b, f)
           ON CONFLICT (device_id, minute_ts) DO NOTHING`,
          [
            dev.id,
            records.map((r) => r.minuteTs),
            ...[0, 1, 2, 3, 4, 5, 6].map(cols),
            records.map((r) => r.unknownS),
            records.map((r) => r.batteryPct),
            records.map((r) => r.flags),
            req.body.via,
          ],
        );
        inserted = res.rowCount ?? 0;
      }
      return {
        received: records.length + rejected.length,
        inserted,
        duplicates: records.length - inserted,
        rejected,
      };
    },
  );

  // ------------------------------------------------------------------ queries
  app.get(
    "/v1/dogs/:id/days/:day",
    { preHandler: requireUser, schema: { params: idParam.extend({ day: z.string().date() }) } },
    async (req, reply) => {
      const dog = await ownDog(req, reply, req.params.id);
      if (!dog) return;
      const r = await pool.query(
        `SELECT time_bucket(INTERVAL '15 minutes', a.minute_ts) AS block,
                count(*)::int AS minutes,
                ${CLASS_COLUMNS.map((c) => `sum(a.${c})::int AS ${c}`).join(", ")},
                sum(a.unknown_s)::int AS unknown_s,
                min(a.battery_pct)::int AS battery_pct
           FROM activity_minute a JOIN devices d ON d.id = a.device_id
          WHERE d.dog_id = $1
            AND a.minute_ts >= ($2::date)::timestamp AT TIME ZONE $3
            AND a.minute_ts < ($2::date + 1)::timestamp AT TIME ZONE $3
          GROUP BY block ORDER BY block`,
        [dog.id, req.params.day, dog.timezone],
      );
      const totals = Object.fromEntries(
        [...CLASS_COLUMNS, "unknown_s"].map((c) => [c, r.rows.reduce((s, b) => s + (b[c] as number), 0)]),
      );
      const daily = (
        await pool.query("SELECT night_wakeups FROM daily_metrics WHERE dog_id = $1 AND day = $2", [
          dog.id,
          req.params.day,
        ])
      ).rows[0];
      return {
        day: req.params.day,
        timezone: dog.timezone,
        totals,
        night_wakeups: daily?.night_wakeups ?? null,
        blocks: r.rows,
      };
    },
  );

  // Sleep estimated from movement for the night ending on :day plus that day's naps
  app.get(
    "/v1/dogs/:id/sleep/:day",
    { preHandler: requireUser, schema: { params: idParam.extend({ day: z.string().date() }) } },
    async (req, reply) => {
      const dog = await ownDog(req, reply, req.params.id);
      if (!dog) return;
      const r = await pool.query(
        `SELECT a.minute_ts, a.still_s,
                (a.walking_s + a.running_s + a.scratching_s + a.shaking_s + a.eating_s + a.drinking_s)
                  AS moving_s
           FROM activity_minute a JOIN devices d ON d.id = a.device_id
          WHERE d.dog_id = $1
            AND a.minute_ts >= (($2::date - 1) + TIME '20:00') AT TIME ZONE $3
            AND a.minute_ts < ($2::date + TIME '20:00') AT TIME ZONE $3
          ORDER BY a.minute_ts`,
        [dog.id, req.params.day, dog.timezone],
      );
      const s = sleepSummary(
        r.rows.map((x) => ({ minuteTs: x.minute_ts, stillS: x.still_s, movingS: x.moving_s })),
        req.params.day,
        dog.timezone,
      );
      return {
        day: s.day,
        timezone: dog.timezone,
        method: s.method,
        night_coverage: Math.round(s.nightCoverage * 1000) / 1000,
        night: s.night && {
          bedtime: s.night.bedtime,
          wake_time: s.night.wakeTime,
          in_bed_min: s.night.inBedMin,
          rest_min: s.night.restMin,
          awakenings: s.night.awakenings,
          longest_rest_min: s.night.longestRestMin,
          missing_min: s.night.missingMin,
        },
        naps: { count: s.naps.count, total_min: s.naps.totalMin },
      };
    },
  );

  app.get(
    "/v1/dogs/:id/trends",
    {
      preHandler: requireUser,
      schema: { params: idParam, querystring: z.object({ days: z.coerce.number().int().min(1).max(365).default(30) }) },
    },
    async (req, reply) => {
      const dog = await ownDog(req, reply, req.params.id);
      if (!dog) return;
      const today = localParts(new Date(), dog.timezone).day;
      const r = await pool.query(
        `SELECT day, coverage_min, active_s, scratching_s, night_wakeups
           FROM daily_metrics WHERE dog_id = $1 AND day >= ($2::date - $3::int) AND day < $2::date
          ORDER BY day`,
        [dog.id, today, req.query.days],
      );
      return { timezone: dog.timezone, days: r.rows };
    },
  );

  app.get("/v1/dogs/:id/alerts", { preHandler: requireUser, schema: { params: idParam } }, async (req, reply) => {
    const dog = await ownDog(req, reply, req.params.id);
    if (!dog) return;
    const r = await pool.query(
      `SELECT id, day, metric, direction, value, median, robust_z, feedback, created_at
         FROM alerts WHERE dog_id = $1 ORDER BY day DESC, id DESC LIMIT 100`,
      [dog.id],
    );
    return r.rows;
  });

  app.post(
    "/v1/alerts/:id/feedback",
    {
      preHandler: requireUser,
      schema: { params: idParam, body: z.object({ feedback: z.enum(["useful", "false_alarm"]) }) },
    },
    async (req, reply) => {
      const r = await pool.query(
        `UPDATE alerts a SET feedback = $1 FROM dogs d
          WHERE a.id = $2 AND a.dog_id = d.id AND d.user_id = $3 RETURNING a.id`,
        [req.body.feedback, req.params.id, userId(req)],
      );
      if (!r.rows[0]) return reply.code(404).send({ error: "alert not found" });
      return { ok: true };
    },
  );

  // ------------------------------------------------------------------ privacy (LGPD)
  // ------------------------------------------------------------------ account / LGPD
  const ME_COLUMNS = "id, email, created_at, consent_version, consent_at, research_opt_in";

  app.get("/v1/me", { preHandler: requireUser }, async (req, reply) => {
    const r = await pool.query(`SELECT ${ME_COLUMNS} FROM users WHERE id = $1`, [userId(req)]);
    return r.rows[0] ?? reply.code(404).send({ error: "user not found" });
  });

  const consentBody = z.object({
    version: z.number().int().positive(),
    research_opt_in: z.boolean().default(false),
  });
  app.put("/v1/me/consent", { preHandler: requireUser, schema: { body: consentBody } }, async (req) => {
    const r = await pool.query(
      `UPDATE users SET consent_version = $2, consent_at = now(), research_opt_in = $3
        WHERE id = $1 RETURNING ${ME_COLUMNS}`,
      [userId(req), req.body.version, req.body.research_opt_in],
    );
    return r.rows[0];
  });

  const pushBody = z.object({
    token: z.string().min(20).max(4096),
    platform: z.enum(["android", "ios"]),
  });
  app.put("/v1/me/push-token", { preHandler: requireUser, schema: { body: pushBody } }, async (req, reply) => {
    await pool.query(
      `INSERT INTO push_tokens (token, user_id, platform) VALUES ($1, $2, $3)
       ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform, updated_at = now()`,
      [req.body.token, userId(req), req.body.platform],
    );
    return reply.code(204).send();
  });
  // on sign-out, so the phone stops getting this account's alerts
  app.delete(
    "/v1/me/push-token",
    { preHandler: requireUser, schema: { body: pushBody.pick({ token: true }) } },
    async (req, reply) => {
      await pool.query("DELETE FROM push_tokens WHERE token = $1 AND user_id = $2", [req.body.token, userId(req)]);
      return reply.code(204).send();
    },
  );

  app.get("/v1/me/export", { preHandler: requireUser }, async (req) => {
    const uid = userId(req);
    const q = (sql: string) => pool.query(sql, [uid]).then((r) => r.rows);
    return {
      user: (await q(`SELECT ${ME_COLUMNS} FROM users WHERE id = $1`))[0],
      dogs: await q("SELECT * FROM dogs WHERE user_id = $1"),
      devices: await q("SELECT d.id, d.dog_id, d.serial, d.created_at FROM devices d JOIN dogs g ON g.id = d.dog_id WHERE g.user_id = $1"),
      daily_metrics: await q("SELECT m.* FROM daily_metrics m JOIN dogs g ON g.id = m.dog_id WHERE g.user_id = $1"),
      alerts: await q("SELECT a.* FROM alerts a JOIN dogs g ON g.id = a.dog_id WHERE g.user_id = $1"),
      push_tokens: await q("SELECT platform, updated_at FROM push_tokens WHERE user_id = $1"),
      activity_minute: await q(
        `SELECT a.* FROM activity_minute a JOIN devices d ON d.id = a.device_id JOIN dogs g ON g.id = d.dog_id
          WHERE g.user_id = $1 ORDER BY a.device_id, a.minute_ts`,
      ),
    };
  });

  app.delete("/v1/me", { preHandler: requireUser }, async (req, reply) => {
    // ON DELETE CASCADE removes dogs, devices, minutes, metrics and alerts.
    await pool.query("DELETE FROM users WHERE id = $1", [userId(req)]);
    return reply.code(204).send();
  });

  return app;
}

function isValidTimeZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}
