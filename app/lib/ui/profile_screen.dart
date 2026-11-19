import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api/api_client.dart';
import '../core/errors.dart';
import 'app_state.dart';
import 'dog_form.dart';
import 'widgets.dart';

/// The owner's account, the dogs on it, privacy (export / delete) and sign-out.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String? _message;

  void _say(String m) {
    if (mounted) setState(() => _message = m);
  }

  Future<void> _editName() async {
    final s = AppScope.of(context);
    final c = TextEditingController(text: s.me?.name);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, c.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    c.dispose();
    if (name == null) return;
    try {
      await s.updateName(name);
    } catch (e) {
      _say('Could not save. ${friendlyError(e)}');
    }
  }

  Future<void> _changePassword() async {
    final s = AppScope.of(context);
    final current = TextEditingController();
    final next = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Change password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: current,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password'),
            ),
            TextField(
              controller: next,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New password (10+ characters)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Change'),
          ),
        ],
      ),
    );
    final (cur, nxt) = (current.text, next.text);
    current.dispose();
    next.dispose();
    if (ok != true) return;
    if (nxt.length < 10) return _say('The new password needs 10+ characters.');
    try {
      await s.changePassword(cur, nxt);
      _say('Password changed.');
    } on ApiException catch (e) {
      _say(
        e.status == 403
            ? 'The current password is wrong.'
            : 'Could not change it. ${friendlyError(e)}',
      );
    } catch (e) {
      _say('Could not change it. ${friendlyError(e)}');
    }
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
      _say('Export failed. ${friendlyError(e)}');
    }
  }

  Future<void> _deleteAccount() async {
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
      _say('Could not delete. ${friendlyError(e)}');
    }
  }

  void _open(Dog? dog) =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => DogFormScreen(dog: dog)));

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(s.me?.name ?? 'Add your name'),
                  subtitle: Text(s.me?.email ?? ''),
                  trailing: const Icon(Icons.edit),
                  onTap: _editName,
                ),
                ListTile(
                  leading: const Icon(Icons.lock),
                  title: const Text('Change password'),
                  onTap: _changePassword,
                ),
              ],
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(_message!),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
            child: Text('Your dogs', style: text.titleMedium),
          ),
          Card(
            child: Column(
              children: [
                for (final d in s.dogs)
                  ListTile(
                    leading: DogAvatar(d),
                    title: Text(d.name),
                    subtitle: Text(
                      [
                        ?dogSubtitle(d),
                        '${s.collars.where((c) => c.dogId == d.id).length} collar(s) on this phone',
                      ].join('\n'),
                    ),
                    isThreeLine: dogSubtitle(d) != null,
                    selected: d.id == s.dog?.id,
                    onTap: () => s.selectDog(d),
                    trailing: IconButton(
                      tooltip: 'Edit ${d.name}',
                      icon: const Icon(Icons.edit),
                      onPressed: () => _open(d),
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('Add a dog'),
                  onTap: () => _open(null),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
            child: Text('Your data', style: text.titleMedium),
          ),
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.privacy_tip),
                  title: Text('Stored on your server'),
                  subtitle: Text('Download or delete it any time (LGPD).'),
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
                  onTap: _deleteAccount,
                ),
                ListTile(
                  leading: const Icon(Icons.dns),
                  title: const Text('Server'),
                  subtitle: Text(s.server),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: s.signOut, child: const Text('Sign out')),
        ],
      ),
    );
  }
}
