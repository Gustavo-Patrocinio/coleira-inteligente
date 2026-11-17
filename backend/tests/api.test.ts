/**
 * Integration tests against a real Postgres + TimescaleDB (docker compose up -d).
 * Each run creates a throwaway database and drops it at the end. Skipped if no DB.
 */
import { randomBytes } from "node:crypto";
import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { createPool, migrate } from "../src/db.js";
import { runAlertsJob } from "../src/jobs.js";
import type { PushMessage, PushResult, PushSender } from "../src/push.js";
import { encodeRecords, type MinuteRecord } from "../src/summary.js";

const ADMIN_URL = process.env.TEST_ADMIN_URL ?? "postgres://collar:collar@localhost:54329/collar";
const dbName = `collar_test_${randomBytes(4).toString("hex")}`;
let available = true;
let pool: pg.Pool;
let app: Awaited<ReturnType<typeof buildApp>>;

beforeAll(async () => {
  const admin = new pg.Client({ connectionString: ADMIN_URL });
  try {
    await admin.connect();
  } catch {
    available = false;
    return;
  }
  await admin.query(`CREATE DATABASE ${dbName}`);
  await admin.end();
  const url = new URL(ADMIN_URL);
  url.pathname = `/${dbName}`;
  pool = createPool(url.toString());
  await migrate(pool);
  app = await buildApp({ pool, jwtSecret: "test-secret-test-secret" });
}, 60_000);

