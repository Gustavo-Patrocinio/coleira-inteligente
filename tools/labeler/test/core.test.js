// Run: node --test tools/labeler/test/core.test.js
const test = require("node:test");
const assert = require("node:assert/strict");
const C = require("../core.js");

const near = (a, b, tol = 1e-6) => assert.ok(Math.abs(a - b) <= tol, `${a} != ${b}`);

/** Synthetic CSV: n packets of 10 samples, IMU at `odrHz`, some packets lost. */
function fakeCsv({ packets = 100, odrHz = 50, drop = [], seq0 = 0 } = {}) {
  const rows = ["phone_ts_ms,device_ms,seq,ax,ay,az,gx,gy,gz"];
  const period = 1000 / odrHz;
  for (let p = 0; p < packets; p++) {
    if (drop.includes(p)) continue;
    const seq = (seq0 + p) % 65536;
    for (let i = 0; i < 10; i++) {
      const k = p * 10 + i;
      const dev = 1000 + k * period; // the MCU clock sees the real rate
      rows.push([5000 + dev, Math.round(dev), seq, 0, 0, 2048, 0, 0, 0].join(","));
    }
  }
  return rows.join("\n");
}

test("parseImuCsv reads columns and rejects incomplete CSVs", () => {
  const cols = C.parseImuCsv(fakeCsv({ packets: 2 }));
  assert.equal(cols.seq.length, 20);
  assert.equal(cols.az[0], 2048);
  assert.throws(() => C.parseImuCsv("a,b\n1,2"), /missing CSV column/);
});

test("unwrapSeq crosses the uint16 wrap-around", () => {
  assert.deepEqual([...C.unwrapSeq([65534, 65535, 0, 1])], [65534, 65535, 65536, 65537]);
});

test("sampleIndex counts the samples of lost packets", () => {
  const cols = C.parseImuCsv(fakeCsv({ packets: 5, drop: [2] }));
  const k = C.sampleIndex(cols.seq);
  assert.equal(k[19], 19); // packet 1, last sample
  assert.equal(k[20], 30); // skips all of packet 2
});

test("buildTimeline estimates the real IMU rate and packet loss", () => {
  const cols = C.parseImuCsv(fakeCsv({ packets: 300, odrHz: 50.5, drop: [10, 11, 200], seq0: 65500 }));
  const tl = C.buildTimeline(cols);
  near(tl.odrHz, 50.5, 0.01);
  assert.equal(tl.packetsExpected, 300);
  assert.equal(tl.packetsReceived, 297);
  near(tl.packetLoss, 0.01, 1e-9);
});

test("toPhysical uses the ranges from meta.json", () => {
  const cols = { ax: [16384], ay: [0], az: [0], gx: [-32768], gy: [0], gz: [0] };
  const p = C.toPhysical(cols, 16, 2000);
  near(p.ax[0], 8);
  near(p.gx[0], -2000);
  near(p.amag[0], 8);
});

test("syncFromTaps: offset and drift correction", () => {
  assert.equal(C.syncFromTaps({}).mode, "none");
  const off = C.syncFromTaps({ start_video_ms: 3200, start_device_ms: 5800 });
  assert.equal(off.mode, "offset");
  near(C.deviceToVideo(off, 5800), 3200);

  // video clock runs 1% faster than the device clock
  const taps = { start_video_ms: 3000, start_device_ms: 10000, end_video_ms: 3000 + 606000, end_device_ms: 610000 };
  const s = C.syncFromTaps(taps);
  assert.equal(s.mode, "drift");
  near(s.b, 1.01);
  near(C.deviceToVideo(s, 310000), 3000 + 303000);
  near(C.videoToDevice(s, C.deviceToVideo(s, 123456)), 123456);
});

test("snapToPeak snaps to the nearest peak within the window", () => {
  const t = [0, 100, 200, 300, 400, 900];
  const a = [1, 1, 5, 1, 1, 9];
  assert.equal(C.snapToPeak(t, a, 250, 300), 200); // 900 is outside the window
});

test("insertSegment cuts overlaps and keeps order", () => {
  let segs = [];
  segs = C.insertSegment(segs, { start_ms: 0, end_ms: 10000, class_id: 0 });
  segs = C.insertSegment(segs, { start_ms: 4000, end_ms: 6000, class_id: 4 });
  assert.deepEqual(segs.map((s) => [s.start_ms, s.end_ms, s.class_id]), [
    [0, 4000, 0], [4000, 6000, 4], [6000, 10000, 0],
  ]);
  assert.equal(C.segmentAt(segs, 5000), 1);
  assert.equal(C.insertSegment(segs, { start_ms: 5, end_ms: 5, class_id: 1 }).length, 3);
});

test("totalsByClass sums durations", () => {
  const tot = C.totalsByClass([
    { start_ms: 0, end_ms: 1000, class_id: 1 },
    { start_ms: 2000, end_ms: 2500, class_id: 1 },
  ]);
  assert.equal(tot[1], 1500);
});

test("labelsToCsv follows contract 4.6 and round-trips", () => {
  const segs = [
    { start_ms: 2000.4, end_ms: 3000.6, class_id: 4, confidence: 0.5 },
    { start_ms: 0, end_ms: 2000.4, class_id: 0 },
  ];
  const csv = C.labelsToCsv(segs, "ann,otator");
  assert.equal(csv, "start_ms,end_ms,class_id,annotator,confidence\n0,2000,0,ann otator,1.00\n2000,3001,4,ann otator,0.50\n");
  const back = C.parseLabelsCsv(csv);
  assert.equal(back[1].class_id, 4);
  assert.equal(back[1].confidence, 0.5);
});

test("class names follow ADR 0008", () => {
  assert.equal(C.CLASS_BY_ID[0].name, "still");
  assert.equal(C.CLASS_BY_ID[4].name, "shaking");
  assert.equal(C.CLASS_BY_KEY.x.id, 255);
});

test("fmtTime", () => {
  assert.equal(C.fmtTime(83456), "1:23.46");
  assert.equal(C.fmtTime(-1500), "-0:01.50");
});
