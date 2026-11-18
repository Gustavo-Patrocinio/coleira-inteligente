import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import '../api/day_summary.dart';
import '../collar/collar_link.dart';
import '../collar/firmware_update.dart';
import '../collar/sync_service.dart';
import '../collection/collection_screen.dart';
import 'app_state.dart';
import 'firmware_card.dart';
import 'onboarding.dart';
import 'widgets.dart';

class CollarScreen extends StatefulWidget {
  CollarScreen({
    super.key,
    required this.link,
    required this.sync,
    FirmwareUpdater? updater,
    ReleaseSource? releases,
  }) : updater = updater ?? FirmwareUpdater(UniversalBleSmpTransport()),
       releases = releases ?? ReleaseSource();
  final CollarLink link;
  final SyncTransport sync;
  final FirmwareUpdater updater;
  final ReleaseSource releases;

  @override
  State<CollarScreen> createState() => _CollarScreenState();
}

class _CollarScreenState extends State<CollarScreen> {
  String? _message;
  String? _selected; // collar whose firmware card is shown
  Future<List<CollarInfo>>? _server; // battery and last data, from the server
  int? _loadedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = AppScope.of(context);
    if (_loadedFor != s.dog!.id) _refresh();
  }

  void _refresh() {
    final s = AppScope.of(context);
    _loadedFor = s.dog!.id;
    _server = s.api!.devices(s.dog!.id).catchError((_) => <CollarInfo>[]);
  }

  Future<void> _syncNow() async {
    final s = AppScope.of(context);
    setState(() => _message = 'Syncing…');
    try {
      await s.syncCollar(widget.sync);
    } catch (_) {
      // the message is in s.lastSyncMessage
    }
    if (mounted) {
      setState(() {
        _message = s.lastSyncMessage;
        _refresh();
      });
    }
  }

  Future<void> _unpair(PairedCollar c) async {
    final s = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Unpair this collar?'),
        content: Text(
          'It stops sending data for ${s.dog!.name}. The minutes already recorded stay. '
          'You can pair it again, with this dog or another one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await s.unpairCollar(c);
      if (mounted) setState(_refresh);
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not unpair: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final text = Theme.of(context).textTheme;
    final mine = s.dogCollars;
    final selected =
        mine.where((c) => c.id == _selected).firstOrNull ?? mine.firstOrNull;
    return Scaffold(
      appBar: AppBar(title: DogTitle((d) => '${d.name}\'s collar')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    mine.isEmpty
                        ? 'No collar paired'
                        : mine.length == 1
                        ? 'Collar paired'
                        : '${mine.length} collars paired',
                    style: text.titleMedium,
                  ),
                  FutureBuilder<List<CollarInfo>>(
                    future: _server,
                    builder: (context, snap) {
                      final info = {
                        for (final i in snap.data ?? const <CollarInfo>[])
                          i.serial: i,
                      };
                      return Column(
                        children: [
                          for (final c in mine)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                Icons.sensors,
                                color: c.id == selected?.id
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              title: Text(c.name ?? 'Collar'),
                              subtitle: Text(
                                [
                                  c.id,
                                  if (info[c.id]?.lastMinute != null)
                                    'data until ${formatAgo(info[c.id]!.lastMinute!)}',
                                  if (info[c.id]?.batteryPct != null)
                                    'battery ${info[c.id]!.batteryPct}%',
                                ].join(' · '),
                              ),
                              onTap: () => setState(() => _selected = c.id),
                              trailing: IconButton(
                                tooltip: 'Unpair',
                                icon: const Icon(Icons.link_off),
                                onPressed: () => _unpair(c),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'At home the base station syncs on its own. Away from home, this phone '
                    'syncs every paired collar whenever you open the app nearby.',
                  ),
                  if (s.lastSyncAt != null)
                    Text(
                      'Last synced ${formatAgo(s.lastSyncAt!)}',
                      style: text.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  if (s.collars.isNotEmpty)
                    FilledButton.icon(
                      onPressed: s.syncing ? null : _syncNow,
                      icon: const Icon(Icons.sync),
                      label: Text(s.syncing ? 'Syncing…' : 'Sync now'),
                    ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_message!),
                    ),
                  const SizedBox(height: 8),
                  PairCollarPanel(
                    link: widget.link,
                    label: mine.isEmpty
                        ? 'Pair a collar'
                        : 'Pair another collar',
                    onPaired: () => setState(_refresh),
                  ),
                ],
              ),
            ),
          ),
          if (selected != null)
            FirmwareCard(
              key: ValueKey(selected.id),
              collarId: selected.id,
              updater: widget.updater,
              releases: widget.releases,
            ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Help improve recognition'),
              subtitle: const Text(
                'Record a session with video. It becomes training data so the model '
                'learns your dog\'s behaviors.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CollectionScreen(link: widget.link),
                ),
              ),
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.health_and_safety),
              title: Text('Comfort and safety'),
              subtitle: Text(
                'Two fingers between collar and neck. Check the skin weekly. Charge with the '
                'collar off the dog. The prototype is not waterproof.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
