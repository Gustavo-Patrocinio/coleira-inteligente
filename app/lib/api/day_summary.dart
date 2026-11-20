/// Turns the backend's day view into what the Today screen shows (pure, unit-tested).
library;

import '../core/contracts.dart';
import '../core/summary_record.dart';
import 'api_client.dart';

const _classColumns = {
  'still_s': Behavior.still,
  'walking_s': Behavior.walking,
  'running_s': Behavior.running,
  'scratching_s': Behavior.scratching,
  'shaking_s': Behavior.shaking,
  'eating_s': Behavior.eating,
  'drinking_s': Behavior.drinking,
};

/// Dominant behavior of a 15-minute block. Scratching and shaking are short events: a block
/// shows them when they add up to ≥ 60 s, otherwise the longest behavior wins.
Behavior dominantBehavior(DayBlock b) {
  final scratch = b.secondsByClass['scratching_s'] ?? 0;
  final shake = b.secondsByClass['shaking_s'] ?? 0;
  if (scratch >= 60 && scratch >= shake) return Behavior.scratching;
  if (shake >= 60) return Behavior.shaking;
  var best = Behavior.unknown;
  var bestS = 0;
  for (final e in _classColumns.entries) {
    final s = b.secondsByClass[e.key] ?? 0;
    if (s > bestS) {
      best = e.value;
      bestS = s;
    }
  }
  return best;
}

/// 96 slots (00:00–23:45 local) for the timeline; slots without data are `null`.
/// `localOffset` converts the block's UTC start to the dog's local time.
List<Behavior?> timelineSlots(DayView day, Duration localOffset) {
  final slots = List<Behavior?>.filled(96, null);
  for (final b in day.blocks) {
    final local = b.start.toUtc().add(localOffset);
    final idx = local.hour * 4 + local.minute ~/ 15;
    if (idx >= 0 && idx < 96) slots[idx] = dominantBehavior(b);
  }
  return slots;
}

/// One local hour of today: active minutes (walking + running) and how many minutes the
/// collar recorded (under 45 = partial: the hour in progress, or a gap in the data).
class HourActivity {
  const HourActivity(this.activeMin, this.recordedMin);
  final double activeMin;
  final int recordedMin;
  bool get partial => recordedMin < 45;
}

/// 24 entries (local hours 0–23); null = no data that hour.
List<HourActivity?> activityPerHour(DayView day, Duration localOffset) {
  final minutes = List<int>.filled(24, 0);
  final active = List<int>.filled(24, 0);
  for (final b in day.blocks) {
    final h = b.start.toUtc().add(localOffset).hour;
    minutes[h] += b.minutes;
    active[h] +=
        (b.secondsByClass['walking_s'] ?? 0) +
        (b.secondsByClass['running_s'] ?? 0);
  }
  return [
    for (var h = 0; h < 24; h++)
      minutes[h] == 0 ? null : HourActivity(active[h] / 60, minutes[h]),
  ];
}

String formatDuration(int seconds) {
  final m = (seconds / 60).round();
  if (m < 60) return '$m min';
  return '${m ~/ 60}h${(m % 60).toString().padLeft(2, '0')}';
}

const _columnsById = [
  'still_s',
  'walking_s',
  'running_s',
  'scratching_s',
  'shaking_s',
  'eating_s',
  'drinking_s',
];

/// The day view built on the phone from synced records, for when the server is unreachable.
/// Same shape as the backend's (15-minute blocks + totals); night wake-ups stay with the
/// server, which has the whole history.
DayView dayFromRecords(String day, List<MinuteSummary> records) {
  final blocks = <int, Map<String, int>>{};
  final minutes = <int, int>{};
  final totals = {
    for (final c in [..._columnsById, 'unknown_s']) c: 0,
  };
  for (final r in records) {
    final start = r.minuteTs - r.minuteTs % 900;
    final b = blocks.putIfAbsent(
      start,
      () => {for (final c in totals.keys) c: 0},
    );
    minutes[start] = (minutes[start] ?? 0) + 1;
    for (var i = 0; i < 7; i++) {
      b[_columnsById[i]] = b[_columnsById[i]]! + r.seconds[i];
      totals[_columnsById[i]] = totals[_columnsById[i]]! + r.seconds[i];
    }
    b['unknown_s'] = b['unknown_s']! + r.unknownS;
    totals['unknown_s'] = totals['unknown_s']! + r.unknownS;
  }
  final starts = blocks.keys.toList()..sort();
  return DayView(
    day: day,
    totals: totals,
    blocks: [
      for (final s in starts)
        DayBlock(
          start: DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true),
          minutes: minutes[s]!,
          secondsByClass: blocks[s]!,
        ),
    ],
  );
}

/// Epoch-second bounds [start, end) of a local calendar day ('YYYY-MM-DD').
(int, int) dayBounds(String day, Duration localOffset) {
  final midnightUtc = DateTime.parse('${day}T00:00:00Z').subtract(localOffset);
  final s = midnightUtc.millisecondsSinceEpoch ~/ 1000;
  return (s, s + 86400);
}

String formatAgo(DateTime t, {DateTime? now}) {
  final m = (now ?? DateTime.now()).difference(t).inMinutes;
  if (m < 1) return 'just now';
  if (m < 60) return '$m min ago';
  if (m < 48 * 60) return '${m ~/ 60} h ago';
  return '${m ~/ 1440} days ago';
}

String _clock(DateTime t, Duration localOffset) {
  final l = t.toUtc().add(localOffset);
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// Value and detail lines of the Today screen's sleep card. Uses the sleep estimate when the
/// server has one, else the night wake-ups of the day view (older servers, offline).
(String, String) sleepCardText(
  SleepView? sleep,
  int? nightWakeups,
  Duration localOffset, {
  String subject = 'they',
}) {
  final n = sleep?.night;
  if (n != null) {
    final naps = sleep!.napCount == 0
        ? ''
        : ' · ${sleep.napCount} nap${sleep.napCount == 1 ? '' : 's'} '
              '(${formatDuration(sleep.napMin * 60)})';
    return (
      'rested ${formatDuration(n.restMin * 60)}',
      '${_clock(n.bedtime, localOffset)}–${_clock(n.wakeTime, localOffset)} · '
          'woke up ${n.awakenings}×$naps · estimated from movement',
    );
  }
  if (sleep != null && sleep.nightCoverage < 0.5) {
    return ('—', 'not enough data from last night');
  }
  if (nightWakeups != null) {
    return ('woke up $nightWakeups×', 'times $subject got up 23:00–06:00');
  }
  return ('—', 'computed after the night is synced');
}
