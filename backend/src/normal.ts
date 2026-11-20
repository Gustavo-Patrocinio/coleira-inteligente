/**
 * The dog's usual activity per hour of the day, for the app's timeline: "did he get his
 * usual morning walk?", "is he quieter than normal this afternoon?". Pure, unit-tested.
 *
 * For each local hour 0–23: the quartiles (25th, 50th, 75th percentile) of active minutes
 * (walking + running) in that hour over the previous 28 days. Same day type (weekday /
 * weekend) when there are enough such days, as the alerts do (ADR 0011). An hour of a day
 * counts only when the collar recorded most of it (≥ 45 min), so a gap does not look like
 * a lazy hour.
 */
import { isWeekend, MIN_SAME_TYPE_DAYS } from "./metrics.js";

export interface HourRow {
  day: string; // local YYYY-MM-DD
  hour: number; // local 0–23
  minutes: number; // minutes with data in that hour
  activeS: number; // walking + running seconds
}

export interface HourBand {
  hour: number;
  p25: number;
  median: number;
  p75: number;
  days: number;
}

export interface HourlyNormal {
  /** days of history behind the band; the band appears from MIN_NORMAL_DAYS */
  days_used: number;
  day_type: "weekday" | "weekend" | "all";
  /** 24 entries; null = too few recorded days for that hour */
  hours: (HourBand | null)[];
}

export const MIN_HOUR_COVERAGE_MIN = 45;
/** A week: fewer days than this and "usual" means little. */
export const MIN_NORMAL_DAYS = 7;
/** An hour needs this many recorded days to get a band. */
export const MIN_DAYS_PER_HOUR = 5;

/** Linear-interpolated quantile of sorted values (q in 0..1). */
export function quantile(sorted: number[], q: number): number {
  const pos = (sorted.length - 1) * q;
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  return sorted[lo]! + (sorted[hi]! - sorted[lo]!) * (pos - lo);
}

const round1 = (x: number) => Math.round(x * 10) / 10;

/** `rows` cover the 28 days before `day` (the caller's query); `day` itself is excluded. */
export function hourlyNormal(rows: HourRow[], day: string): HourlyNormal {
  const usable = rows.filter((r) => r.day < day && r.minutes >= MIN_HOUR_COVERAGE_MIN);
  const allDays = new Set(usable.map((r) => r.day));
  const weekend = isWeekend(day);
  const sameType = new Set([...allDays].filter((d) => isWeekend(d) === weekend));

  const useSameType = sameType.size >= MIN_SAME_TYPE_DAYS;
  const days = useSameType ? sameType : allDays;
  const dayType = useSameType ? (weekend ? "weekend" : "weekday") : "all";
  const hours: (HourBand | null)[] = Array(24).fill(null);
  if (allDays.size < MIN_NORMAL_DAYS) return { days_used: allDays.size, day_type: dayType, hours };

  const perHour: number[][] = Array.from({ length: 24 }, () => []);
  for (const r of usable) {
    if (!days.has(r.day)) continue;
    // scaled to a full hour, so 50 recorded minutes compare with 60
    perHour[r.hour]!.push(Math.min(60, r.activeS / 60 / (r.minutes / 60)));
  }
  perHour.forEach((xs, hour) => {
    if (xs.length < MIN_DAYS_PER_HOUR) return;
    const s = [...xs].sort((a, b) => a - b);
    hours[hour] = {
      hour,
      p25: round1(quantile(s, 0.25)),
      median: round1(quantile(s, 0.5)),
      p75: round1(quantile(s, 0.75)),
      days: s.length,
    };
  });
  return { days_used: days.size, day_type: dayType, hours };
}
