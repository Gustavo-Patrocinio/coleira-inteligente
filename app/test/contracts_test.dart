// Contract tests: the same byte vectors as ml/tests/test_raw_packet.py and the backend, so
// firmware, Python, backend and app agree on every byte.
import 'dart:typed_data';

import 'package:collar_app/core/contracts.dart';
import 'package:collar_app/core/raw_packet.dart';
import 'package:collar_app/core/summary_record.dart';
import 'package:flutter_test/flutter_test.dart';

List<List<int>> samples() => [
  for (var i = 0; i < 10; i++) [for (var c = 0; c < 6; c++) (i * 6 + c) * -37],
];

void main() {
  group('raw packet (contract 4.4)', () {
    test(
      'is 128 bytes with a little-endian header (same vector as Python)',
      () {
        final buf = packRawPacket(0x1234, 0xA1B2C3D4, samples());
        expect(rawPacketSize, 128);
        expect(buf.sublist(0, 8), [1, 1, 0x34, 0x12, 0xD4, 0xC3, 0xB2, 0xA1]);
        expect(buf.sublist(8, 12), [
          0x00,
          0x00,
          0xDB,
          0xFF,
        ]); // ax = 0, ay = -37
      },
    );

    test('round-trips, including the uint16 maximum', () {
      final p = parseRawPacket(packRawPacket(65535, 123456, samples()));
      expect(p.seq, 65535);
      expect(p.deviceMs, 123456);
      expect(p.samples, samples());
    });

    test('rejects wrong size, version and type', () {
      final good = packRawPacket(1, 2, samples());
      expect(() => parseRawPacket(good.sublist(0, 127)), throwsFormatException);
      expect(
        () => parseRawPacket(Uint8List.fromList([2, ...good.sublist(1)])),
        throwsFormatException,
      );
      expect(
        () => parseRawPacket(Uint8List.fromList([1, 7, ...good.sublist(2)])),
        throwsFormatException,
      );
    });

    test('CSV rows follow contract 4.5', () {
      final rows = csvRows(
        parseRawPacket(packRawPacket(7, 1000, samples())),
        5000,
      );
      expect(rows, hasLength(10));
      expect(rows.first.sublist(0, 3), [5000, 1000, 7]);
      expect(rows.last[1], 1000 + 9 * 20);
      expect(rows.first, hasLength(csvHeader.length));
    });

    test('loss counter handles the wrap-around and gaps', () {
      final c = LossCounter();
      for (final s in [65533, 65534, 65535, 0, 2, 3]) {
        c.add(s);
      }
      expect(c.expected, 7);
      expect(c.received, 6);
      expect(c.loss, closeTo(1 / 7, 1e-9));
    });
  });

  group('per-minute summary (contract 4.7)', () {
    test('15 bytes, version first, little-endian timestamp', () {
      const r = MinuteSummary(
        minuteTs: 1794868800,
        seconds: [50, 10, 0, 0, 0, 0, 0],
        unknownS: 0,
        batteryPct: 80,
        flags: 0,
      );
      final buf = encodeSummaries([r]);
      expect(buf, hasLength(15));
      expect(buf[0], 1);
      expect(ByteData.sublistView(buf).getUint32(1, Endian.little), 1794868800);
      final back = decodeSummaries(buf).single;
      expect(back.seconds, r.seconds);
      expect(back.batteryPct, 80);
    });
  });

  test('class IDs are stable (contract 4.1)', () {
    expect(
      {for (final b in Behavior.values) b.label: b.id},
      {
        'still': 0,
        'walking': 1,
        'running': 2,
        'scratching': 3,
        'shaking': 4,
        'eating': 5,
        'drinking': 6,
        'unknown': 255, //
      },
    );
  });
}
