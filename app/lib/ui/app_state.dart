import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/api_client.dart';
import '../core/push.dart';
import '../collar/summary_cache.dart';
import '../collar/sync_service.dart';

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
  AppState({
    required this.store,
    CollarApi Function(Uri)? apiFactory,
    SummaryCache? cache,
    DateTime Function()? clock,
    this.push = const NoPush(),
  }) : _apiFactory = apiFactory ?? ((u) => CollarApi(baseUrl: u)),
       cache = cache ?? FileSummaryCache(),
       _clock = clock ?? DateTime.now;

  static const defaultServer = 'http://192.168.0.10:3000';
  final SessionStore store;
  final CollarApi Function(Uri) _apiFactory;
  final SummaryCache cache;
  final DateTime Function() _clock;
  final PushService push;
  String? _pushToken;
  StreamSubscription<PushToken>? _pushRefresh;

  /// Version of the privacy notice in the app (ConsentScreen). Bump it when the notice
  /// changes in a way users must agree to again.
  static const consentVersion = 1;

  CollarApi? api;
  String server = defaultServer;
  Dog? dog;
  Me? me;

  /// Set after the dog is created, so onboarding offers to pair the collar once.
  bool pairStepPending = false;

  bool get needsConsent => (me?.consentVersion ?? 0) < consentVersion;
  bool restoring = true;

  /// Bumped whenever new records arrive, so screens showing the day reload.
  int dataVersion = 0;
  bool syncing = false;
  DateTime? lastSyncAt;
  DateTime? _lastAttempt;
  String? lastSyncMessage;

  bool get loggedIn => api?.token != null;

  Future<void> restore() async {
    server = await store.read('server') ?? defaultServer;
    api = _apiFactory(Uri.parse(server))..token = await store.read('token');
    if (loggedIn) {
      try {
        await _pickDog();
        me = await api!.me();
        unawaited(_registerPush());
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
    me = await a.me();
    unawaited(_registerPush());
    notifyListeners();
  }

  Future<void> createDog(String name) async {
    dog = await api!.createDog(name);
    await store.write('dog', '${dog!.id}');
    pairStepPending = await store.read('paired_collar') == null;
    notifyListeners();
  }

  Future<void> acceptConsent({required bool researchOptIn}) async {
    me = await api!.putConsent(consentVersion, researchOptIn: researchOptIn);
    unawaited(_registerPush());
    notifyListeners();
  }

  /// Registers the collar for the selected dog and keeps its upload token on the phone.
  Future<void> pairCollar(String collarId) async {
    final token = await api!.registerDevice(dog!.id, collarId);
    await store.write('paired_collar', collarId);
    await store.write('device_token', token);
    pairStepPending = false;
    notifyListeners();
  }

  void skipPairing() {
    pairStepPending = false;
    notifyListeners();
  }

  /// LGPD: deletes the account and every record on the server, then forgets it here.
  Future<void> deleteAccount() async {
    await api!.deleteMe();
    for (final k in ['paired_collar', 'device_token']) {
      await store.write(k, null);
    }
    await signOut();
  }

  /// Asks for notification permission only after consent (the first screen explains
  /// alerts); best effort: without push, alerts still show in the app.
  Future<void> _registerPush() async {
    if (needsConsent || api == null) return;
    try {
      final t = await push.register();
      if (t == null) return;
      await api!.putPushToken(t.token, t.platform);
      _pushToken = t.token;
      _pushRefresh ??= push.tokenRefresh.listen((n) async {
        try {
          await api?.putPushToken(n.token, n.platform);
          _pushToken = n.token;
        } catch (_) {}
      });
    } catch (_) {}
  }

  Future<void> signOut() async {
    // this phone stops getting the account's alerts (best effort: the server also drops
    // tokens FCM reports as gone)
    final t = _pushToken;
    if (t != null && loggedIn) {
      try {
        await api!.deletePushToken(t);
      } catch (_) {}
    }
    _pushToken = null;
    await _pushRefresh?.cancel();
    _pushRefresh = null;
    api?.token = null;
    dog = null;
    me = null;
    await store.write('token', null);
    await store.write('dog', null);
    await cache
        .clear(); // the dog's minutes do not stay on a phone after sign-out
    notifyListeners();
  }

  /// Syncs the paired collar (contract 4.8) and uploads. `auto` runs are silent, skipped
  /// when there is no paired collar and throttled, so opening the app often is cheap.
  Future<SyncResult?> syncCollar(
    SyncTransport transport, {
    bool auto = false,
    Duration minInterval = const Duration(minutes: 10),
  }) async {
    final collar = await store.read('paired_collar');
    final token = await store.read('device_token');
    if (syncing || collar == null || token == null || api == null) return null;
    final now = _clock();
    if (auto &&
        _lastAttempt != null &&
        now.difference(_lastAttempt!) < minInterval) {
      return null;
    }
    _lastAttempt = now;
    syncing = true;
    notifyListeners();
    try {
      final r = await SyncService(
        transport: transport,
        api: api!,
        store: store,
        cache: cache,
      ).syncAndUpload(collar, token);
      lastSyncAt = _clock();
      if (r.records > 0) dataVersion++;
      lastSyncMessage = r.records == 0
          ? 'Already up to date.'
          : r.uploaded
          ? 'Synced ${r.records} minutes (${r.inserted} new on the server).'
          : 'Got ${r.records} minutes from the collar; upload will be retried '
                '(server unreachable).';
      return r;
    } catch (e) {
      // auto runs fail quietly (collar out of range is normal); manual runs show it
      lastSyncMessage = auto ? lastSyncMessage : 'Sync failed: $e';
      if (!auto) rethrow;
      return null;
    } finally {
      syncing = false;
      notifyListeners();
    }
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
