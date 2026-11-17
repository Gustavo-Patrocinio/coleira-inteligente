/// First run, without help (Phase 6 goal): privacy notice and consent (LGPD) → the dog's
/// profile → pair the collar. Each step is skipped once done.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import '../collar/collar_link.dart';
import '../core/sync_protocol.dart';
import 'app_state.dart';

class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key});
  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _agree = false;
  bool _research = false;
  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await AppScope.of(context).acceptConsent(researchOptIn: _research);
    } on Exception catch (e) {
      setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final text = Theme.of(context).textTheme;
    Widget section(String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleSmall),
          const SizedBox(height: 4),
          Text(body),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Your data')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          section(
            'What the collar records',
            'How many seconds per minute your dog spent still, walking, running, '
                'scratching or shaking. No location, no sound, no video.',
          ),
          section(
            'Where it goes',
            'To the server you signed in to (${s.server}), with your email and your dog\'s '
                'name and profile. A copy of recent days stays on this phone.',
          ),
          section(
            'What it is used for',
            'To show your dog\'s routine, learn what is normal for them and tell you when '
                'something changes. It is not a diagnosis: when in doubt, talk to your vet.',
          ),
          section(
            'Videos',
            'Only if you use "Help improve recognition". Those sessions stay on your phone '
                'and leave it only when you share them yourself.',
          ),
          section(
            'Your rights',
            'Download everything or delete your account and all its data at any time '
                '(Collar tab → Your data). Deleting is immediate and permanent.',
          ),
          const Divider(),
          CheckboxListTile(
            value: _research,
            onChanged: (v) => setState(() => _research = v ?? false),
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Optional: I may share recorded sessions to improve the model',
            ),
            subtitle: const Text(
              'Helps recognition work for every dog. You can change this later.',
            ),
          ),
          CheckboxListTile(
            value: _agree,
            onChanged: (v) => setState(() => _agree = v ?? false),
            contentPadding: EdgeInsets.zero,
            title: const Text('I have read this and agree'),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _agree && !_busy ? _accept : null,
            child: const Text('Agree and continue'),
          ),
          TextButton(
            onPressed: s.signOut,
            child: const Text('Not now (sign out)'),
          ),
        ],
      ),
    );
  }
}

class CreateDogScreen extends StatefulWidget {
  const CreateDogScreen({super.key});
  @override
  State<CreateDogScreen> createState() => _CreateDogScreenState();
}

class _CreateDogScreenState extends State<CreateDogScreen> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your dog')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('What is your dog\'s name?'),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _name.text.trim().isEmpty
                  ? null
                  : AppScope.of(context).createDog(_name.text.trim()),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scans for collars running the normal firmware (sync service) and pairs one.
/// Used by onboarding and by the Collar tab.
class PairCollarPanel extends StatefulWidget {
  const PairCollarPanel({super.key, required this.link, this.onPaired});
  final CollarLink link;
  final VoidCallback? onPaired;
  @override
  State<PairCollarPanel> createState() => _PairCollarPanelState();
}

class _PairCollarPanelState extends State<PairCollarPanel> {
  final List<FoundCollar> _found = [];
  StreamSubscription<FoundCollar>? _scan;
  bool _scanning = false;
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _scan?.cancel();
    if (_scanning) widget.link.stopScan();
    super.dispose();
  }

  void _start() {
    setState(() {
      _found.clear();
      _scanning = true;
      _message = 'Looking for the collar… keep it close to the phone.';
    });
    _scan?.cancel();
    _scan = widget.link.scan(services: const [syncServiceUuid]).listen((c) {
      if (_found.every((f) => f.id != c.id)) setState(() => _found.add(c));
    });
    Future.delayed(const Duration(seconds: 12), () async {
      if (!mounted || !_scanning) return;
      await widget.link.stopScan();
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _message = _found.isEmpty
            ? 'No collar found. Is it charged and nearby? Try again.'
            : null;
      });
    });
  }

  Future<void> _pair(FoundCollar c) async {
    final s = AppScope.of(context);
    await widget.link.stopScan();
    setState(() {
      _scanning = false;
      _busy = true;
    });
    try {
      await s.pairCollar(c.id);
      widget.onPaired?.call();
      if (mounted) {
        setState(() => _message = 'Collar paired with ${s.dog!.name}.');
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _message = 'Could not pair: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: _busy || _scanning ? null : _start,
          icon: const Icon(Icons.link),
          label: Text(_scanning ? 'Looking…' : 'Pair collar'),
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
    );
  }
}

class PairStepScreen extends StatelessWidget {
  const PairStepScreen({super.key, required this.link});
  final CollarLink link;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Pair the collar')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Turn the collar on (charge it first) and keep it next to the phone. Then tap '
            'Pair collar and pick it from the list.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Fit: two fingers between the collar and the neck, the device under the neck '
            'with the arrow pointing to the head.',
          ),
          const SizedBox(height: 20),
          PairCollarPanel(link: link),
          const SizedBox(height: 12),
          TextButton(
            onPressed: s.skipPairing,
            child: const Text('Skip for now'),
          ),
        ],
      ),
    );
  }
}
