import 'package:material_ui/material_ui.dart';

import '../collar/collar_link.dart';
import '../collar/sync_service.dart';
import 'alerts_screen.dart';
import 'app_state.dart';
import 'collar_screen.dart';
import 'today_screen.dart';
import 'trends_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.link, required this.sync});
  final CollarLink link;
  final SyncTransport sync;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _autoSync();
  }

  /// Phone fallback sync (ADR 0007): silent, throttled, only with a paired collar.
  void _autoSync() {
    if (!mounted) return;
    AppScope.of(context).syncCollar(widget.sync, auto: true);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    if (s.dog == null) return const _CreateDog();
    final pages = [
      const TodayScreen(),
      const TrendsScreen(),
      const AlertsScreen(),
      CollarScreen(link: widget.link, sync: widget.sync),
    ];
    return Scaffold(
      body: pages[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today), label: 'Today'),
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Trends'),
          NavigationDestination(
            icon: Icon(Icons.notifications),
            label: 'Alerts',
          ),
          NavigationDestination(icon: Icon(Icons.sensors), label: 'Collar'),
        ],
      ),
    );
  }
}

class _CreateDog extends StatefulWidget {
  const _CreateDog();
  @override
  State<_CreateDog> createState() => _CreateDogState();
}

class _CreateDogState extends State<_CreateDog> {
  final _name = TextEditingController();

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
