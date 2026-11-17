import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api/day_summary.dart';
import '../collar/collar_link.dart';
import '../collar/firmware_update.dart';
import '../collar/sync_service.dart';
import '../collection/collection_screen.dart';
import 'app_state.dart';
import 'firmware_card.dart';
import 'onboarding.dart';

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
  String? _paired;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadPairing();
  }

  Future<void> _loadPairing() async {
    final paired = await AppScope.of(context).store.read('paired_collar');
    if (mounted) setState(() => _paired = paired);
  }

  Future<void> _syncNow() async {
    final s = AppScope.of(context);
    setState(() => _message = 'Syncing…');
    try {
      await s.syncCollar(widget.sync);
    } catch (_) {
      // the message is in s.lastSyncMessage
    }
    if (mounted) setState(() => _message = s.lastSyncMessage);
  }

  Future<void> _export() async {
    final s = AppScope.of(context);
    try {
      final json = await s.api!.exportMe();
      final dir = await getTemporaryDirectory();
      final f = File(
        '${dir.path}${Platform.pathSeparator}collar-data-export.json',
      );
      await f.writeAsString(json);
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
    } catch (e) {
      if (mounted) setState(() => _message = 'Export failed: $e');
    }
  }

  Future<void> _delete() async {
    final s = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'Your account, your dogs and every recorded minute are deleted from the server '
          'now. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await s.deleteAccount();
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not delete: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Collar')),
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
                    _paired == null ? 'No collar paired' : 'Collar paired',
                    style: text.titleMedium,
                  ),
                  if (_paired != null) Text(_paired!, style: text.bodySmall),
                  const SizedBox(height: 8),
                  const Text(
                    'At home the base station syncs on its own. Away from home, this phone '
                    'syncs whenever you open the app near the collar.',
                  ),
                  if (s.lastSyncAt != null)
                    Text(
                      'Last synced ${formatAgo(s.lastSyncAt!)}',
                      style: text.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  if (_paired == null)
                    PairCollarPanel(link: widget.link, onPaired: _loadPairing)
                  else
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
                ],
              ),
            ),
          ),
          if (_paired != null)
            FirmwareCard(
              collarId: _paired!,
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
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ListTile(
                  leading: Icon(Icons.privacy_tip),
                  title: Text('Your data'),
                  subtitle: Text(
                    'Stored on the server below. Download or delete it any time.',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.download),
                  title: const Text('Download my data'),
                  onTap: _export,
                ),
                ListTile(
                  leading: Icon(
                    Icons.delete_forever,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: const Text('Delete account and all data'),
                  onTap: _delete,
                ),
              ],
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
