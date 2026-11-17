import 'package:material_ui/material_ui.dart';

import '../core/contracts.dart';

/// 24 h timeline: 96 slots of 15 min, colored by behavior (same colors as the labeler).
class TimelineBar extends StatelessWidget {
  const TimelineBar({super.key, required this.slots});
  final List<Behavior?> slots;

  @override
  Widget build(BuildContext context) {
    final empty = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 40,
            child: Row(
              children: [
                for (final s in slots)
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.only(right: 1),
                      color: s?.color ?? empty,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final t in ['0h', '6h', '12h', '18h', '24h'])
              Text(t, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            for (final b in [
              Behavior.still,
              Behavior.walking,
              Behavior.running,
              Behavior.scratching,
            ])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: b.color,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(b.label, style: Theme.of(context).textTheme.labelMedium),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// One indicator (Exercise, Sleep, Skin): what it is, the number, and a one-line verdict.
class IndicatorCard extends StatelessWidget {
  const IndicatorCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
    this.warn = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final String detail;
  final bool warn;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final accent = warn ? const Color(0xFFB45309) : t.colorScheme.primary;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: accent.withValues(alpha: 0.12),
                child: Icon(icon, color: accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: t.textTheme.labelLarge),
                    Text(
                      value,
                      style: t.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      detail,
                      style: t.textTheme.bodySmall?.copyWith(color: accent),
                    ),
                  ],
                ),
              ),
              if (onTap != null) const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

/// Simple vertical bars for trends (no chart dependency).
class DayBars extends StatelessWidget {
  const DayBars({
    super.key,
    required this.values,
    required this.labels,
    this.highlight,
  });
  final List<double> values;
  final List<String> labels;
  final bool Function(int i)? highlight;

  @override
  Widget build(BuildContext context) {
    final maxV = values.fold<double>(1, (m, v) => v > m ? v : m);
    final t = Theme.of(context);
    return SizedBox(
      height: 130,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < values.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: 100 * values[i] / maxV,
                      decoration: BoxDecoration(
                        color: (highlight?.call(i) ?? false)
                            ? const Color(0xFFF58518)
                            : t.colorScheme.primary,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(3),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(labels[i], style: t.textTheme.labelSmall, maxLines: 1),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
