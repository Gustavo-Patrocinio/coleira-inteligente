import 'package:material_ui/material_ui.dart';

import '../api/alert_text.dart';
import '../api/api_client.dart';
import 'app_state.dart';
import 'widgets.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});
  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  Future<List<AlertItem>>? _alerts;
  final Map<int, bool> _given = {};

  Future<List<AlertItem>> _fetch() {
    final s = AppScope.of(context);
    return s.api!.alerts(s.dog!.id);
  }

  void _load() => setState(() {
    _alerts = _fetch();
  });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _alerts ??= _fetch(); // first load: no setState needed during dependencies
  }

  Future<void> _feedback(AlertItem a, bool useful) async {
    await AppScope.of(context).api!.alertFeedback(a.id, useful: useful);
    setState(() => _given[a.id] = useful);
  }

  @override
  Widget build(BuildContext context) {
    final dog = AppScope.of(context).dog!;
    return Scaffold(
      appBar: AppBar(title: DogTitle((d) => '${d.name} · alerts')),
      body: RefreshIndicator(
        onRefresh: () async => _load(),
        child: FutureBuilder<List<AlertItem>>(
          future: _alerts,
          builder: (context, snap) {
            if (snap.hasError) {
              return ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('${snap.error}'),
                  ),
                ],
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (snap.data!.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      'No alerts. The app learns your dog\'s normal over the first two '
                      'weeks and only warns when a day is far from it.',
                    ),
                  ),
                for (final a in snap.data!) _card(context, a, dog),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _card(BuildContext context, AlertItem a, Dog dog) {
    final copy = alertCopy(a, dog);
    final given =
        _given[a.id] ?? (a.feedback == null ? null : a.feedback == 'useful');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(copy.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(copy.body),
            const SizedBox(height: 10),
            Row(
              children: [
                const Expanded(child: Text('Did this alert make sense?')),
                ChoiceChip(
                  label: const Text('Yes'),
                  selected: given == true,
                  onSelected: (_) => _feedback(a, true),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('False alarm'),
                  selected: given == false,
                  onSelected: (_) => _feedback(a, false),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
