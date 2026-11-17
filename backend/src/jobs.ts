/**
 * Baseline + alerts job: recomputes daily metrics for recent days of every dog and stores
 * the alerts the rules in metrics.ts produce. Idempotent: re-running does not duplicate.
 */
import type pg from "pg";
import {
  BASELINE_DAYS,
  addDays,
  computeDailyMetrics,
  evaluateDay,
  localParts,
  type DayMetrics,
  type MinuteRow,
} from "./metrics.js";
import { notifyNewAlerts, type PushSender } from "./push.js";

export interface JobResult {
  dogs: number;
  days: number;
  alerts: number;
  pushed: number;
}

/** `evaluateLastDays`: how many recent complete local days to (re)evaluate per dog. */
export async function runAlertsJob(
  pool: pg.Pool,
  now: Date = new Date(),
  evaluateLastDays = 3,
  push?: PushSender,
): Promise<JobResult> {
  const dogs = (await pool.query<{ id: string; timezone: string }>("SELECT id, timezone FROM dogs")).rows;
  let days = 0;
  let alerts = 0;

  for (const dog of dogs) {
    const today = localParts(now, dog.timezone).day;
    const from = addDays(today, -(BASELINE_DAYS + evaluateLastDays + 1));
    // one extra day before `from` so nights crossing midnight are complete
    const rows = (
      await pool.query<{ minute_ts: Date; walking_s: number; running_s: number; scratching_s: number }>(
        `SELECT a.minute_ts, a.walking_s, a.running_s, a.scratching_s
           FROM activity_minute a JOIN devices d ON d.id = a.device_id
          WHERE d.dog_id = $1 AND a.minute_ts >= ($2::date - 1)::timestamp AT TIME ZONE $3
                AND a.minute_ts < ($4::date)::timestamp AT TIME ZONE $3
          ORDER BY a.minute_ts`,
        [dog.id, from, dog.timezone, today],
      )
    ).rows;
    const minutes: MinuteRow[] = rows.map((r) => ({
      minuteTs: r.minute_ts,
      walkingS: r.walking_s,
      runningS: r.running_s,
      scratchingS: r.scratching_s,
    }));
    const metrics = computeDailyMetrics(minutes, dog.timezone).filter((m) => m.day >= from && m.day < today);

    for (const m of metrics) {
      await upsertDaily(pool, dog.id, m);
      days++;
    }
    const recent = metrics.filter((m) => m.day >= addDays(today, -evaluateLastDays));
    for (const target of recent) {
      for (const a of evaluateDay(target, metrics)) {
        const res = await pool.query(
          `INSERT INTO alerts (dog_id, day, metric, direction, value, median, robust_z)
           VALUES ($1, $2, $3, $4, $5, $6, $7)
           ON CONFLICT (dog_id, day, metric) DO NOTHING`,
          [dog.id, a.day, a.metric, a.direction, a.value, a.median, a.robustZ],
        );
        alerts += res.rowCount ?? 0;
      }
    }
  }
  let pushed = 0;
  if (push) {
    // the oldest day any dog could have been evaluated on in this run
    const since = addDays(now.toISOString().slice(0, 10), -(evaluateLastDays + 2));
    pushed = (await notifyNewAlerts(pool, push, since)).sent;
  }
  return { dogs: dogs.length, days, alerts, pushed };
}

async function upsertDaily(pool: pg.Pool, dogId: string, m: DayMetrics): Promise<void> {
  await pool.query(
    `INSERT INTO daily_metrics (dog_id, day, coverage_min, active_s, scratching_s, night_wakeups)
     VALUES ($1, $2, $3, $4, $5, $6)
     ON CONFLICT (dog_id, day) DO UPDATE SET
       coverage_min = EXCLUDED.coverage_min, active_s = EXCLUDED.active_s,
       scratching_s = EXCLUDED.scratching_s, night_wakeups = EXCLUDED.night_wakeups,
       updated_at = now()`,
    [dogId, m.day, m.coverageMin, m.activeS, m.scratchingS, m.nightWakeups],
  );
}
