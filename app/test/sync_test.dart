import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collar_app/api/api_client.dart';
import 'package:collar_app/collar/sync_service.dart';
import 'package:collar_app/core/summary_record.dart';
import 'package:collar_app/core/sync_protocol.dart';
import 'package:collar_app/ui/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const t0 = 1800000000;

Uint8List records(int n, {int from = t0}) => encodeSummaries([
  for (var i = 0; i < n; i++)
    MinuteSummary(
      minuteTs: from + 60 * i,
      seconds: const [60, 0, 0, 0, 0, 0, 0],
      unknownS: 0,
      batteryPct: 0,
      flags: 1,
    ),
]);

Uint8List status(int kind, int count) =>
    (ByteData(16)
          ..setUint8(0, kind)
          ..setUint8(1, 1)
          ..setUint32(4, count, Endian.little)
          ..setUint32(8, t0, Endian.little)
          ..setUint32(12, t0 + 60 * (count - 1), Endian.little))
        .buffer
        .asUint8List();

/// A collar that answers "send since X" with the records ≥ X, 16 per notification.
class FakeCollar implements SyncTransport {
  FakeCollar(this.stored);
  final Uint8List stored;
  final writes = <String, Uint8List>{};
  final _data = StreamController<List<int>>.broadcast();
  final _status = StreamController<List<int>>.broadcast();
  bool connected = false;

  @override
  Future<void> connect(String collarId) async => connected = true;
  @override
  Future<void> disconnect(String collarId) async => connected = false;
  @override
  Future<void> subscribe(String collarId, String characteristic) async {}
  @override
  Stream<List<int>> notifications(String collarId, String c) =>
      c == syncDataUuid ? _data.stream : _status.stream;

  @override
  Future<void> write(
    String collarId,
    String characteristic,
    Uint8List value,
  ) async {
    writes[characteristic] = value;
    if (characteristic != syncControlUuid) return;
    final since = ByteData.sublistView(value).getUint32(1, Endian.little);
    final all = splitRecords(stored)
        .where(
          (r) => ByteData.sublistView(r).getUint32(1, Endian.little) >= since,
        )
        .toList();
    scheduleMicrotask(() {
      for (var i = 0; i < all.length; i += 16) {
        _data.add([for (final r in all.skip(i).take(16)) ...r]);
      }
      _status.add(status(statusKindSyncDone, all.length));
    });
  }
}

void main() {
  test('payloads and status match the Python vectors (contract 4.8)', () {
    expect(timePayload(0x01020304), [4, 3, 2, 1]);
    expect(sendSincePayload(0x01020304), [1, 4, 3, 2, 1]);
    final st = parseStatus(status(statusKindSyncDone, 42));
    expect(
      [st.kind, st.count, st.newest - st.oldest],
      [statusKindSyncDone, 42, 41 * 60],
    );
    expect(splitRecords(records(16)), hasLength(16));
    expect(
      () => splitRecords(records(2).sublist(0, 29)),
      throwsFormatException,
    );
  });

  test('syncs since the last upload, uploads raw records and remembers the next minute', () async {
    final collar = FakeCollar(records(40));
    final uploads = <Map<String, dynamic>>[];
    final api = CollarApi(
      baseUrl: Uri.parse('http://server'),
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        uploads.add({...body, 'auth': req.headers['authorization']});
        final n = base64Decode(body['records'] as String).length ~/ 15;
        return http.Response(
          jsonEncode({
            'received': n,
            'inserted': n,
            'duplicates': 0,
            'rejected': [],
          }),
          200,
        );
      }),
    );
    final store = MemorySessionStore();
    final sync = SyncService(
      transport: collar,
      api: api,
      store: store,
      nowS: () => t0 + 3000,
    );

    final first = await sync.syncAndUpload('AA:BB', 'dev_token');
    expect(first.records, 40);
    expect(first.newestMinute, t0 + 39 * 60);
    expect(
      ByteData.sublistView(collar.writes[syncTimeUuid]!)
          .getUint32(0, Endian.little),
      t0 + 3000,
    ); // clock set
    expect(uploads.single['auth'], 'Bearer dev_token');
    expect(uploads.single['via'], 'app');
    expect(collar.connected, isFalse); // always disconnects

    // second sync asks only for what is new
    final second = await sync.syncAndUpload('AA:BB', 'dev_token');
    expect(
      ByteData.sublistView(collar.writes[syncControlUuid]!)
          .getUint32(1, Endian.little),
      t0 + 40 * 60,
    );
    expect(second.records, 0);
    expect(uploads, hasLength(1)); // nothing to upload
  });
}
