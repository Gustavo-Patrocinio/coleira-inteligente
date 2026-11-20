// Usual active minutes per hour (src/normal.ts): quartiles, day types, coverage rules.
import { describe, expect, it } from "vitest";
import { addDays } from "../src/metrics.js";
import { hourlyNormal, type HourRow, quantile } from "../src/normal.js";

/** n days before `day`, each with the given hour fully recorded and `activeMin` active. */
function days(day: string, n: number, hour: number, activeMin: (i: number) => number, minutes = 60): HourRow[] {
  return Array.from({ length: n }, (_, i) => ({
    day: addDays(day, -(i + 1)),
    hour,
    minutes,
    activeS: activeMin(i) * 60,
  }));
}

describe("hourlyNormal", () => {
  it("quantile interpolates", () => {
    expect(quantile([0, 10], 0.25)).toBe(2.5);
    expect(quantile([1, 2, 3, 4, 5], 0.5)).toBe(3);
  });

  it("needs a week of history before showing anything", () => {
    const n = hourlyNormal(days("2026-11-20", 6, 7, () => 30), "2026-11-20");
    expect(n.days_used).toBe(6);
    expect(n.hours.every((h) => h === null)).toBe(true);
  });

  it("quartiles of the morning walk; hours with few days stay empty", () => {
    // 2026-11-20 is a Friday; 20 days back mixes weekdays and weekends
    const rows = [
      ...days("2026-11-20", 20, 7, (i) => 20 + (i % 5) * 5), // 20..40 active minutes
      ...days("2026-11-20", 3, 15, () => 10), // only 3 days recorded at 15h
    ];
    const n = hourlyNormal(rows, "2026-11-20");
    expect(n.day_type).toBe("weekday");
    const seven = n.hours[7]!;
    expect(seven.p25).toBeLessThanOrEqual(seven.median);
    expect(seven.median).toBeLessThanOrEqual(seven.p75);
    expect(seven.median).toBeGreaterThanOrEqual(20);
    expect(seven.p75).toBeLessThanOrEqual(40);
    expect(n.hours[15]).toBeNull();
    expect(n.hours[3]).toBeNull();
  });

  it("weekends compare with weekends when there are enough of them", () => {
    // 28 days: weekday mornings 40 active minutes, weekend mornings 5
    const rows = days("2026-11-22", 28, 9, (i) => {
      const wd = new Date(`${addDays("2026-11-22", -(i + 1))}T00:00:00Z`).getUTCDay();
      return wd === 0 || wd === 6 ? 5 : 40;
    });
    const sunday = hourlyNormal(rows, "2026-11-22");
    expect(sunday.day_type).toBe("weekend");
    expect(sunday.hours[9]!.median).toBe(5);
    const monday = hourlyNormal(rows, "2026-11-23");
    expect(monday.day_type).toBe("weekday");
    expect(monday.hours[9]!.median).toBe(40);
  });

  it("partly recorded hours scale to 60 min; mostly empty hours and the day itself are left out", () => {
    const rows = [
      ...days("2026-11-20", 10, 8, () => 25, 50), // 25 of 50 recorded minutes → 30 per hour
      ...days("2026-11-20", 10, 10, () => 50, 30), // only 30 min recorded: not counted
      { day: "2026-11-20", hour: 8, minutes: 60, activeS: 60 * 60 }, // today: excluded
    ];
    const n = hourlyNormal(rows, "2026-11-20");
    expect(n.hours[8]!.median).toBe(30);
    expect(n.hours[8]!.days).toBeLessThanOrEqual(10);
    expect(n.hours[10]).toBeNull();
  });
});
