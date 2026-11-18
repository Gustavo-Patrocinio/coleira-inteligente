import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import '../api/day_summary.dart';
import 'app_state.dart';
import 'widgets.dart';

class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key});
  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  int _days = 7;
  Future<List<DayMetric>>? _data;

  Future<List<DayMetric>> _fetch() {
    final s = AppScope.of(context);
    return s.api!.trends(s.dog!.id, days: _days);
  }

  void _load() => setState(() {
    _data = _fetch();
  });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= _fetch(); // first load: no setState needed during dependencies
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: DogTitle((d) => '${d.name}\'s trends')),
      body: FutureBuilder<List<DayMetric>>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Could not load: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final days = snap.data!;
          final labels = [
            for (final (i, d) in days.indexed)
              _days == 7 || i % 7 == 0 ? d.day.substring(8) : '',
          ];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 7, label: Text('7 days')),
                  ButtonSegment(value: 30, label: Text('30 days')),
                ],
                selected: {_days},
                onSelectionChanged: (s) {
                  _days = s.first;
                  _load();
                },
              ),
              const SizedBox(height: 16),
              if (days.isEmpty)
                const Text('Trends appear after the first full day of data.')
              else ...[
                _section(
                  context,
                  'Active time per day',
                  'average ${formatDuration(_avg(days.map((d) => d.activeS)))}',
                  DayBars(
                    values: [for (final d in days) d.activeS / 60],
                    labels: labels,
                  ),
                ),
                _section(
                  context,
                  'Scratching per day',
                  'average ${formatDuration(_avg(days.map((d) => d.scratchingS)))}',
                  DayBars(
                    values: [for (final d in days) d.scratchingS / 60],
                    labels: labels,
                  ),
                ),
                _section(
                  context,
                  'Night wake-ups',
                  'nights with more than 3: ${days.where((d) => d.nightWakeups > 3).length}',
                  DayBars(
                    values: [for (final d in days) d.nightWakeups.toDouble()],
                    labels: labels,
                    highlight: (i) => days[i].nightWakeups > 3,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  int _avg(Iterable<int> xs) =>
      xs.isEmpty ? 0 : (xs.reduce((a, b) => a + b) / xs.length).round();

  Widget _section(
    BuildContext context,
    String title,
    String subtitle,
    Widget chart,
  ) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          chart,
        ],
      ),
    ),
  );
}
