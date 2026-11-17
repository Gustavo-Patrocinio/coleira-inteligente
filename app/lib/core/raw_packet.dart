/// Raw BLE data packet, contract 4.4 (little-endian, 128 bytes):
///   0 uint8 version (=1) · 1 uint8 type (0x01) · 2 uint16 seq · 4 uint32 device_ms ·
///   8 int16 × 6 × 10 samples (ax, ay, az, gx, gy, gz)
/// Mirrors ml/src/coleira_ml/raw_packet.py and firmware/logger/src/packet.c; the tests use
/// the same known byte vectors as the Python tests.
library;

import 'dart:typed_data';

const int rawPacketVersion = 1;
const int rawPacketTypeRaw = 0x01;
const int samplesPerPacket = 10;
const int rawChannels = 6;
const int rawHeaderSize = 8;
const int rawPacketSize =
    rawHeaderSize + samplesPerPacket * rawChannels * 2; // 128
const int samplePeriodMs =
    20; // nominal; the real rate is estimated downstream (ADR 0003)

/// Contract 4.5 header.
const List<String> csvHeader = [
  'phone_ts_ms', 'device_ms', 'seq', 'ax', 'ay', 'az', 'gx', 'gy', 'gz', //
];

class RawPacket {
  const RawPacket({
    required this.seq,
    required this.deviceMs,
    required this.samples,
  });
  final int seq;
  final int deviceMs;
  final List<List<int>> samples; // 10 × 6
}

RawPacket parseRawPacket(List<int> bytes) {
  if (bytes.length != rawPacketSize) {
    throw FormatException('expected $rawPacketSize bytes, got ${bytes.length}');
  }
  final b = ByteData.sublistView(Uint8List.fromList(bytes));
  final version = b.getUint8(0);
  if (version != rawPacketVersion) {
    throw FormatException('unsupported packet version $version');
  }
  final type = b.getUint8(1);
  if (type != rawPacketTypeRaw) {
    throw FormatException('unexpected packet type $type');
  }
  final samples = List.generate(
    samplesPerPacket,
    (i) => List.generate(
      rawChannels,
      (c) =>
          b.getInt16(rawHeaderSize + (i * rawChannels + c) * 2, Endian.little),
    ),
  );
  return RawPacket(
    seq: b.getUint16(2, Endian.little),
    deviceMs: b.getUint32(4, Endian.little),
    samples: samples,
  );
}

Uint8List packRawPacket(int seq, int deviceMs, List<List<int>> samples) {
  final b = ByteData(rawPacketSize)
    ..setUint8(0, rawPacketVersion)
    ..setUint8(1, rawPacketTypeRaw)
    ..setUint16(2, seq & 0xFFFF, Endian.little)
    ..setUint32(4, deviceMs & 0xFFFFFFFF, Endian.little);
  for (var i = 0; i < samplesPerPacket; i++) {
    for (var c = 0; c < rawChannels; c++) {
      b.setInt16(
        rawHeaderSize + (i * rawChannels + c) * 2,
        samples[i][c],
        Endian.little,
      );
    }
  }
  return b.buffer.asUint8List();
}

/// Contract 4.5 rows: one per sample, device_ms = packet device_ms + i × 20 ms.
List<List<int>> csvRows(RawPacket p, int phoneTsMs) => [
  for (var i = 0; i < p.samples.length; i++)
    [phoneTsMs, p.deviceMs + i * samplePeriodMs, p.seq, ...p.samples[i]],
];

/// Received vs expected packets from `seq`, handling the uint16 wrap-around.
class LossCounter {
  int? _first;
  int _lastUnwrapped = 0;
  int received = 0;

  void add(int seq) {
    if (_first == null) {
      _first = seq;
      _lastUnwrapped = seq;
    } else {
      final prev = _lastUnwrapped;
      var cand = (prev & ~0xFFFF) | seq;
      if (cand < prev - 0x8000) cand += 0x10000;
      _lastUnwrapped = cand;
    }
    received++;
  }

  int get expected => _first == null ? 0 : _lastUnwrapped - _first! + 1;
  double get loss => expected == 0 ? 0 : 1 - received / expected;
}
