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
import type { MailMessage } from "../src/mail.js";
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

  it("keeps owner and dog profiles, edits and removes them", async () => {
    const owner = await user("profile@example.com");
    const other = await user("intruder@example.com");
    const created = await app.inject({
      method: "POST",
      url: "/v1/dogs",
      headers: owner,
      payload: { name: " Mel ", sex: "female", breed: "Mixed", birth_date: "2021-03-10", weight_kg: 12.5 },
    });
    expect(created.statusCode).toBe(201);
    const mel = created.json();
    expect(mel).toMatchObject({ name: "Mel", sex: "female", breed: "Mixed", birth_date: "2021-03-10", neutered: null });
    expect(Number(mel.weight_kg)).toBe(12.5);

    const edit = (headers: Record<string, string>, payload: object) =>
      app.inject({ method: "PATCH", url: `/v1/dogs/${mel.id}`, headers, payload });
    const edited = await edit(owner, { neutered: true, weight_kg: 13.1, breed: null });
    expect(edited.json()).toMatchObject({ name: "Mel", neutered: true, breed: null, birth_date: "2021-03-10" });
    expect((await edit(owner, {})).statusCode).toBe(400);
    expect((await edit(owner, { birth_date: "2999-01-01" })).statusCode).toBe(400);
    expect((await edit(owner, { name: "" })).statusCode).toBe(400);
    expect((await edit(other, { name: "Mine now" })).statusCode).toBe(404);

    const me = await app.inject({ method: "PATCH", url: "/v1/me", headers: owner, payload: { name: "Gustavo" } });
    expect(me.json()).toMatchObject({ email: "profile@example.com", name: "Gustavo" });

    const pw = (payload: object) => app.inject({ method: "POST", url: "/v1/me/password", headers: owner, payload });
    expect((await pw({ current_password: "wrong password!", new_password: "another long one" })).statusCode).toBe(403);
    expect((await pw({ current_password: "correct horse battery", new_password: "short" })).statusCode).toBe(400);
    const changed = await pw({ current_password: "correct horse battery", new_password: "another long one" });
    expect(changed.statusCode).toBe(200);
    // the old token stops working (other phones are signed out); the answer brings a new one
    expect((await app.inject({ method: "GET", url: "/v1/me", headers: owner })).statusCode).toBe(401);
    owner.authorization = `Bearer ${changed.json().token}`;
    expect((await app.inject({ method: "GET", url: "/v1/me", headers: owner })).statusCode).toBe(200);
    const login = (password: string) =>
      app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "profile@example.com", password } });
    expect((await login("correct horse battery")).statusCode).toBe(401);
    expect((await login("another long one")).statusCode).toBe(200);

    expect((await app.inject({ method: "DELETE", url: `/v1/dogs/${mel.id}`, headers: other })).statusCode).toBe(404);
    expect((await app.inject({ method: "DELETE", url: `/v1/dogs/${mel.id}`, headers: owner })).statusCode).toBe(204);
    expect((await app.inject({ method: "GET", url: "/v1/dogs", headers: owner })).json()).toEqual([]);
  });

  it("several dogs and collars: re-pair, move a collar between dogs, unpair", async () => {
    const owner = await user("pack@example.com");
    const { dogId: thor, device: oldToken } = await dogWithDevice(owner, "AA:00:00:00:00:21");
    const mel = (await app.inject({ method: "POST", url: "/v1/dogs", headers: owner, payload: { name: "Mel" } })).json().id;
    const pair = (dog: string, serial: string, headers = owner) =>
      app.inject({ method: "POST", url: `/v1/dogs/${dog}/devices`, headers, payload: { serial, name: "Blue" } });
    const devices = async (dog: string) =>
      (await app.inject({ method: "GET", url: `/v1/dogs/${dog}/devices`, headers: owner })).json();
    const total = async (dog: string) =>
      (await app.inject({ method: "GET", url: `/v1/dogs/${dog}/days/2026-10-05`, headers: owner })).json().totals.walking_s;

    const week = Array.from({ length: 60 }, (_, i) => minute(spTs("2026-10-05", 8 * 60 + i), 30));
    expect((await ingest(oldToken, week)).json().inserted).toBe(60);

    // a new phone pairs the same collar to the same dog: same row, new token, no double count
    const again = await pair(thor, "AA:00:00:00:00:21");
    expect(again.statusCode).toBe(201);
    const newToken = { authorization: `Bearer ${again.json().token}` };
    expect((await ingest(oldToken, week)).statusCode).toBe(401);
    expect((await ingest(newToken, week)).json()).toMatchObject({ inserted: 0, duplicates: 60 });
    expect(await devices(thor)).toMatchObject([{ serial: "AA:00:00:00:00:21", name: "Blue", battery_pct: 90 }]);

    // a second collar for Mel, then Thor's collar moves to Mel too
    expect((await pair(mel, "AA:00:00:00:00:22")).statusCode).toBe(201);
    const moved = await pair(mel, "AA:00:00:00:00:21");
    expect(moved.statusCode).toBe(201);
    const melToken = { authorization: `Bearer ${moved.json().token}` };
    expect((await ingest(newToken, week)).statusCode).toBe(401); // Thor's row is retired
    // the collar re-sends Thor's minutes: kept with Thor, not credited to Mel
    expect((await ingest(melToken, week)).json()).toMatchObject({ inserted: 0, before_pairing: 60 });
    expect(await total(thor)).toBe(1800);
    expect(await total(mel)).toBe(0);
    expect(await devices(thor)).toEqual([]);
    expect((await devices(mel)).map((d: { serial: string }) => d.serial)).toEqual([
      "AA:00:00:00:00:22",
      "AA:00:00:00:00:21",
    ]);

    // another account cannot take an active collar; after unpairing it can
    const neighbor = await user("neighbor@example.com");
    const nDog = (await app.inject({ method: "POST", url: "/v1/dogs", headers: neighbor, payload: { name: "Bob" } })).json().id;
    expect((await pair(nDog, "AA:00:00:00:00:21", neighbor)).statusCode).toBe(409);
    const melCollar = (await devices(mel)).find((d: { serial: string }) => d.serial === "AA:00:00:00:00:21");
    expect((await app.inject({ method: "DELETE", url: `/v1/devices/${melCollar.id}`, headers: neighbor })).statusCode).toBe(404);
    expect((await app.inject({ method: "DELETE", url: `/v1/devices/${melCollar.id}`, headers: owner })).statusCode).toBe(204);
    expect((await ingest(melToken, week)).statusCode).toBe(401);
    expect((await pair(nDog, "AA:00:00:00:00:21", neighbor)).statusCode).toBe(201);
  });

  it("health checks the database", async () => {
    const r = await app.inject({ method: "GET", url: "/health" });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ ok: true });
  });

  it("health/backups: 404 when not watched, 503 with the reason when late", async () => {
    expect((await app.inject({ method: "GET", url: "/health/backups" })).statusCode).toBe(404);
    const watched = await buildApp({ pool, jwtSecret: "test-secret-test-secret", backupDir: "/nonexistent-dir" });
    const r = await watched.inject({ method: "GET", url: "/health/backups" });
    expect(r.statusCode).toBe(503);
    expect(r.json().problems).toEqual(["backup folder not readable"]);
    await watched.close();
  });

  it("password reset by email: one code, 15 minutes, 5 guesses, signs out other phones", async () => {
    const sent: MailMessage[] = [];
    const withMail = await buildApp({
      pool,
      jwtSecret: "test-secret-test-secret",
      mailer: { send: async (m) => void sent.push(m) },
    });
    const post = (url: string, payload: object) => withMail.inject({ method: "POST", url, payload });
    const email = "forgot@example.com";
    const phone = await user(email); // a phone already signed in
    const codeOf = (m: MailMessage) => /(\d{6})/.exec(m.text)![1]!;

    // unknown email: same answer, nothing sent
    expect((await post("/v1/auth/forgot", { email: "nobody@example.com" })).statusCode).toBe(202);
    expect(sent).toHaveLength(0);

    expect((await post("/v1/auth/forgot", { email: "Forgot@Example.com" })).statusCode).toBe(202);
    expect(sent).toHaveLength(1);
    expect(sent[0]!.to).toBe(email);
    const code = codeOf(sent[0]!);
    // asking again within a minute does not send (or replace) a code
    expect((await post("/v1/auth/forgot", { email })).statusCode).toBe(202);
    expect(sent).toHaveLength(1);

    const reset = (c: string) => post("/v1/auth/reset", { email, code: c, new_password: "a brand new password" });
    const wrong = code === "000000" ? "111111" : "000000";
    expect((await reset(wrong)).statusCode).toBe(400);
    const ok = await reset(code);
    expect(ok.statusCode).toBe(200);
    expect((await withMail.inject({ method: "GET", url: "/v1/me", headers: phone })).statusCode).toBe(401);
    const fresh = { authorization: `Bearer ${ok.json().token}` };
    expect((await withMail.inject({ method: "GET", url: "/v1/me", headers: fresh })).statusCode).toBe(200);
    expect((await reset(code)).statusCode).toBe(400); // used once
    const login = await post("/v1/auth/login", { email, password: "a brand new password" });
    expect(login.statusCode).toBe(200);

    // 5 wrong guesses burn the code, even the right one fails afterwards
    await pool.query("UPDATE password_resets SET created_at = now() - interval '2 minutes'");
    await post("/v1/auth/forgot", { email });
    expect(sent).toHaveLength(2);
    const second = codeOf(sent[1]!);
    const miss = second === "000000" ? "111111" : "000000";
    for (let i = 0; i < 5; i++) expect((await reset(miss)).statusCode).toBe(400);
    expect((await reset(second)).statusCode).toBe(400);

    // expired codes fail
    await pool.query("DELETE FROM password_resets");
    await post("/v1/auth/forgot", { email });
    await pool.query("UPDATE password_resets SET expires_at = now() - interval '1 second'");
    expect((await reset(codeOf(sent[2]!))).statusCode).toBe(400);
    await withMail.close();

    // a server without email says so instead of pretending
    expect((await app.inject({ method: "POST", url: "/v1/auth/forgot", payload: { email } })).statusCode).toBe(501);
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

  it("usual activity per hour from the previous weeks, in the dog's time zone", async () => {
    // own app: the shared one has used up this test file's sign-up allowance
    const a = await buildApp({ pool, jwtSecret: "test-secret-test-secret" });
    const reg = await a.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: { email: "normal@example.com", password: "correct horse battery" },
    });
    const owner = { authorization: `Bearer ${reg.json().token}` };
    const dogId = (await a.inject({ method: "POST", url: "/v1/dogs", headers: owner, payload: { name: "Thor", timezone: TZ } })).json().id;
    const pair = await a.inject({ method: "POST", url: `/v1/dogs/${dogId}/devices`, headers: owner, payload: { serial: "AA:00:00:00:00:51" } });
    const device = { authorization: `Bearer ${pair.json().token}` };
    // 10 days before 2026-10-20: 07:00-07:59 local with 30 s walking per minute, 08:00 still
    const recs: MinuteRecord[] = [];
    for (let d = 10; d >= 1; d--) {
      const day = new Date(Date.parse("2026-10-20T00:00:00Z") - d * 86_400_000).toISOString().slice(0, 10);
      for (let m = 7 * 60; m < 9 * 60; m++) recs.push(minute(spTs(day, m), m < 8 * 60 ? 30 : 0));
    }
    const up = await a.inject({ method: "POST", url: "/v1/ingest", headers: device, payload: { records: b64(recs), via: "app" } });
    expect(up.json().inserted).toBe(recs.length);

    const r = await a.inject({ method: "GET", url: `/v1/dogs/${dogId}/normal/2026-10-20`, headers: owner });
    expect(r.statusCode).toBe(200);
    const n = r.json();
    // 2026-10-20 is a Tuesday: 6 of the 10 days are weekdays, enough to compare like with like
    expect(n.day_type).toBe("weekday");
    expect(n.days_used).toBe(6);
    expect(n.hours).toHaveLength(24);
    expect(n.hours[7]).toMatchObject({ hour: 7, median: 30, p25: 30, p75: 30, days: 6 });
    expect(n.hours[8]).toMatchObject({ median: 0 });
    expect(n.hours[6]).toBeNull();
    expect((await a.inject({ method: "GET", url: `/v1/dogs/${dogId}/normal/2026-10-20` })).statusCode).toBe(401);
    await a.close();
  });
});
