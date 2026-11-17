/// Summary sync protocol, contract 4.8 / ADR 0013. Mirrors ml/src/coleira_ml/sync_protocol.py
/// and firmware/app/src/ble_sync.c.
library;

import 'dart:typed_data';

import 'summary_record.dart';

const String syncServiceUuid = 'c01a0100-7e3b-4c5e-9d2a-5f1e8b6a2c10';
const String syncTimeUuid = 'c01a0101-7e3b-4c5e-9d2a-5f1e8b6a2c10';
const String syncControlUuid = 'c01a0102-7e3b-4c5e-9d2a-5f1e8b6a2c10';
const String syncDataUuid = 'c01a0103-7e3b-4c5e-9d2a-5f1e8b6a2c10';
const String syncStatusUuid = 'c01a0104-7e3b-4c5e-9d2a-5f1e8b6a2c10';
const String collarName = 'Collar';

const int statusKindInfo = 0x80;
const int statusKindSyncDone = 0x81;

Uint8List timePayload(int epochS) =>
    (ByteData(4)..setUint32(0, epochS, Endian.little)).buffer.asUint8List();

Uint8List sendSincePayload(int sinceMinuteTs) =>
    (ByteData(5)
          ..setUint8(0, 0x01)
          ..setUint32(1, sinceMinuteTs, Endian.little))
        .buffer
        .asUint8List();

final Uint8List statusRequest = Uint8List.fromList([0x02]);

class SyncStatus {
  const SyncStatus(
    this.kind,
    this.clockSet,
    this.batteryPct,
    this.count,
    this.oldest,
    this.newest,
  );
  final int kind;
  final bool clockSet;
  final int batteryPct;
  final int count;
  final int oldest;
  final int newest;
}

SyncStatus parseStatus(List<int> bytes) {
  if (bytes.length != 16) {
    throw FormatException('status must be 16 bytes, got ${bytes.length}');
  }
  final b = ByteData.sublistView(Uint8List.fromList(bytes));
  return SyncStatus(
    b.getUint8(0),
    b.getUint8(1) != 0,
    b.getUint8(2),
    b.getUint32(4, Endian.little),
    b.getUint32(8, Endian.little),
    b.getUint32(12, Endian.little),
  );
}

/// One Data notification → its raw 15-byte records (uploaded to the backend as they are).
List<Uint8List> splitRecords(List<int> bytes) {
  if (bytes.length % summaryRecordSize != 0) {
    throw FormatException('${bytes.length} bytes is not whole records');
  }
  final u = Uint8List.fromList(bytes);
  return [
    for (var o = 0; o < u.length; o += summaryRecordSize)
      Uint8List.sublistView(u, o, o + summaryRecordSize),
  ];
}
