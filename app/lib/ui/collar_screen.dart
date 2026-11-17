import 'package:material_ui/material_ui.dart';

import '../collar/collar_link.dart';
import '../collection/collection_screen.dart';
import 'app_state.dart';

class CollarScreen extends StatelessWidget {
  const CollarScreen({super.key, required this.link});
  final CollarLink link;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Collar')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
                MaterialPageRoute(builder: (_) => CollectionScreen(link: link)),
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
