import { describe, expect, it } from "vitest";
import {
  addDays,
  computeDailyMetrics,
  evaluateDay,
  localParts,
  mad,
  median,
  type DayMetrics,
  type MinuteRow,
} from "../src/metrics.js";

const TZ = "America/Sao_Paulo"; // UTC−3 all year (no DST since 2019)
/** A wall-clock time in São Paulo as a Date. */
const sp = (day: string, h: number, m = 0) =>
  new Date(Date.parse(`${day}T00:00:00Z`) + ((h + 3) * 60 + m) * 60_000);
const row = (t: Date, walk = 0, scratch = 0): MinuteRow => ({
  minuteTs: t,
  walkingS: walk,
  runningS: 0,
  scratchingS: scratch,
});

describe("time zones", () => {
  it("assigns minutes to the local day", () => {
    // 01:30 UTC on Mar 11 is 22:30 on Mar 10 in São Paulo
    expect(localParts(new Date("2026-03-11T01:30:00Z"), TZ)).toEqual({ day: "2026-03-10", hour: 22 });
    expect(localParts(new Date("2026-03-11T01:30:00Z"), "UTC").day).toBe("2026-03-11");
  });

  it("adds days across month ends", () => {
    expect(addDays("2026-02-28", 1)).toBe("2026-03-01");
    expect(addDays("2026-03-01", -1)).toBe("2026-02-28");
  });
});

describe("daily metrics", () => {
  it("sums activity and scratching per local day", () => {
    const m = computeDailyMetrics(
      [row(sp("2026-03-10", 9), 60), row(sp("2026-03-10", 14), 0, 40), row(sp("2026-03-11", 9), 30)],
      TZ,
    );
    expect(m).toEqual([
      { day: "2026-03-10", coverageMin: 2, activeS: 60, scratchingS: 40, nightWakeups: 0 },
      { day: "2026-03-11", coverageMin: 1, activeS: 30, scratchingS: 0, nightWakeups: 0 },
    ]);
  });

  it("counts night wake-ups, merges close minutes, credits them to the morning", () => {
    const rows = [
      row(sp("2026-03-10", 23, 30), 40), // 23:30 → night of Mar 11
      row(sp("2026-03-10", 23, 31), 40), // same episode
      row(sp("2026-03-11", 2, 10), 50), // new episode
      row(sp("2026-03-11", 2, 12), 50), // 2 min later → same episode
      row(sp("2026-03-11", 4, 0), 10), // < 20 s: not "up"
      row(sp("2026-03-11", 7, 0), 60), // daytime: not a wake-up
    ];
    const m = computeDailyMetrics(rows, TZ);
    expect(m.find((d) => d.day === "2026-03-11")!.nightWakeups).toBe(2);
    expect(m.find((d) => d.day === "2026-03-10")!.nightWakeups).toBe(0);
  });
});

describe("robust statistics", () => {
  it("median and MAD", () => {
    expect(median([3, 1, 2])).toBe(2);
    expect(median([4, 1, 2, 3])).toBe(2.5);
    expect(mad([1, 1, 2, 2, 4, 6, 9])).toBe(1);
  });
});

describe("alert rules", () => {
  const day = (d: string, over: Partial<DayMetrics> = {}): DayMetrics => ({
    day: d,
    coverageMin: 1440,
    activeS: 3 * 3600,
    scratchingS: 180,
    nightWakeups: 1,
    ...over,
  });
  const history = (n: number, start = "2026-09-01") =>
    Array.from({ length: n }, (_, i) =>
      day(addDays(start, i), { activeS: 3 * 3600 + (i % 5) * 300, scratchingS: 150 + (i % 4) * 30 }),
    );

  it("needs at least 14 days of history", () => {
    expect(evaluateDay(day("2026-09-14", { scratchingS: 900 }), history(13))).toEqual([]);
    expect(evaluateDay(day("2026-09-15", { scratchingS: 900 }), history(14)).map((a) => a.metric)).toEqual([
      "scratching",
    ]);
  });

  it("flags high scratching and both directions of activity, ignores normal days", () => {
    const h = history(28);
    expect(evaluateDay(day("2026-09-29"), h)).toEqual([]);
    expect(evaluateDay(day("2026-09-29", { activeS: 1800 }), h)).toMatchObject([
      { metric: "activity", direction: "low" },
    ]);
    expect(evaluateDay(day("2026-09-29", { scratchingS: 10 }), h)).toEqual([]); // low scratching is fine
  });

  it("skips incomplete days (a sync gap must not look like a lazy dog)", () => {
    expect(evaluateDay(day("2026-09-29", { coverageMin: 600, activeS: 600 }), history(28))).toEqual([]);
  });

  it("uses a floor on the spread for very regular dogs", () => {
    const flat = Array.from({ length: 20 }, (_, i) => day(addDays("2026-09-01", i), { nightWakeups: 0 }));
    expect(evaluateDay(day("2026-09-21", { nightWakeups: 2 }), flat)).toEqual([]); // z = 2 with σ floor 1
    expect(evaluateDay(day("2026-09-21", { nightWakeups: 4 }), flat)).toMatchObject([
      { metric: "night_wakeups" },
    ]);
  });
});
