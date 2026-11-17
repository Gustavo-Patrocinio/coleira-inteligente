/**
 * Sleep estimated from movement (actigraphy), level 1 of docs/product/indicators.md.
 * Pure function over per-minute records; unit-tested in tests/sleep.test.ts.
 *
 * Sleep page for day D (dog's local time):
 * - Night = the main rest period inside 20:00 on D−1 → 11:00 on D (the night "belongs" to
 *   the morning, like night_wakeups).
 * - A minute is "rest" when it is almost all `still` (≥ 45 s) with ≤ 5 s of any movement.
 * - Main rest period: from the start of the first rest run of ≥ 30 min to the end of the
 *   last such run. Inside it: minutes at rest, awakenings (runs of non-rest minutes; runs
 *   separated by < 2 rest minutes count as one), longest uninterrupted rest.
 * - Naps: rest runs of ≥ 20 min between 11:00 and 20:00 on D.
 *
 * It is an estimate: a dog lying awake and still counts as rest. The app always says
 * "estimated from movement" and never shows sleep stages or quality scores.
 */

export interface SleepMinute {
  minuteTs: Date;
  stillS: number;
  movingS: number; // walking + running + scratching + shaking + eating + drinking
}

export interface NightSleep {
  bedtime: string; // ISO instant: start of the main rest period
  wakeTime: string; // ISO instant: end of the main rest period
  inBedMin: number; // bedtime → wake time
  restMin: number;
  awakenings: number;
  longestRestMin: number;
  missingMin: number; // minutes without data inside the period
}

export interface SleepSummary {
  day: string;
  night: NightSleep | null;
  nightCoverage: number; // fraction of the 20:00–11:00 window with data
  naps: { count: number; totalMin: number };
  method: "estimated from movement";
}

const REST_STILL_S = 45;
const REST_MAX_MOVING_S = 5;
const MAIN_RUN_MIN = 30;
const NAP_RUN_MIN = 20;
const AWAKE_MERGE_MIN = 2;
const NIGHT_START_H = 20; // on D−1
const NIGHT_END_H = 11; // on D
const NAP_END_H = 20; // on D

const fmt = new Map<string, Intl.DateTimeFormat>();

/** Local wall-clock date and time of an instant, as a pseudo-UTC epoch (ms). */
function wallClock(d: Date, tz: string): number {
  let f = fmt.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-CA", {
      timeZone: tz,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    });
    fmt.set(tz, f);
  }
  const p: Record<string, number> = {};
  for (const x of f.formatToParts(d)) p[x.type] = Number(x.value);
  const n = (k: string) => p[k] ?? 0;
  return Date.UTC(n("year"), n("month") - 1, n("day"), n("hour"), n("minute"));
}

type Slot = "rest" | "active" | "missing";

function classify(m: SleepMinute): Slot {
  return m.stillS >= REST_STILL_S && m.movingS <= REST_MAX_MOVING_S ? "rest" : "active";
}

/** Runs of `rest` as [start, end) slot indices. */
function restRuns(slots: Slot[]): [number, number][] {
  const out: [number, number][] = [];
  let start = -1;
  slots.forEach((s, i) => {
    if (s === "rest" && start < 0) start = i;
    if (s !== "rest" && start >= 0) {
      out.push([start, i]);
      start = -1;
    }
  });
  if (start >= 0) out.push([start, slots.length]);
  return out;
}

export function sleepSummary(rows: SleepMinute[], day: string, tz: string): SleepSummary {
  const dayStart = Date.UTC(+day.slice(0, 4), +day.slice(5, 7) - 1, +day.slice(8, 10));
  const winStart = dayStart - (24 - NIGHT_START_H) * 3_600_000;
  const nightLen = (24 - NIGHT_START_H + NIGHT_END_H) * 60;
  const napLen = (NAP_END_H - NIGHT_END_H) * 60;
  // slots cover 20:00 D−1 → 20:00 D in local wall-clock minutes
  const slots: Slot[] = Array(nightLen + napLen).fill("missing");
  const instants: (Date | null)[] = Array(slots.length).fill(null);
  for (const r of rows) {
    const i = Math.floor((wallClock(r.minuteTs, tz) - winStart) / 60_000);
    if (i >= 0 && i < slots.length) {
      slots[i] = classify(r);
      instants[i] = r.minuteTs;
    }
  }
  const night = slots.slice(0, nightLen);
  const nightCoverage = night.filter((s) => s !== "missing").length / nightLen;

  const main = restRuns(night).filter(([a, b]) => b - a >= MAIN_RUN_MIN);
  let nightSleep: NightSleep | null = null;
  if (main.length > 0) {
    const start = (main[0] as [number, number])[0];
    const end = (main[main.length - 1] as [number, number])[1];
    const span = night.slice(start, end);
    let awakenings = 0;
    let restSinceAwake = Infinity;
    for (const s of span) {
      if (s === "active") {
        if (restSinceAwake >= AWAKE_MERGE_MIN) awakenings += 1;
        restSinceAwake = 0;
      } else if (s === "rest") {
        restSinceAwake += 1;
      }
    }
    const runs = restRuns(span);
    const at = (i: number) => (instants[i] as Date).getTime();
    nightSleep = {
      bedtime: new Date(at(start)).toISOString(),
      wakeTime: new Date(at(end - 1) + 60_000).toISOString(),
      inBedMin: end - start,
      restMin: span.filter((s) => s === "rest").length,
      awakenings,
      longestRestMin: Math.max(...runs.map(([a, b]) => b - a)),
      missingMin: span.filter((s) => s === "missing").length,
    };
  }

  const naps = restRuns(slots.slice(nightLen)).filter(([a, b]) => b - a >= NAP_RUN_MIN);
  return {
    day,
    night: nightSleep,
    nightCoverage,
    naps: { count: naps.length, totalMin: naps.reduce((s, [a, b]) => s + b - a, 0) },
    method: "estimated from movement",
  };
}
