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
  Future<SleepView?>? _sleep;

  // The backend's days are in the dog's time zone; Brazil has no DST, so a fixed offset is
  // enough here. A full IANA lookup comes with multi-country support.
  static const _localOffset = Duration(hours: -3);

  String _today() {
    final n = (widget.now?.call() ?? DateTime.now()).toUtc().add(_localOffset);
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  int _seenVersion = -1;
  bool _offline = false;

  /// Server first; if it is unreachable, the day from records synced to this phone.
  Future<DayView> _fetch() async {
    final s = AppScope.of(context);
    final day = _today();
    try {
      final v = await s.api!.day(s.dog!.id, day);
      _offline = false;
      return v;
    } on ApiException {
      rethrow; // the server answered: a real error, not a connectivity problem
    } catch (e) {
      final (from, to) = dayBounds(day, _localOffset);
      final local = await s.cache.range(from, to, dog: s.dog!.id);
      if (local.isEmpty) rethrow;
      _offline = true;
      return dayFromRecords(day, local);
    }
  }

  /// Optional: an older server without the sleep route, or no connection, falls back to the
  /// day view's night wake-ups.
  Future<SleepView?> _fetchSleep() async {
    final s = AppScope.of(context);
    try {
      return await s.api!.sleep(s.dog!.id, _today());
    } catch (_) {
      return null;
    }
  }

  void _load() => setState(() {
    _day = _fetch();
    _sleep = _fetchSleep();
  });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // first load, and again whenever a sync brought new records (no setState needed here)
    final v = AppScope.of(context).dataVersion;
    if (_day == null || v != _seenVersion) {
      _seenVersion = v;
      _day = _fetch();
      _sleep = _fetchSleep();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dog = AppScope.of(context).dog!;
    return Scaffold(
      appBar: AppBar(title: DogTitle((d) => '${d.name} · today')),
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
                if (_offline)
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.cloud_off),
                      title: Text('Offline'),
                      subtitle: Text(
                        'Showing what this phone synced from the collar. Trends and '
                        'alerts come back with the connection.',
                      ),
                    ),
                  ),
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
                FutureBuilder<SleepView?>(
                  future: _sleep,
                  builder: (context, sleepSnap) {
                    final (value, detail) = sleepCardText(
                      sleepSnap.data,
                      d.nightWakeups,
                      _localOffset,
                      subject: dog.subject,
                    );
                    return IndicatorCard(
                      icon: Icons.nightlight_round,
                      label: 'Sleep (last night)',
                      value: value,
                      detail: detail,
                    );
                  },
                ),
                IndicatorCard(
                  icon: Icons.pets,
                  label: 'Skin',
                  value: 'scratched ${formatDuration(scratch)}',
                  detail: 'compared with ${dog.possessive} normal in Trends',
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
