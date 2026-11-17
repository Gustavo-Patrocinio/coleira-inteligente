import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/api_client.dart';

/// Where the session (server URL, JWT, selected dog) is kept between launches.
abstract class SessionStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

class SecureSessionStore implements SessionStore {
  const SecureSessionStore();
  static const _s = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String? value) =>
      value == null ? _s.delete(key: key) : _s.write(key: key, value: value);
}

class MemorySessionStore implements SessionStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String? value) async =>
      value == null ? data.remove(key) : data[key] = value;
}

/// App-wide state: the API client, the logged-in user and the selected dog.
class AppState extends ChangeNotifier {
  AppState({required this.store, CollarApi Function(Uri)? apiFactory})
    : _apiFactory = apiFactory ?? ((u) => CollarApi(baseUrl: u));

  static const defaultServer = 'http://192.168.0.10:3000';
  final SessionStore store;
  final CollarApi Function(Uri) _apiFactory;

  CollarApi? api;
  String server = defaultServer;
  Dog? dog;
  bool restoring = true;

  bool get loggedIn => api?.token != null;

  Future<void> restore() async {
    server = await store.read('server') ?? defaultServer;
    api = _apiFactory(Uri.parse(server))..token = await store.read('token');
    if (loggedIn) {
      try {
        await _pickDog();
      } catch (_) {
        api!.token = null; // expired token or server unreachable → log in again
      }
    }
    restoring = false;
    notifyListeners();
  }

  Future<void> signIn(
    String serverUrl,
    String email,
    String password, {
    required bool register,
  }) async {
    server = serverUrl.trim().replaceAll(RegExp(r'/$'), '');
    final a = _apiFactory(Uri.parse(server));
    register
        ? await a.register(email, password)
        : await a.login(email, password);
    api = a;
    await store.write('server', server);
    await store.write('token', a.token);
    await _pickDog();
    notifyListeners();
  }

  Future<void> createDog(String name) async {
    dog = await api!.createDog(name);
    await store.write('dog', '${dog!.id}');
    notifyListeners();
  }

  Future<void> signOut() async {
    api?.token = null;
    dog = null;
    await store.write('token', null);
    await store.write('dog', null);
    notifyListeners();
  }

  Future<void> _pickDog() async {
    final dogs = await api!.dogs();
    final saved = int.tryParse(await store.read('dog') ?? '');
    dog = dogs.where((d) => d.id == saved).firstOrNull ?? dogs.firstOrNull;
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
