/// Data contracts shared with the firmware, the ML pipeline and the backend (CLAUDE.md §4).
library;

import 'dart:ui' show Color;

/// Contract 4.1 (names: ADR 0008). IDs are stable; never reuse or reorder them.
enum Behavior {
  still(0, 'still', Color(0xFF4C78A8)),
  walking(1, 'walking', Color(0xFF54A24B)),
  running(2, 'running', Color(0xFFF58518)),
  scratching(3, 'scratching', Color(0xFFE45756)),
  shaking(4, 'shaking', Color(0xFFB279A2)),
  eating(5, 'eating', Color(0xFF9D755D)),
  drinking(6, 'drinking', Color(0xFF72B7B2)),
  unknown(255, 'unknown', Color(0xFFE3E6E1));

  const Behavior(this.id, this.label, this.color);
  final int id;
  final String label;
  final Color color;

  static Behavior fromId(int id) => Behavior.values.firstWhere(
    (b) => b.id == id,
    orElse: () => Behavior.unknown,
  );
}

/// Contract 4.2 / ADR 0005.
const int accelRangeG = 16;
const int gyroRangeDps = 2000;
const int odrHz = 50;

/// GATT (ADR 0010).
const String rawServiceUuid = 'c01a0000-7e3b-4c5e-9d2a-5f1e8b6a2c10';
const String rawCharUuid = 'c01a0001-7e3b-4c5e-9d2a-5f1e8b6a2c10';
const String loggerName = 'Collar-Logger';
