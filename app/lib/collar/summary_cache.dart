/// Per-minute records synced to this phone, kept locally so the Today screen works without
/// internet and nothing is lost when the upload fails (it is retried on the next sync).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../core/summary_record.dart';

abstract class SummaryCache {
  /// Adds raw 15-byte records of one dog (duplicates are fine: reads keep one per minute).
  Future<void> add(Uint8List records, {int dog = 0});

  /// The dog's records with `fromTs <= minute_ts < toTs`, one per minute, oldest first.
  Future<List<MinuteSummary>> range(int fromTs, int toTs, {int dog = 0});

  /// Removes every record (sign out, account deletion: privacy policy).
  Future<void> clear();
}

List<MinuteSummary> _dedupe(Iterable<MinuteSummary> all, int fromTs, int toTs) {
  final byMinute = <int, MinuteSummary>{};
  for (final r in all) {
    if (r.minuteTs >= fromTs && r.minuteTs < toTs) byMinute[r.minuteTs] = r;
  }
  return byMinute.values.toList()
    ..sort((a, b) => a.minuteTs.compareTo(b.minuteTs));
}

class MemorySummaryCache implements SummaryCache {
  final Map<int, List<MinuteSummary>> records = {};
  @override
  Future<void> add(Uint8List r, {int dog = 0}) async =>
      records.putIfAbsent(dog, () => []).addAll(decodeSummaries(r));
  @override
  Future<List<MinuteSummary>> range(
    int fromTs,
    int toTs, {
    int dog = 0,
  }) async => _dedupe(records[dog] ?? const [], fromTs, toTs);
  @override
  Future<void> clear() async => records.clear();
}

/// One append-only file per dog; trimmed to the last [keepDays] when it grows (~21 KB per day).
class FileSummaryCache implements SummaryCache {
  FileSummaryCache({this.keepDays = 14, Future<Directory> Function()? dir})
    : _dir = dir ?? getApplicationSupportDirectory;

  final int keepDays;
  final Future<Directory> Function() _dir;

  Future<File> _file(int dog) async =>
      File('${(await _dir()).path}${Platform.pathSeparator}summaries_$dog.bin');

  @override
  Future<void> add(Uint8List records, {int dog = 0}) async {
    final f = await _file(dog);
    await f.writeAsBytes(records, mode: FileMode.append, flush: true);
    if (await f.length() > (keepDays + 2) * 1440 * summaryRecordSize) {
      final newest = decodeSummaries(await f.readAsBytes())
          .fold<int>(0, (a, r) => r.minuteTs > a ? r.minuteTs : a);
      final keep = _dedupe(
        decodeSummaries(await f.readAsBytes()),
        newest - keepDays * 86400,
        newest + 60,
      );
      await f.writeAsBytes(encodeSummaries(keep), flush: true);
    }
  }

  @override
  Future<List<MinuteSummary>> range(int fromTs, int toTs, {int dog = 0}) async {
    final f = await _file(dog);
    if (!await f.exists()) return [];
    final bytes = await f.readAsBytes();
    // a crash mid-append can leave a partial record at the end: ignore it
    final whole = bytes.length - bytes.length % summaryRecordSize;
    return _dedupe(
      decodeSummaries(Uint8List.sublistView(bytes, 0, whole)),
      fromTs,
      toTs,
    );
  }

  @override
  Future<void> clear() async {
    final dir = await _dir();
    if (!await dir.exists()) return;
    await for (final f in dir.list()) {
      final name = f.uri.pathSegments.last;
      // summaries.bin: the single file of app versions before several dogs
      if (f is File && name.startsWith('summaries') && name.endsWith('.bin')) {
        await f.delete();
      }
    }
  }
}
