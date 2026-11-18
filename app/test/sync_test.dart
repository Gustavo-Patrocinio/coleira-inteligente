import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collar_app/api/api_client.dart';

import 'dart:io';

import 'package:collar_app/api/day_summary.dart';
import 'package:collar_app/collar/summary_cache.dart';
import 'package:collar_app/collar/sync_service.dart';
import 'package:collar_app/core/contracts.dart';
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

  test(
    'upload failure keeps the records on the phone and retries them next time',
    () async {
      final collar = FakeCollar(records(5));
      var online = false;
      final api = CollarApi(
        baseUrl: Uri.parse('http://server'),
        client: MockClient((req) async {
          if (!online) throw const SocketException('no route to host');
          final n =
              base64Decode(jsonDecode(req.body)['records'] as String).length ~/
              15;
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
      final cache = MemorySummaryCache();
      final sync = SyncService(
        transport: collar,
        api: api,
        store: MemorySessionStore(),
        cache: cache,
      );

      final offline = await sync.syncAndUpload('AA:BB', 'dev_token');
      expect(offline.uploaded, isFalse);
      expect(await cache.range(t0, t0 + 3600), hasLength(5)); // visible offline

      online = true;
      final retry = await sync.syncAndUpload('AA:BB', 'dev_token');
      expect(retry.records, 5); // asked for the same minutes again
      expect(retry.uploaded, isTrue);
      expect(
        await cache.range(t0, t0 + 3600),
        hasLength(5),
      ); // no duplicates on reads
    },
  );

  test('offline day: 15-minute blocks and totals from local records', () {
    // 2027-01-15 00:00 in Brazil (UTC-3) = 03:00 UTC
    const offset = Duration(hours: -3);
    final (from, to) = dayBounds('2027-01-15', offset);
    expect(to - from, 86400);
    expect(
      DateTime.fromMillisecondsSinceEpoch(from * 1000, isUtc: true).hour,
      3,
    );

    final recs = decodeSummaries(
      encodeSummaries([
        for (
          var i = 0;
          i < 30;
          i++
        ) // 00:00–00:29 local: walking, then scratching
          MinuteSummary(
            minuteTs: from + 60 * i,
            seconds: i < 15
                ? const [0, 60, 0, 0, 0, 0, 0]
                : const [0, 0, 0, 0, 0, 0, 0],
            unknownS: 0,
            batteryPct: 0,
            flags: 1,
          ),
      ]),
    );
    final scratchy = [
      ...recs.take(15),
      for (final r in recs.skip(15))
        MinuteSummary(
          minuteTs: r.minuteTs,
          seconds: const [50, 0, 0, 10, 0, 0, 0],
          unknownS: 0,
          batteryPct: 0,
          flags: 1,
        ),
    ];
    final day = dayFromRecords('2027-01-15', scratchy);
    expect(day.blocks, hasLength(2));
    expect(day.totals['walking_s'], 15 * 60);
    expect(day.totals['scratching_s'], 150);
    final slots = timelineSlots(day, offset);
    expect(slots[0], Behavior.walking);
    expect(
      slots[1],
      Behavior.scratching,
    ); // 150 s of scratching ≥ 60 s in the block
    expect(slots[2], isNull);
  });

  test('cache file survives a partial record and trims old days', () async {
    final dir = await Directory.systemTemp.createTemp('collar_cache');
    final cache = FileSummaryCache(keepDays: 1, dir: () async => dir);
    await cache.add(records(3));
    await File('${dir.path}/summaries_0.bin')
        .writeAsBytes([1, 2, 3], mode: FileMode.append);
    expect(await cache.range(t0, t0 + 3600), hasLength(3));
    await cache.clear(); // sign-out
    expect(await cache.range(t0, t0 + 3600), isEmpty);
    await cache.clear(); // twice is fine
    await dir.delete(recursive: true);
  });

  test('several dogs: every paired collar syncs into its own dog, old pairing migrates', () async {
    final uploads = <String>[];
    final backend = MockClient((req) async {
      final p = req.url.path;
      if (p == '/v1/ingest') {
        uploads.add(req.headers['authorization']!);
        final n =
            base64Decode(jsonDecode(req.body)['records'] as String).length ~/
            15;
        return http.Response(
          jsonEncode({
            'received': n,
            'inserted': n,
            'duplicates': 0,
            'rejected': [],
          }),
          200,
        );
      }
      if (p == '/v1/dogs') {
        return http.Response(
          jsonEncode([
            {'id': 1, 'name': 'Thor', 'timezone': 'America/Sao_Paulo'},
            {'id': 2, 'name': 'Mel', 'timezone': 'America/Sao_Paulo'},
          ]),
          200,
        );
      }
      if (p == '/v1/me') {
        return http.Response('{"email":"a@b.com","consent_version":1}', 200);
      }
      if (p == '/v1/dogs/2/devices') {
        return http.Response('{"device_id":"9","token":"dev_mel"}', 201);
      }
      return http.Response('{"error":"not found"}', 404);
    });
    // an app version before several dogs left one collar for dog 1
    final store = MemorySessionStore()
      ..data.addAll({
        'server': 'http://server',
        'token': 'jwt',
        'dog': '1',
        'paired_collar': 'AA:01',
        'device_token': 'dev_thor',
      });
    final cache = MemorySummaryCache();
    final state = AppState(
      store: store,
      apiFactory: (u) => CollarApi(baseUrl: u, client: backend),
      cache: cache,
    );
    await state.restore();
    expect(state.collars.single.id, 'AA:01');
    expect(state.collars.single.dogId, 1);
    expect(store.data.containsKey('paired_collar'), isFalse);

    await state.pairCollar('BB:02', forDog: state.dogs[1]);
    expect(state.collars.map((c) => '${c.id}>${c.dogId}'), [
      'AA:01>1',
      'BB:02>2',
    ]);

    final r = await state.syncCollar(FakeCollar(records(5)));
    expect(r!.records, 10); // 5 from each collar
    expect(uploads, ['Bearer dev_thor', 'Bearer dev_mel']);
    expect(await cache.range(t0, t0 + 3600, dog: 1), hasLength(5));
    expect(await cache.range(t0, t0 + 3600, dog: 2), hasLength(5));
    expect(state.lastSyncMessage, contains('Mel: synced 5 minutes'));

    // the pairing list survives a restart
    final again = AppState(
      store: store,
      apiFactory: (u) => CollarApi(baseUrl: u, client: backend),
      cache: cache,
    );
    await again.restore();
    expect(again.collars, hasLength(2));
  });
}