afterAll(async () => {
  if (!available) return;
  await app.close();
  await pool.end();
  const admin = new pg.Client({ connectionString: ADMIN_URL });
  await admin.connect();
  await admin.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`);
  await admin.end();
});

const TZ = "America/Sao_Paulo";
/** Epoch seconds of a São Paulo wall-clock minute (UTC−3). */
const spTs = (day: string, minuteOfDay: number) => Date.parse(`${day}T03:00:00Z`) / 1000 + minuteOfDay * 60;
const minute = (ts: number, walking = 0, scratching = 0): MinuteRecord => ({
  minuteTs: ts,
  seconds: [60 - walking - scratching, walking, 0, scratching, 0, 0, 0],
  unknownS: 0,
  batteryPct: 90,
  flags: 0,
});
const b64 = (records: MinuteRecord[]) => encodeRecords(records).toString("base64");

async function user(email: string) {
  const r = await app.inject({ method: "POST", url: "/v1/auth/register", payload: { email, password: "correct horse battery" } });
  expect(r.statusCode).toBe(201);
  return { authorization: `Bearer ${r.json().token}` };
}

async function dogWithDevice(headers: Record<string, string>, serial: string) {
  const dog = await app.inject({ method: "POST", url: "/v1/dogs", headers, payload: { name: "Thor", timezone: TZ } });
  expect(dog.statusCode).toBe(201);
  const dev = await app.inject({
    method: "POST",
    url: `/v1/dogs/${dog.json().id}/devices`,
    headers,
    payload: { serial },
  });
  expect(dev.statusCode).toBe(201);
  return { dogId: dog.json().id as string, device: { authorization: `Bearer ${dev.json().token}` } };
}

const ingest = (device: Record<string, string>, records: MinuteRecord[], via = "base_station") =>
  app.inject({ method: "POST", url: "/v1/ingest", headers: device, payload: { records: b64(records), via } });

describe.runIf(() => available)("API with a real database", () => {
  it("ingestion is idempotent across retries and across both sync paths", async () => {
    const owner = await user("idem@example.com");
    const { device } = await dogWithDevice(owner, "AA:00:00:00:00:01");
    const batch = Array.from({ length: 100 }, (_, i) => minute(spTs("2026-10-01", 8 * 60 + i), 30));

    const first = await ingest(device, batch);
    expect(first.json()).toMatchObject({ received: 100, inserted: 100, duplicates: 0 });
    const retry = await ingest(device, batch); // network hiccup → same batch again
    expect(retry.json()).toMatchObject({ inserted: 0, duplicates: 100 });
    // the phone syncs an overlapping range after the base station did
    const overlap = await ingest(device, [...batch.slice(50), minute(spTs("2026-10-01", 8 * 60 + 100))], "app");
    expect(overlap.json()).toMatchObject({ received: 51, inserted: 1, duplicates: 50 });
  });

  it("rejects bad records individually and bad tokens entirely", async () => {
    const owner = await user("reject@example.com");
    const { device } = await dogWithDevice(owner, "AA:00:00:00:00:02");
    const bad = minute(spTs("2026-10-02", 0));
    bad.seconds = [60, 60, 0, 0, 0, 0, 0];
    const r = await ingest(device, [minute(spTs("2026-10-02", 1)), bad]);
    expect(r.json()).toMatchObject({ inserted: 1, rejected: [{ index: 1 }] });

    const noAuth = await ingest({ authorization: "Bearer dev_nope" }, [minute(spTs("2026-10-02", 2))]);
    expect(noAuth.statusCode).toBe(401);
  });

  it("never shows one user's dog to another", async () => {
    const alice = await user("alice@example.com");
    const bob = await user("bob@example.com");
    const { dogId } = await dogWithDevice(alice, "AA:00:00:00:00:03");
    const r = await app.inject({ method: "GET", url: `/v1/dogs/${dogId}/days/2026-10-01`, headers: bob });
    expect(r.statusCode).toBe(404);
  });

  it("builds the day in the dog's time zone and tolerates sync gaps", async () => {
    const owner = await user("tz@example.com");
    const { dogId, device } = await dogWithDevice(owner, "AA:00:00:00:00:04");
    // 22:30–22:44 local on Oct 3 is 01:30 UTC on Oct 4; then a gap; then 23:30–23:34
    const recs = [
      ...Array.from({ length: 15 }, (_, i) => minute(spTs("2026-10-03", 22 * 60 + 30 + i), 60)),
      ...Array.from({ length: 5 }, (_, i) => minute(spTs("2026-10-03", 23 * 60 + 30 + i), 0, 20)),
    ];
    expect((await ingest(device, recs)).json().inserted).toBe(20);

    const day = await app.inject({ method: "GET", url: `/v1/dogs/${dogId}/days/2026-10-03`, headers: owner });
    expect(day.statusCode).toBe(200);
    const body = day.json();
    expect(body.totals.walking_s).toBe(15 * 60);
    expect(body.totals.scratching_s).toBe(5 * 20);
    expect(body.blocks.map((b: { minutes: number }) => b.minutes)).toEqual([15, 5]); // gap kept as a gap
    const next = await app.inject({ method: "GET", url: `/v1/dogs/${dogId}/days/2026-10-04`, headers: owner });
    expect(next.json().blocks).toEqual([]);
  });

  it("estimates the night's sleep in the dog's time zone", async () => {
    const owner = await user("sleep@example.com");
    const { dogId, device } = await dogWithDevice(owner, "AA:00:00:00:00:07");
    // Oct 5 21:00 → Oct 6 07:00 local: active until 22:00, rest with one 4-min walk at 02:00
    const recs: MinuteRecord[] = [];
    for (let m = 21 * 60; m < 34 * 60; m++) {
      const day = m < 24 * 60 ? "2026-10-05" : "2026-10-06";
      const local = m % (24 * 60);
      const awake = m < 22 * 60 || (m >= 26 * 60 && m < 26 * 60 + 4) || m >= 31 * 60;
      recs.push(minute(spTs(day, local), awake ? 40 : 0));
    }
    expect((await ingest(device, recs)).json().inserted).toBe(recs.length);
    const r = await app.inject({ method: "GET", url: `/v1/dogs/${dogId}/sleep/2026-10-06`, headers: owner });
    expect(r.statusCode).toBe(200);
    expect(r.json().night).toMatchObject({
      bedtime: "2026-10-06T01:00:00.000Z", // 22:00 local
      wake_time: "2026-10-06T10:00:00.000Z", // 07:00 local
      in_bed_min: 540,
      rest_min: 536,
      awakenings: 1,
    });
    expect(r.json().method).toBe("estimated from movement");
  });

  it("baseline job raises a scratching alert once, and the owner can give feedback", async () => {
    const owner = await user("alerts@example.com");
    const { dogId, device } = await dogWithDevice(owner, "AA:00:00:00:00:05");
    const days = Array.from({ length: 22 }, (_, i) => {
      const d = new Date(Date.UTC(2026, 8, 1 + i)).toISOString().slice(0, 10);
      return d;
    }); // Sep 1 … Sep 22 (target = Sep 22)
    for (const [i, d] of days.entries()) {
      const scratchMin = d === "2026-09-22" ? 15 : 2 + (i % 3); // normal: 2–4 min/day
      const recs = Array.from({ length: 1440 }, (_, m) =>
        minute(spTs(d, m), m >= 8 * 60 && m < 10 * 60 + (i % 4) * 5 ? 60 : 0, m >= 14 * 60 && m < 14 * 60 + scratchMin ? 60 : 0),
      );
      expect((await ingest(device, recs)).json().inserted).toBe(1440);
    }
    // two phones on the account; one was uninstalled (FCM says the token is gone)
    for (const [token, platform] of [["phone-ios-token-000000001", "ios"], ["phone-gone-token-00000002", "android"]]) {
      const r = await app.inject({ method: "PUT", url: "/v1/me/push-token", headers: owner, payload: { token, platform } });
      expect(r.statusCode).toBe(204);
    }
    const sent: [string, PushMessage][] = [];
    const push: PushSender = {
      send: async (token, msg): Promise<PushResult> => {
        sent.push([token, msg]);
        return token.includes("gone") ? "unregistered" : "ok";
      },
    };
    const now = new Date("2026-09-23T15:00:00Z"); // noon on Sep 23 in São Paulo
    const run1 = await runAlertsJob(pool, now, 3, push);
    expect(run1).toMatchObject({ alerts: 1, pushed: 1 });
    expect(sent.map(([t]) => t).sort()).toEqual(["phone-gone-token-00000002", "phone-ios-token-000000001"]);
    expect(sent[0]![1].title).toBe("Thor scratched more than usual");
    const run2 = await runAlertsJob(pool, now, 3, push); // idempotent: no new alert, no second push
    expect(run2).toMatchObject({ alerts: 0, pushed: 0 });
    expect(sent).toHaveLength(2);
    const left = await pool.query("SELECT token FROM push_tokens WHERE token LIKE 'phone-%'");
    expect(left.rows).toEqual([{ token: "phone-ios-token-000000001" }]); // dead token deleted

    const alerts = (await app.inject({ method: "GET", url: `/v1/dogs/${dogId}/alerts`, headers: owner })).json();
    expect(alerts).toHaveLength(1);
    expect(alerts[0]).toMatchObject({ metric: "scratching", direction: "high", value: 900, day: "2026-09-22" });

    const metrics = await pool.query("SELECT day, scratching_s FROM daily_metrics WHERE dog_id = $1 ORDER BY day", [dogId]);
    expect(metrics.rows.at(-1)).toEqual({ day: "2026-09-22", scratching_s: 900 }); // local day as plain text

    const fb = await app.inject({
      method: "POST",
      url: `/v1/alerts/${alerts[0].id}/feedback`,
      headers: owner,
      payload: { feedback: "useful" },
    });
    expect(fb.statusCode).toBe(200);
  }, 120_000);

  it("exports and deletes all of a user's data (LGPD)", async () => {
    const owner = await user("privacy@example.com");
    const { device } = await dogWithDevice(owner, "AA:00:00:00:00:06");
    await ingest(device, [minute(spTs("2026-10-05", 600), 30)]);

    const exp = await app.inject({ method: "GET", url: "/v1/me/export", headers: owner });
    expect(exp.json().activity_minute).toHaveLength(1);

    const del = await app.inject({ method: "DELETE", url: "/v1/me", headers: owner });
    expect(del.statusCode).toBe(204);
    const login = await app.inject({
      method: "POST",
      url: "/v1/auth/login",
      payload: { email: "privacy@example.com", password: "correct horse battery" },
    });
    expect(login.statusCode).toBe(401);
    const left = await pool.query(
      "SELECT count(*)::int AS n FROM activity_minute a JOIN devices d ON d.id = a.device_id WHERE d.serial = $1",
      ["AA:00:00:00:00:06"],
    );
    expect(left.rows[0].n).toBe(0);
  });

  it("records consent (LGPD) and the separate research opt-in", async () => {
    const owner = await user("consent@example.com");
    const before = await app.inject({ method: "GET", url: "/v1/me", headers: owner });
    expect(before.json()).toMatchObject({ email: "consent@example.com", consent_version: null, research_opt_in: false });

    const put = await app.inject({
      method: "PUT",
      url: "/v1/me/consent",
      headers: owner,
      payload: { version: 1, research_opt_in: true },
    });
    expect(put.statusCode).toBe(200);
    expect(put.json()).toMatchObject({ consent_version: 1, research_opt_in: true });
    expect(put.json().consent_at).toBeTruthy();

    const exp = await app.inject({ method: "GET", url: "/v1/me/export", headers: owner });
    expect(exp.json().user).toMatchObject({ consent_version: 1, research_opt_in: true });
    expect(exp.json().user.password_hash).toBeUndefined();
  });

  it("rate-limits login attempts per IP", async () => {
    const limited = await buildApp({ pool, jwtSecret: "test-secret-0123456789", authAttemptsPer15Min: 3 });
    const tryLogin = () =>
      limited.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "nobody@example.com", password: "wrong password" } });
    for (let i = 0; i < 3; i++) expect((await tryLogin()).statusCode).toBe(401);
    const blocked = await tryLogin();
    expect(blocked.statusCode).toBe(429);
    expect(Number(blocked.headers["retry-after"])).toBeGreaterThan(0);
    await limited.close();
  });
});
