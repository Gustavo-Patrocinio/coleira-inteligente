import { describe, expect, it } from "vitest";
import { type SleepMinute, sleepSummary } from "../src/sleep.js";

const TZ = "America/Sao_Paulo"; // UTC−3, no DST

/** Minutes from local `from` to `to` (HH:MM on a local date), all rest or all active. */
function minutes(date: string, from: string, to: string, kind: "rest" | "active"): SleepMinute[] {
  const start = new Date(`${date}T${from}:00-03:00`).getTime();
  const end = new Date(`${date}T${to}:00-03:00`).getTime();
  const out: SleepMinute[] = [];
  for (let t = start; t < end; t += 60_000) {
    out.push({
      minuteTs: new Date(t),
      stillS: kind === "rest" ? 60 : 10,
      movingS: kind === "rest" ? 0 : 45,
    });
  }
  return out;
}

const night = [
  ...minutes("2026-11-09", "20:00", "22:00", "active"),
  ...minutes("2026-11-09", "22:00", "23:59", "rest"),
  ...minutes("2026-11-09", "23:59", "24:00", "rest"),
  ...minutes("2026-11-10", "00:00", "01:00", "rest"),
  ...minutes("2026-11-10", "01:00", "01:03", "active"), // awakening 1
  ...minutes("2026-11-10", "01:03", "03:00", "rest"),
  ...minutes("2026-11-10", "03:00", "03:01", "active"), // awakening 2 ...
  ...minutes("2026-11-10", "03:01", "03:02", "rest"),
  ...minutes("2026-11-10", "03:02", "03:03", "active"), // ... same episode (1 calm minute)
  ...minutes("2026-11-10", "03:03", "06:30", "rest"),
  ...minutes("2026-11-10", "06:30", "14:00", "active"),
  ...minutes("2026-11-10", "14:00", "14:45", "rest"), // nap
  ...minutes("2026-11-10", "14:45", "16:00", "active"),
  ...minutes("2026-11-10", "16:00", "16:10", "rest"), // too short for a nap
  ...minutes("2026-11-10", "16:10", "20:00", "active"),
];

describe("sleep estimated from movement", () => {
  it("finds bedtime, wake time, awakenings, longest stretch and naps", () => {
    const s = sleepSummary(night, "2026-11-10", TZ);
    expect(s.night).toEqual({
      bedtime: "2026-11-10T01:00:00.000Z", // 22:00 local on the 9th
      wakeTime: "2026-11-10T09:30:00.000Z", // 06:30 local
      inBedMin: 510,
      restMin: 505,
      awakenings: 2,
      longestRestMin: 207,
      missingMin: 0,
    });
    expect(s.nightCoverage).toBe(1);
    expect(s.naps).toEqual({ count: 1, totalMin: 45 });
    expect(s.method).toBe("estimated from movement");
  });

  it("restless night with no 30-minute rest has no main period", () => {
    const rows: SleepMinute[] = [];
    for (let h = 0; h < 15; h++) {
      const date = h < 4 ? "2026-11-09" : "2026-11-10";
      const hh = (20 + h) % 24;
      const at = `${String(hh).padStart(2, "0")}`;
      rows.push(...minutes(date, `${at}:00`, `${at}:20`, "rest"));
      rows.push(...minutes(date, `${at}:20`, `${at}:25`, "active"));
    }
    expect(sleepSummary(rows, "2026-11-10", TZ).night).toBeNull();
  });

  it("reports coverage and missing minutes when the collar was out of range", () => {
    const gap = night.filter((m) => {
      const t = m.minuteTs.toISOString();
      return !(t >= "2026-11-10T05:00:00.000Z" && t < "2026-11-10T06:00:00.000Z");
    });
    const s = sleepSummary(gap, "2026-11-10", TZ);
    expect(s.night?.missingMin).toBe(60);
    expect(s.night?.restMin).toBe(445);
    expect(s.nightCoverage).toBeCloseTo(1 - 60 / 900, 5);
  });

  it("ignores minutes outside the window", () => {
    const s = sleepSummary(minutes("2026-11-08", "22:00", "23:00", "rest"), "2026-11-10", TZ);
    expect(s.night).toBeNull();
    expect(s.nightCoverage).toBe(0);
  });
});
