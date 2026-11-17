import { describe, expect, it } from "vitest";
import { RECORD_SIZE, decodeRecords, encodeRecords, type MinuteRecord } from "../src/summary.js";

const NOW = Date.UTC(2026, 10, 17, 12) / 1000;
const rec = (minuteTs: number, seconds = [50, 10, 0, 0, 0, 0, 0], unknownS = 0): MinuteRecord => ({
  minuteTs,
  seconds,
  unknownS,
  batteryPct: 80,
  flags: 0,
});

describe("per-minute summary record (contract 4.7)", () => {
  it("is 15 bytes, little-endian, version first", () => {
    const t = NOW - (NOW % 60);
    const buf = encodeRecords([rec(t)]);
    expect(RECORD_SIZE).toBe(15);
    expect(buf.length).toBe(15);
    expect(buf[0]).toBe(1);
    expect(buf.readUInt32LE(1)).toBe(t);
    expect([...buf.subarray(5, 12)]).toEqual([50, 10, 0, 0, 0, 0, 0]);
  });

  it("round-trips", () => {
    const t = NOW - (NOW % 60);
    const records = [rec(t - 60), rec(t, [0, 0, 30, 20, 5, 0, 0], 5)];
    expect(decodeRecords(encodeRecords(records), NOW).records).toEqual(records);
  });

  it("rejects bad records individually and keeps the good ones", () => {
    const t = NOW - (NOW % 60) - 3600;
    const buf = encodeRecords([
      rec(t),
      rec(t + 60, [60, 10, 0, 0, 0, 0, 0]), // 70 s in one minute
      rec(t + 90), // not on a minute
      rec(NOW - (NOW % 60) + 3600), // an hour in the future
      rec(t + 120),
    ]);
    buf.writeUInt8(2, 15 * 4); // record #4 → unsupported version
    const { records, rejected } = decodeRecords(buf, NOW);
    expect(records.map((r) => r.minuteTs)).toEqual([t]);
    expect(rejected.map((r) => r.index)).toEqual([1, 2, 3, 4]);
    expect(rejected[0]!.reason).toMatch(/70 > 60/);
  });

  it("refuses payloads that are not whole records", () => {
    expect(() => decodeRecords(Buffer.alloc(16))).toThrow(/multiple of 15/);
  });
});
