/**
 * HTTP API (Fastify + Zod), Phase 4.
 *
 * Users authenticate with a JWT (Authorization: Bearer <jwt>). Collars upload through the
 * base station or the app with a per-device token (Authorization: Bearer dev_...).
 * Login tokens carry the user's token_version: changing or resetting the password bumps it,
 * which signs out every other phone.
 */
import { randomInt, timingSafeEqual } from "node:crypto";
import Fastify, { type FastifyReply, type FastifyRequest } from "fastify";
import jwt from "@fastify/jwt";
import { serializerCompiler, validatorCompiler, type ZodTypeProvider } from "fastify-type-provider-zod";
import type pg from "pg";
import { z } from "zod";
import { CLASS_COLUMNS, decodeRecords } from "./summary.js";
import { hashPassword, hashToken, newDeviceToken, verifyPassword } from "./security.js";
import { localParts } from "./metrics.js";
import { sleepSummary } from "./sleep.js";
import { type Mailer, resetEmail } from "./mail.js";
import { backupStatus } from "./backups.js";

export interface AppOptions {
  pool: pg.Pool;
  jwtSecret: string;
  logger?: boolean;
  /** Behind a reverse proxy (Caddy), so req.ip is the client's address. */
  trustProxy?: boolean;
  /** Login/register attempts allowed per IP per 15 minutes. */
  authAttemptsPer15Min?: number;
  /** Sends password reset codes; without it the reset endpoints answer 501. */
  mailer?: Mailer;
  /** Folder with the nightly dumps; GET /health/backups watches it (src/backups.ts). */
  backupDir?: string;
}

declare module "@fastify/jwt" {
  interface FastifyJWT {
    // v = users.token_version when the token was issued (absent in tokens from before it)
    payload: { sub: string; v?: number };
    user: { sub: string; v?: number };
  }
}

const MAX_RECORDS_PER_BATCH = 7 * 1440; // a week of minutes

