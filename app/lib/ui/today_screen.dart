import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import '../api/day_summary.dart';
import 'app_state.dart';
import 'widgets.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key, this.now});
  final DateTime Function()? now;
  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  Future<DayView>? _day;

  // The backend's days are in the dog's time zone; Brazil has no DST, so a fixed offset is
  // enough here. A full IANA lookup comes with multi-country support.
  static const _localOffset = Duration(hours: -3);

  String _today() {
    final n = (widget.now?.call() ?? DateTime.now()).toUtc().add(_localOffset);
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  Future<DayView> _fetch() {
    final s = AppScope.of(context);
    return s.api!.day(s.dog!.id, _today());
  }

  void _load() => setState(() {
    _day = _fetch();
  });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _day ??= _fetch(); // first load: no setState needed during dependencies
  }

  @override
  Widget build(BuildContext context) {
    final dog = AppScope.of(context).dog!;
    return Scaffold(
      appBar: AppBar(title: Text('${dog.name} · today')),
      body: RefreshIndicator(
        onRefresh: () async => _load(),
        child: FutureBuilder<DayView>(
          future: _day,
          builder: (context, snap) {
            if (snap.hasError) {
              return ListView(
                padding: const EdgeInsets.all(24),
                children: [Text('Could not load: ${snap.error}')],
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final d = snap.data!;
            final active =
                (d.totals['walking_s'] ?? 0) + (d.totals['running_s'] ?? 0);
            final scratch = d.totals['scratching_s'] ?? 0;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Timeline',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        TimelineBar(slots: timelineSlots(d, _localOffset)),
                      ],
                    ),
                  ),
                ),
                IndicatorCard(
                  icon: Icons.directions_walk,
                  label: 'Exercise',
                  value: formatDuration(active),
                  detail: 'walking + running today',
                ),
                IndicatorCard(
                  icon: Icons.nightlight_round,
                  label: 'Sleep (last night)',
                  value: d.nightWakeups == null
                      ? '—'
                      : 'woke up ${d.nightWakeups}×',
                  detail: d.nightWakeups == null
                      ? 'computed after the night is synced'
                      : 'times he got up 23:00–06:00',
                ),
                IndicatorCard(
                  icon: Icons.pets,
                  label: 'Skin',
                  value: 'scratched ${formatDuration(scratch)}',
                  detail: 'compared with his normal in Trends',
                ),
                if (d.blocks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No data for today yet. Data arrives when the collar syncs with the '
                      'home base station or this phone.',
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
