/// Phone-side sync (the fallback path of ADR 0007): fetch new per-minute records from the
/// collar over BLE and upload them to the backend. Unit-tested with a fake transport.
library;

import 'dart:async';
import 'dart:typed_data';

import '../api/api_client.dart';
import '../core/summary_record.dart';
import '../core/sync_protocol.dart';
import '../ui/app_state.dart';
import 'summary_cache.dart';

/// The BLE operations a sync needs (implemented by UniversalBleSyncTransport).
abstract class SyncTransport {
  Future<void> connect(String collarId);
  Future<void> write(String collarId, String characteristic, Uint8List value);
  Stream<List<int>> notifications(String collarId, String characteristic);
  Future<void> subscribe(String collarId, String characteristic);
  Future<void> disconnect(String collarId);
}

class SyncResult {
  const SyncResult({
    required this.records,
    required this.inserted,
    required this.duplicates,
    required this.newestMinute,
    this.uploadError,
  });
  final int records;
  final int inserted;
  final int duplicates;
  final int? newestMinute;

  /// Set when the records were fetched (and kept on the phone) but could not be uploaded;
  /// the next sync asks the collar for them again.
  final Object? uploadError;
  bool get uploaded => uploadError == null;
}

class SyncService {
  SyncService({
    required this.transport,
    required this.api,
    required this.store,
    this.cache,
    int Function()? nowS,
  }) : _nowS = nowS ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  final SyncTransport transport;
  final CollarApi api;
  final SessionStore store;
  final SummaryCache? cache;
  final int Function() _nowS;

  static String _sinceKey(String collarId) => 'sync_since_$collarId';

  /// Connect → set the collar's clock → "send since X" → upload → remember the next X.
  Future<SyncResult> syncAndUpload(
    String collarId,
    String deviceToken, {
    int dogId = 0,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final since =
        int.tryParse(await store.read(_sinceKey(collarId)) ?? '') ?? 0;
    final records = <Uint8List>[];
    final done = Completer<SyncStatus>();
    SyncStatus? finished;

    // Data and Status arrive on different characteristics, so the "done" status can be
    // delivered before the last data notification. Finish only when both are in.
    void maybeFinish() {
      final st = finished;
      if (st != null && records.length >= st.count && !done.isCompleted) {
        done.complete(st);
      }
    }

    await transport.connect(collarId);
    try {
      await transport.write(collarId, syncTimeUuid, timePayload(_nowS()));
      final dataSub = transport.notifications(collarId, syncDataUuid).listen((
        b,
      ) {
        records.addAll(splitRecords(b));
        maybeFinish();
      });
      final statusSub = transport
          .notifications(collarId, syncStatusUuid)
          .listen((b) {
            final st = parseStatus(b);
            if (st.kind == statusKindSyncDone) {
              finished = st;
              maybeFinish();
            }
          });
      await transport.subscribe(collarId, syncDataUuid);
      await transport.subscribe(collarId, syncStatusUuid);
      await transport.write(collarId, syncControlUuid, sendSincePayload(since));
      await done.future.timeout(timeout);
      await dataSub.cancel();
      await statusSub.cancel();
    } finally {
      await transport.disconnect(collarId);
    }

    if (records.isEmpty) {
      return const SyncResult(
        records: 0,
        inserted: 0,
        duplicates: 0,
        newestMinute: null,
      );
    }
    final all = Uint8List.fromList([for (final r in records) ...r]);
    // the day shows on this phone even if the upload fails
    await cache?.add(all, dog: dogId);
    final IngestResult res;
    try {
      res = await api.ingest(deviceToken, all, via: 'app');
    } catch (e) {
      return SyncResult(
        records: records.length,
        inserted: 0,
        duplicates: 0,
        newestMinute: null,
        uploadError: e,
      );
    }
    final newest = decodeSummaries(all)
        .map((r) => r.minuteTs)
        .fold<int>(0, (a, b) => b > a ? b : a);
    await store.write(_sinceKey(collarId), '${newest + 60}');
    return SyncResult(
      records: records.length,
      inserted: res.inserted,
      duplicates: res.duplicates,
      newestMinute: newest,
    );
  }
}
