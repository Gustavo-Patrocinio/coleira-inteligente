/**
 * Per-minute summary record, contract 4.7 / ADR 0001 (little-endian, 15 bytes):
 *   0  uint8   version (=1)
 *   1  uint32  minute_ts (epoch s, UTC)
 *   5  uint8×7 seconds per class 0..6 (still, walking, running, scratching, shaking,
 *              eating, drinking)
 *   12 uint8   unknown_s
 *   13 uint8   battery_pct
 *   14 uint8   flags
 * This is the only place in the backend that decodes the collar's bytes.
 */

export const RECORD_SIZE = 15;
export const CLASS_COLUMNS = [
  "still_s",
  "walking_s",
  "running_s",
  "scratching_s",
  "shaking_s",
  "eating_s",
  "drinking_s",
] as const;

export interface MinuteRecord {
  minuteTs: number; // epoch seconds, multiple of 60
  seconds: number[]; // 7 values, contract 4.1 IDs 0..6
  unknownS: number;
  batteryPct: number;
  flags: number;
}

export interface Rejected {
  index: number;
  reason: string;
}

const EARLIEST = Date.UTC(2024, 0, 1) / 1000;
const FUTURE_SLACK_S = 300;

export function decodeRecords(
  buf: Buffer,
  nowS: number = Date.now() / 1000,
): { records: MinuteRecord[]; rejected: Rejected[] } {
  if (buf.length % RECORD_SIZE !== 0) {
    throw new Error(`payload is ${buf.length} bytes, not a multiple of ${RECORD_SIZE}`);
  }
  const records: MinuteRecord[] = [];
  const rejected: Rejected[] = [];
  for (let i = 0; i < buf.length / RECORD_SIZE; i++) {
    const o = i * RECORD_SIZE;
    const version = buf.readUInt8(o);
    if (version !== 1) {
      rejected.push({ index: i, reason: `unsupported version ${version}` });
      continue;
    }
    const minuteTs = buf.readUInt32LE(o + 1);
    const seconds = Array.from({ length: 7 }, (_, c) => buf.readUInt8(o + 5 + c));
    const unknownS = buf.readUInt8(o + 12);
    const batteryPct = buf.readUInt8(o + 13);
    const flags = buf.readUInt8(o + 14);
    const total = seconds.reduce((a, b) => a + b, 0) + unknownS;

    if (minuteTs % 60 !== 0) rejected.push({ index: i, reason: "minute_ts not on a minute" });
    else if (minuteTs < EARLIEST) rejected.push({ index: i, reason: "minute_ts too old" });
    else if (minuteTs > nowS + FUTURE_SLACK_S)
      rejected.push({ index: i, reason: "minute_ts in the future" });
    else if (total > 60) rejected.push({ index: i, reason: `seconds add up to ${total} > 60` });
    else if (batteryPct > 100) rejected.push({ index: i, reason: "battery_pct > 100" });
    else records.push({ minuteTs, seconds, unknownS, batteryPct, flags });
  }
  return { records, rejected };
}

/** Inverse of decodeRecords (used by tests, simulators and the app/base station mocks). */
export function encodeRecords(records: MinuteRecord[]): Buffer {
  const buf = Buffer.alloc(records.length * RECORD_SIZE);
  records.forEach((r, i) => {
    const o = i * RECORD_SIZE;
    buf.writeUInt8(1, o);
    buf.writeUInt32LE(r.minuteTs, o + 1);
    r.seconds.forEach((s, c) => buf.writeUInt8(s, o + 5 + c));
    buf.writeUInt8(r.unknownS, o + 12);
    buf.writeUInt8(r.batteryPct, o + 13);
    buf.writeUInt8(r.flags, o + 14);
  });
  return buf;
}
