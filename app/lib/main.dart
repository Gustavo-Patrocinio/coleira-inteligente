import 'package:material_ui/material_ui.dart';

import 'collar/collar_link.dart';
import 'collar/sync_service.dart';
import 'ui/app_state.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';

void main() {
  final state = AppState(store: const SecureSessionStore())..restore();
  runApp(
    CollarApp(
      state: state,
      link: UniversalBleCollarLink(),
      sync: UniversalBleSyncTransport(),
    ),
  );
}

class CollarApp extends StatelessWidget {
  const CollarApp({
    super.key,
    required this.state,
    required this.link,
    required this.sync,
  });
  final AppState state;
  final CollarLink link;
  final SyncTransport sync;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'Smart Collar',
        theme: ThemeData(
          colorScheme: .fromSeed(seedColor: const Color(0xFF1F5FBF)),
        ),
        darkTheme: ThemeData(
          colorScheme: .fromSeed(
            seedColor: const Color(0xFF1F5FBF),
            brightness: Brightness.dark,
          ),
        ),
        home: Builder(
          builder: (context) {
            final s = AppScope.of(context);
            if (s.restoring) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            return s.loggedIn
                ? HomeScreen(link: link, sync: sync)
                : const LoginScreen();
          },
        ),
      ),
    );
  }
}
