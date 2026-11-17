/// Turns the backend's day view into what the Today screen shows (pure, unit-tested).
library;

import '../core/contracts.dart';
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

String formatDuration(int seconds) {
  final m = (seconds / 60).round();
  if (m < 60) return '$m min';
  return '${m ~/ 60}h${(m % 60).toString().padLeft(2, '0')}';
}
