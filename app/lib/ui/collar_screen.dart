import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import '../collar/collar_link.dart';
import '../collar/sync_service.dart';
import '../collection/collection_screen.dart';
import '../core/sync_protocol.dart';
import 'app_state.dart';

class CollarScreen extends StatefulWidget {
  const CollarScreen({super.key, required this.link, required this.sync});
  final CollarLink link;
  final SyncTransport sync;

  @override
  State<CollarScreen> createState() => _CollarScreenState();
}

class _CollarScreenState extends State<CollarScreen> {
  String? _paired;
  String? _token;
  bool _busy = false;
  String? _message;
  final List<FoundCollar> _found = [];
  StreamSubscription<FoundCollar>? _scan;

  @override
  void initState() {
    super.initState();
    _loadPairing();
  }

  @override
  void dispose() {
    _scan?.cancel();
    super.dispose();
  }

  Future<void> _loadPairing() async {
    final store = AppScope.of(context).store;
    final paired = await store.read('paired_collar');
    final token = await store.read('device_token');
    if (mounted) {
      setState(() {
        _paired = paired;
        _token = token;
      });
    }
  }

  void _startPairing() {
    setState(() {
      _found.clear();
      _message = 'Looking for the collar…';
    });
    _scan?.cancel();
    _scan = widget.link.scan(serviceUuid: syncServiceUuid).listen((c) {
      if (_found.every((f) => f.id != c.id)) setState(() => _found.add(c));
    });
    Future.delayed(const Duration(seconds: 12), () async {
      await widget.link.stopScan();
      if (mounted) {
        setState(
          () => _message = _found.isEmpty ? 'No collar found nearby.' : null,
        );
      }
    });
  }

  Future<void> _pair(FoundCollar c) async {
    final s = AppScope.of(context);
    await widget.link.stopScan();
    setState(() => _busy = true);
    try {
      final token = await s.api!.registerDevice(s.dog!.id, c.id);
      await s.store.write('paired_collar', c.id);
      await s.store.write('device_token', token);
      setState(() {
        _paired = c.id;
        _token = token;
        _found.clear();
        _message = 'Collar paired with ${s.dog!.name}.';
      });
    } on ApiException catch (e) {
      setState(() => _message = 'Could not pair: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    final s = AppScope.of(context);
    setState(() {
      _busy = true;
      _message = 'Syncing…';
    });
    try {
      final r = await SyncService(
        transport: widget.sync,
        api: s.api!,
        store: s.store,
      ).syncAndUpload(_paired!, _token!);
      setState(
        () => _message = r.records == 0
            ? 'Already up to date.'
            : 'Synced ${r.records} minutes (${r.inserted} new, ${r.duplicates} already on the server).',
      );
    } catch (e) {
      setState(() => _message = 'Sync failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Collar')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _paired == null ? 'No collar paired' : 'Collar paired',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (_paired != null)
                    Text(
                      _paired!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'At home the base station syncs on its own. Away from home, sync here.',
                  ),
                  const SizedBox(height: 12),
                  if (_paired == null)
                    FilledButton.icon(
                      onPressed: _busy ? null : _startPairing,
                      icon: const Icon(Icons.link),
                      label: const Text('Pair collar'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _busy ? null : _syncNow,
                      icon: const Icon(Icons.sync),
                      label: const Text('Sync now'),
                    ),
                  for (final c in _found)
                    ListTile(
                      leading: const Icon(Icons.sensors),
                      title: Text(c.name),
                      subtitle: Text(c.id),
                      onTap: _busy ? null : () => _pair(c),
                    ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_message!),
                    ),
                ],
              ),
            ),
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
          Card(
            child: ListTile(
              leading: const Icon(Icons.dns),
              title: const Text('Server'),
              subtitle: Text(s.server),
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
          const SizedBox(height: 12),
          OutlinedButton(onPressed: s.signOut, child: const Text('Sign out')),
        ],
      ),
    );
  }
}