export async function buildApp({
  pool,
  jwtSecret,
  logger = false,
  trustProxy = false,
  authAttemptsPer15Min = 20,
  mailer,
  backupDir,
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
    // a deleted account, or a password changed since this token was issued
    const r = await pool.query<{ token_version: number }>("SELECT token_version FROM users WHERE id = $1", [
      req.user.sub,
    ]);
    if (!r.rows[0] || r.rows[0].token_version !== (req.user.v ?? 0)) {
      return reply.code(401).send({ error: "unauthorized" });
    }
  };
  const tokenFor = (id: string, version: number) => app.jwt.sign({ sub: id, v: version });
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

  // also checks the database, so an uptime monitor notices when it is down
  app.get("/health", async (_req, reply) => {
    try {
      await pool.query("SELECT 1");
      return { ok: true };
    } catch {
      return reply.code(503).send({ ok: false, error: "database unavailable" });
    }
  });

  // Separate from /health: a late backup must alert the owner, not mark the API unhealthy.
  app.get("/health/backups", async (_req, reply) => {
    if (!backupDir) return reply.code(404).send({ error: "this server does not watch its backups" });
    const status = await backupStatus(backupDir);
    return reply.code(status.ok ? 200 : 503).send(status);
  });

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
    return reply.code(201).send({ token: tokenFor(r.rows[0].id, 0) });
  });

  app.post("/v1/auth/login", { preHandler: limitAuth, schema: { body: credentials } }, async (req, reply) => {
    const r = await pool.query<{ id: string; password_hash: string; token_version: number }>(
      "SELECT id, password_hash, token_version FROM users WHERE email = $1",
      [req.body.email.toLowerCase()],
    );
    const user = r.rows[0];
    if (!user || !(await verifyPassword(req.body.password, user.password_hash))) {
      return reply.code(401).send({ error: "invalid email or password" });
    }
    return { token: tokenFor(user.id, user.token_version) };
  });

  // Password reset by email: a 6-digit code (stored as a hash), 15 minutes, 5 guesses.
  // The answer never says whether the email has an account.
  const RESET_MINUTES = 15;
  const RESET_MAX_ATTEMPTS = 5;
  const resetHash = (userIdValue: string, code: string) => hashToken(`${userIdValue}:${code}`);
  const noEmail = (reply: FastifyReply) =>
    reply.code(501).send({ error: "this server cannot send email; ask whoever runs it to reset your password" });

  app.post(
    "/v1/auth/forgot",
    { preHandler: limitAuth, schema: { body: z.object({ email: z.string().email().max(200) }) } },
    async (req, reply) => {
      if (!mailer) return noEmail(reply);
      const email = req.body.email.toLowerCase();
      const r = await pool.query<{ id: string }>("SELECT id FROM users WHERE email = $1", [email]);
      const user = r.rows[0];
      if (user) {
        const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
        // a new code replaces the old one, but not more than once a minute (no email flooding)
        const saved = await pool.query(
          `INSERT INTO password_resets (user_id, code_hash, expires_at)
           VALUES ($1, $2, now() + make_interval(mins => $3))
           ON CONFLICT (user_id) DO UPDATE
             SET code_hash = EXCLUDED.code_hash, expires_at = EXCLUDED.expires_at, attempts = 0, created_at = now()
             WHERE password_resets.created_at < now() - interval '1 minute'
           RETURNING user_id`,
          [user.id, resetHash(user.id, code), RESET_MINUTES],
        );
        if (saved.rowCount) {
          try {
            await mailer.send(resetEmail(email, code));
          } catch (err) {
            req.log.error(err, "could not send the reset email");
          }
        }
      }
      return reply.code(202).send({ ok: true });
    },
  );

  const resetBody = z.object({
    email: z.string().email().max(200),
    code: z.string().regex(/^\d{6}$/),
    new_password: z.string().min(10).max(200),
  });
  app.post("/v1/auth/reset", { preHandler: limitAuth, schema: { body: resetBody } }, async (req, reply) => {
    if (!mailer) return noEmail(reply);
    const bad = () => reply.code(400).send({ error: "invalid or expired code" });
    const r = await pool.query<{ id: string; code_hash: string; attempts: number; expired: boolean }>(
      `SELECT u.id, p.code_hash, p.attempts, p.expires_at < now() AS expired
         FROM users u JOIN password_resets p ON p.user_id = u.id WHERE u.email = $1`,
      [req.body.email.toLowerCase()],
    );
    const row = r.rows[0];
    if (!row || row.expired || row.attempts >= RESET_MAX_ATTEMPTS) return bad();
    const expected = Buffer.from(row.code_hash);
    const actual = Buffer.from(resetHash(row.id, req.body.code));
    if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
      await pool.query("UPDATE password_resets SET attempts = attempts + 1 WHERE user_id = $1", [row.id]);
      return bad();
    }
    const u = await pool.query<{ token_version: number }>(
      "UPDATE users SET password_hash = $2, token_version = token_version + 1 WHERE id = $1 RETURNING token_version",
      [row.id, await hashPassword(req.body.new_password)],
    );
    await pool.query("DELETE FROM password_resets WHERE user_id = $1", [row.id]);
    return { token: tokenFor(row.id, u.rows[0]!.token_version) };
  });

  // ------------------------------------------------------------------ dogs / devices
  // profile fields (nullable: PATCH with null clears one)
  const dogFields = {
    name: z.string().trim().min(1).max(60),
    timezone: z.string().refine(isValidTimeZone, "unknown IANA time zone"),
    birth_date: z
      .string()
      .date()
      .refine((d) => d <= new Date().toISOString().slice(0, 10) && d >= "1990-01-01", "birth date out of range")
      .nullable(),
    weight_kg: z.number().positive().max(150).nullable(),
    sex: z.enum(["male", "female"]).nullable(),
    neutered: z.boolean().nullable(),
    breed: z.string().trim().max(80).nullable(),
  };
  const dogBody = z.object({
    ...dogFields,
    timezone: dogFields.timezone.default("America/Sao_Paulo"),
    birth_date: dogFields.birth_date.optional(),
    weight_kg: dogFields.weight_kg.optional(),
    sex: dogFields.sex.optional(),
    neutered: dogFields.neutered.optional(),
    breed: dogFields.breed.optional(),
  });
  const dogPatch = z.object(dogFields).partial().refine((b) => Object.keys(b).length > 0, "nothing to change");
  const DOG_COLUMNS = "id, name, timezone, birth_date, weight_kg, sex, neutered, breed";
  const idParam = z.object({ id: z.coerce.number().int().positive() });

  app.post("/v1/dogs", { preHandler: requireUser, schema: { body: dogBody } }, async (req, reply) => {
    const b = req.body;
    const r = await pool.query(
      `INSERT INTO dogs (user_id, name, timezone, birth_date, weight_kg, sex, neutered, breed)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       RETURNING ${DOG_COLUMNS}`,
      [
        userId(req),
        b.name,
        b.timezone,
        b.birth_date ?? null,
        b.weight_kg ?? null,
        b.sex ?? null,
        b.neutered ?? null,
        b.breed || null,
      ],
    );
    return reply.code(201).send(r.rows[0]);
  });

  app.patch(
    "/v1/dogs/:id",
    { preHandler: requireUser, schema: { params: idParam, body: dogPatch } },
    async (req, reply) => {
      if (!(await ownDog(req, reply, req.params.id))) return;
      // column names come from the zod schema keys, never from the client
      const entries = Object.entries(req.body).map(([k, v]) => [k, k === "breed" && v === "" ? null : v] as const);
      const r = await pool.query(
        `UPDATE dogs SET ${entries.map(([k], i) => `${k} = $${i + 2}`).join(", ")}
          WHERE id = $1 RETURNING ${DOG_COLUMNS}`,
        [req.params.id, ...entries.map(([, v]) => v)],
      );
      return r.rows[0];
    },
  );

  // removes the dog with its collars, minutes, metrics and alerts (ON DELETE CASCADE)
  app.delete("/v1/dogs/:id", { preHandler: requireUser, schema: { params: idParam } }, async (req, reply) => {
    if (!(await ownDog(req, reply, req.params.id))) return;
    await pool.query("DELETE FROM dogs WHERE id = $1", [req.params.id]);
    return reply.code(204).send();
  });

  app.get("/v1/dogs", { preHandler: requireUser }, async (req) => {
    const r = await pool.query(
      `SELECT ${DOG_COLUMNS} FROM dogs WHERE user_id = $1 ORDER BY id`,
      [userId(req)],
    );
    return r.rows;
  });

  // Pairing. The same collar again on the same dog (new phone, reinstall) keeps its device
  // row and gets a new token, so re-sent minutes stay duplicates instead of doubling. On
  // another of the owner's dogs it starts a new row from now. Another account's active
  // collar is refused: its owner unpairs it first.
  app.post(
    "/v1/dogs/:id/devices",
    {
      preHandler: requireUser,
      schema: {
        params: idParam,
        body: z.object({ serial: z.string().min(3).max(64), name: z.string().trim().max(40).optional() }),
      },
    },
    async (req, reply) => {
      if (!(await ownDog(req, reply, req.params.id))) return;
      const { token, hash } = newDeviceToken();
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        const cur = (
          await client.query<{ id: string; dog_id: string; user_id: string }>(
            `SELECT d.id, d.dog_id, g.user_id FROM devices d JOIN dogs g ON g.id = d.dog_id
              WHERE d.serial = $1 AND d.retired_at IS NULL FOR UPDATE OF d`,
            [req.body.serial],
          )
        ).rows[0];
        if (cur && cur.user_id !== userId(req)) {
          await client.query("ROLLBACK");
          return reply.code(409).send({ error: "this collar is paired with another account" });
        }
        let deviceId: string;
        if (cur && Number(cur.dog_id) === req.params.id) {
          await client.query("UPDATE devices SET token_hash = $2, name = COALESCE($3, name) WHERE id = $1", [
            cur.id,
            hash,
            req.body.name ?? null,
          ]);
          deviceId = cur.id;
        } else {
          if (cur) await client.query("UPDATE devices SET retired_at = now() WHERE id = $1", [cur.id]);
          const r = await client.query<{ id: string }>(
            `INSERT INTO devices (dog_id, serial, token_hash, name, active_from)
             VALUES ($1, $2, $3, $4, CASE WHEN $5 THEN now() END) RETURNING id`,
            [req.params.id, req.body.serial, hash, req.body.name ?? null, Boolean(cur)],
          );
          deviceId = r.rows[0]!.id;
        }
        await client.query("COMMIT");
        // The token is returned once; the app hands it to the base station during setup.
        return reply.code(201).send({ device_id: deviceId, token });
      } catch (err) {
        await client.query("ROLLBACK");
        throw err;
      } finally {
        client.release();
      }
    },
  );

  app.get("/v1/dogs/:id/devices", { preHandler: requireUser, schema: { params: idParam } }, async (req, reply) => {
    if (!(await ownDog(req, reply, req.params.id))) return;
    const r = await pool.query(
      `SELECT d.id, d.serial, d.name, d.created_at,
              (SELECT max(a.minute_ts) FROM activity_minute a WHERE a.device_id = d.id) AS last_minute,
              (SELECT a.battery_pct FROM activity_minute a WHERE a.device_id = d.id
                ORDER BY a.minute_ts DESC LIMIT 1) AS battery_pct
         FROM devices d WHERE d.dog_id = $1 AND d.retired_at IS NULL ORDER BY d.id`,
      [req.params.id],
    );
    return r.rows;
  });

  // Unpair: the token stops working; the minutes it recorded stay with the dog.
  app.delete(
    "/v1/devices/:id",
    { preHandler: requireUser, schema: { params: idParam } },
    async (req, reply) => {
      const r = await pool.query(
        `UPDATE devices d SET retired_at = now() FROM dogs g
          WHERE d.id = $1 AND g.id = d.dog_id AND g.user_id = $2 AND d.retired_at IS NULL`,
        [req.params.id, userId(req)],
      );
      return r.rowCount ? reply.code(204).send() : reply.code(404).send({ error: "collar not found" });
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
        ? (
            await pool.query<{ id: string; active_from: Date | null }>(
              "SELECT id, active_from FROM devices WHERE token_hash = $1 AND retired_at IS NULL",
              [hashToken(token)],
            )
          ).rows[0]
        : undefined;
      if (!dev) return reply.code(401).send({ error: "invalid device token" });

      let decoded;
      try {
        decoded = decodeRecords(Buffer.from(req.body.records, "base64"));
      } catch (err) {
        return reply.code(400).send({ error: (err as Error).message });
      }
      const { rejected } = decoded;
      // a collar moved from another dog still holds that dog's minutes: not this dog's
      const from = dev.active_from ? Math.floor(dev.active_from.getTime() / 1000 / 60) * 60 : 0;
      const records = decoded.records.filter((r) => r.minuteTs >= from);
      const beforePairing = decoded.records.length - records.length;
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
        received: decoded.records.length + rejected.length,
        inserted,
        duplicates: records.length - inserted,
        before_pairing: beforePairing,
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
  const ME_COLUMNS = "id, email, name, created_at, consent_version, consent_at, research_opt_in";

  app.get("/v1/me", { preHandler: requireUser }, async (req, reply) => {
    const r = await pool.query(`SELECT ${ME_COLUMNS} FROM users WHERE id = $1`, [userId(req)]);
    return r.rows[0] ?? reply.code(404).send({ error: "user not found" });
  });

  app.patch(
    "/v1/me",
    { preHandler: requireUser, schema: { body: z.object({ name: z.string().trim().max(80).nullable() }) } },
    async (req) => {
      const r = await pool.query(`UPDATE users SET name = $2 WHERE id = $1 RETURNING ${ME_COLUMNS}`, [
        userId(req),
        req.body.name || null,
      ]);
      return r.rows[0];
    },
  );

  const passwordBody = z.object({
    current_password: z.string().min(1).max(200),
    new_password: z.string().min(10).max(200),
  });
  app.post(
    "/v1/me/password",
    { preHandler: [requireUser, limitAuth], schema: { body: passwordBody } },
    async (req, reply) => {
      const r = await pool.query<{ password_hash: string }>("SELECT password_hash FROM users WHERE id = $1", [
        userId(req),
      ]);
      const user = r.rows[0];
      if (!user || !(await verifyPassword(req.body.current_password, user.password_hash))) {
        return reply.code(403).send({ error: "current password is wrong" });
      }
      // signs out every other phone; this one gets a fresh token
      const u = await pool.query<{ token_version: number }>(
        "UPDATE users SET password_hash = $2, token_version = token_version + 1 WHERE id = $1 RETURNING token_version",
        [userId(req), await hashPassword(req.body.new_password)],
      );
      return { token: tokenFor(userId(req), u.rows[0]!.token_version) };
    },
  );

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
      devices: await q(
        `SELECT d.id, d.dog_id, d.serial, d.name, d.created_at, d.active_from, d.retired_at
           FROM devices d JOIN dogs g ON g.id = d.dog_id WHERE g.user_id = $1`,
      ),
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
