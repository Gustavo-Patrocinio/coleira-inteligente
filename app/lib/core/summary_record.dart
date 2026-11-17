/// Per-minute summary record, contract 4.7 / ADR 0001 (little-endian, 15 bytes).
/// The app only forwards these to the backend (which decodes them), but it reads them too
/// to show the day offline. Mirrors backend/src/summary.ts.
library;

import 'dart:typed_data';

const int summaryRecordSize = 15;

class MinuteSummary {
  const MinuteSummary({
    required this.minuteTs,
    required this.seconds,
    required this.unknownS,
    required this.batteryPct,
    required this.flags,
  });

  final int minuteTs; // epoch seconds, multiple of 60
  final List<int> seconds; // 7 values, class IDs 0..6
  final int unknownS;
  final int batteryPct;
  final int flags;
}

List<MinuteSummary> decodeSummaries(Uint8List buf) {
  if (buf.length % summaryRecordSize != 0) {
    throw FormatException(
      '${buf.length} bytes is not a multiple of $summaryRecordSize',
    );
  }
  final b = ByteData.sublistView(buf);
  return [
    for (var o = 0; o < buf.length; o += summaryRecordSize)
      if (b.getUint8(o) == 1)
        MinuteSummary(
          minuteTs: b.getUint32(o + 1, Endian.little),
          seconds: [for (var c = 0; c < 7; c++) b.getUint8(o + 5 + c)],
          unknownS: b.getUint8(o + 12),
          batteryPct: b.getUint8(o + 13),
          flags: b.getUint8(o + 14),
        ),
  ];
}

Uint8List encodeSummaries(List<MinuteSummary> records) {
  final b = ByteData(records.length * summaryRecordSize);
  for (var i = 0; i < records.length; i++) {
    final o = i * summaryRecordSize;
    final r = records[i];
    b
      ..setUint8(o, 1)
      ..setUint32(o + 1, r.minuteTs, Endian.little)
      ..setUint8(o + 12, r.unknownS)
      ..setUint8(o + 13, r.batteryPct)
      ..setUint8(o + 14, r.flags);
    for (var c = 0; c < 7; c++) {
      b.setUint8(o + 5 + c, r.seconds[c]);
    }
  }
  return b.buffer.asUint8List();
}
