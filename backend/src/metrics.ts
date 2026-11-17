/**
 * Daily metrics, baseline and alert rules (Phase 4). Pure functions, unit-tested.
 *
 * - Days and nights are in the dog's local time zone.
 * - Night of day D = 23:00 on D−1 → 06:00 on D (it "belongs" to the morning).
 * - Baseline: median and MAD of the same metric over the previous 28 days, same day type
 *   (weekday / weekend) when there are enough such days.
 * - Alert: robust z = (x − median) / (1.4826 · MAD) with |z| > 3, only with ≥ 14 days of
 *   history and a complete day of data.
 */

export interface MinuteRow {
  minuteTs: Date;
  walkingS: number;
  runningS: number;
  scratchingS: number;
}

export interface DayMetrics {
  day: string; // YYYY-MM-DD local
  coverageMin: number;
  activeS: number;
  scratchingS: number;
  nightWakeups: number;
}

export type Metric = "activity" | "scratching" | "night_wakeups";

export const BASELINE_DAYS = 28;
export const MIN_HISTORY_DAYS = 14;
export const MIN_SAME_TYPE_DAYS = 6;
export const MIN_COVERAGE_MIN = 20 * 60; // a day needs ≥ 20 h of data to count
export const Z_THRESHOLD = 3;
const MAD_TO_SIGMA = 1.4826;
// Floors for the spread so a very regular dog does not alert on tiny changes.
const MIN_SIGMA: Record<Metric, number> = { activity: 15 * 60, scratching: 60, night_wakeups: 1 };

const WAKE_ACTIVE_S = 20; // a minute with ≥ 20 s walking/running counts as "up"
const WAKE_GAP_MIN = 2; // up-minutes separated by < 2 calm minutes are one episode

const formatters = new Map<string, Intl.DateTimeFormat>();

/** Local calendar date and hour of an instant in an IANA time zone. */
export function localParts(d: Date, tz: string): { day: string; hour: number } {
  let f = formatters.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-CA", {
      timeZone: tz,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      hourCycle: "h23",
    });
    formatters.set(tz, f);
  }
  const p = Object.fromEntries(f.formatToParts(d).map((x) => [x.type, x.value]));
  return { day: `${p.year}-${p.month}-${p.day}`, hour: Number(p.hour) };
}

export function addDays(day: string, n: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export function isWeekend(day: string): boolean {
  const wd = new Date(`${day}T00:00:00Z`).getUTCDay();
  return wd === 0 || wd === 6;
}

export function computeDailyMetrics(rows: MinuteRow[], tz: string): DayMetrics[] {
  const days = new Map<string, DayMetrics>();
  const get = (day: string) => {
    let m = days.get(day);
    if (!m) {
      m = { day, coverageMin: 0, activeS: 0, scratchingS: 0, nightWakeups: 0 };
      days.set(day, m);
    }
    return m;
  };
  const sorted = [...rows].sort((a, b) => a.minuteTs.getTime() - b.minuteTs.getTime());
  let lastUpTs = -Infinity;
  let lastNightDay = "";

  for (const r of sorted) {
    const { day, hour } = localParts(r.minuteTs, tz);
    const m = get(day);
    m.coverageMin += 1;
    m.activeS += r.walkingS + r.runningS;
    m.scratchingS += r.scratchingS;

    const atNight = hour >= 23 || hour < 6;
    if (atNight && r.walkingS + r.runningS >= WAKE_ACTIVE_S) {
      const nightDay = hour >= 23 ? addDays(day, 1) : day;
      const t = r.minuteTs.getTime();
      const newEpisode = nightDay !== lastNightDay || t - lastUpTs > WAKE_GAP_MIN * 60_000;
      if (newEpisode) get(nightDay).nightWakeups += 1;
      lastUpTs = t;
      lastNightDay = nightDay;
    }
  }
  return [...days.values()].sort((a, b) => a.day.localeCompare(b.day));
}

export function median(xs: number[]): number {
  if (xs.length === 0) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid]! : (s[mid - 1]! + s[mid]!) / 2;
}

export function mad(xs: number[]): number {
  const m = median(xs);
  return median(xs.map((x) => Math.abs(x - m)));
}

export function metricValue(d: DayMetrics, metric: Metric): number {
  return metric === "activity" ? d.activeS : metric === "scratching" ? d.scratchingS : d.nightWakeups;
}

export interface AlertCandidate {
  day: string;
  metric: Metric;
  direction: "high" | "low";
  value: number;
  median: number;
  robustZ: number;
}

/** Evaluate one day against the previous 28 days. `history` may contain any days. */
export function evaluateDay(target: DayMetrics, history: DayMetrics[]): AlertCandidate[] {
  if (target.coverageMin < MIN_COVERAGE_MIN) return [];
  const from = addDays(target.day, -BASELINE_DAYS);
  const window = history.filter(
    (d) => d.day >= from && d.day < target.day && d.coverageMin >= MIN_COVERAGE_MIN,
  );
  if (window.length < MIN_HISTORY_DAYS) return [];
  const sameType = window.filter((d) => isWeekend(d.day) === isWeekend(target.day));
  const ref = sameType.length >= MIN_SAME_TYPE_DAYS ? sameType : window;

  const out: AlertCandidate[] = [];
  for (const metric of ["activity", "scratching", "night_wakeups"] as Metric[]) {
    const xs = ref.map((d) => metricValue(d, metric));
    const med = median(xs);
    const sigma = Math.max(MAD_TO_SIGMA * mad(xs), MIN_SIGMA[metric]);
    const value = metricValue(target, metric);
    const z = (value - med) / sigma;
    // Activity matters both ways (lethargy or hyperactivity); the others only when high.
    const fires = metric === "activity" ? Math.abs(z) > Z_THRESHOLD : z > Z_THRESHOLD;
    if (fires) {
      out.push({ day: target.day, metric, direction: z > 0 ? "high" : "low", value, median: med, robustZ: z });
    }
  }
  return out;
}
