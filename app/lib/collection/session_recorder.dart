/// Records one collection session (Phase 1): raw packets → imu.csv (contract 4.5) and
/// meta.json, plus the video start time on the phone clock (ADR 0003). Pure Dart + dart:io,
/// unit-tested with a fake clock.
library;

import 'dart:convert';
import 'dart:io';

import '../core/contracts.dart';
import '../core/raw_packet.dart';

typedef Clock = int Function();

int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

/// `YYYYMMDD-HHMM-<dog>`, the same format as ml/scripts/record_ble.py.
String sessionIdFor(DateTime t, String dogId) {
  String two(int v) => v.toString().padLeft(2, '0');
  final safeDog = dogId.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9_-]'),
    '-',
  );
  return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}-$safeDog';
}

class SessionRecorder {
  SessionRecorder({
    required this.dir,
    required this.dogId,
    required this.deviceId,
    Clock? now,
  }) : _now = now ?? _systemNowMs;

  final Directory dir;
  final String dogId;
  final String deviceId;
  final Clock _now;

  final LossCounter loss = LossCounter();
  int badPackets = 0;
  int? startPhoneTs;
  int? videoStartPhoneTs;
  IOSink? _csv;

  String get sessionId => dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  File get csvFile => File('${dir.path}${Platform.pathSeparator}imu.csv');
  File get metaFile => File('${dir.path}${Platform.pathSeparator}meta.json');

  Future<void> start() async {
    await dir.create(recursive: true);
    startPhoneTs = _now();
    _csv = csvFile.openWrite()..writeln(csvHeader.join(','));
  }

  /// Call for every BLE notification, as soon as it arrives (the receive time matters).
  void addPacket(List<int> bytes) {
    final sink = _csv;
    if (sink == null) throw StateError('recorder not started');
    final ts = _now();
    final RawPacket p;
    try {
      p = parseRawPacket(bytes);
    } on FormatException {
      badPackets++;
      return;
    }
    loss.add(p.seq);
    for (final row in csvRows(p, ts)) {
      sink.writeln(row.join(','));
    }
  }

  /// Call right when the camera starts recording.
  void markVideoStart() => videoStartPhoneTs = _now();

  Future<void> stop({
    String? videoFile,
    String location = '',
    String surface = '',
    String notes = '',
  }) async {
    final sink = _csv;
    if (sink == null) return;
    await sink.flush();
    await sink.close();
    _csv = null;
    final meta = {
      'session_id': sessionId,
      'dog_id': dogId,
      'device_id': deviceId,
      'start_phone_ts': startPhoneTs,
      'video_file': videoFile ?? '',
      'video_start_phone_ts_ms': videoStartPhoneTs,
      'accel_range': accelRangeG,
      'gyro_range': gyroRangeDps,
      'odr_hz': odrHz,
      'location': location,
      'surface': surface,
      'notes': [
        if (notes.isNotEmpty) notes,
        'recorded with the app',
        'packet loss ${(loss.loss * 100).toStringAsFixed(2)}%',
        if (badPackets > 0) '$badPackets bad packets',
      ].join('; '),
      'sync_taps': <String, int>{},
    };
    await metaFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(meta)}\n',
    );
  }
}
