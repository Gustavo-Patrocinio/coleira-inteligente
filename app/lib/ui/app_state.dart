import 'dart:async';
import 'dart:convert';

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
  Dog? dog; // the dog the screens show
  List<Dog> dogs = [];
  Me? me;

  /// Collars paired from this phone, any of the account's dogs. Each keeps its own upload
  /// token (contract 4.8 sync runs per collar).
  List<PairedCollar> collars = [];
  List<PairedCollar> get dogCollars => [
    for (final c in collars)
      if (c.dogId == dog?.id) c,
  ];

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
    await _loadCollars();
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

  /// Adds a dog to the account and shows it. After onboarding's first dog, offers pairing.
  Future<void> createDog(DogProfile profile) async {
    final created = await api!.createDog(profile);
    dogs = [...dogs, created];
    await selectDog(created);
    pairStepPending = dogCollars.isEmpty && dogs.length == 1;
    notifyListeners();
  }

  Future<void> updateDog(Dog d, DogProfile profile) async {
    final updated = await api!.updateDog(d.id, profile);
    dogs = [for (final x in dogs) x.id == d.id ? updated : x];
    if (dog?.id == d.id) dog = updated;
    notifyListeners();
  }

  /// Deletes the dog and its data on the server; its collars on this phone are forgotten.
  Future<void> deleteDog(Dog d) async {
    await api!.deleteDog(d.id);
    dogs = [
      for (final x in dogs)
        if (x.id != d.id) x,
    ];
    collars = [
      for (final c in collars)
        if (c.dogId != d.id) c,
    ];
    await _saveCollars();
    if (dog?.id == d.id) {
      dog = dogs.firstOrNull;
      await store.write('dog', dog == null ? null : '${dog!.id}');
    }
    dataVersion++;
    notifyListeners();
  }

  Future<void> selectDog(Dog d) async {
    dog = d;
    await store.write('dog', '${d.id}');
    dataVersion++;
    notifyListeners();
  }

  Future<void> acceptConsent({required bool researchOptIn}) async {
    me = await api!.putConsent(consentVersion, researchOptIn: researchOptIn);
    unawaited(_registerPush());
    notifyListeners();
  }

  Future<void> updateName(String name) async {
    me = await api!.updateMe(name: name.trim().isEmpty ? null : name.trim());
    notifyListeners();
  }

  Future<void> changePassword(String current, String next) =>
      api!.changePassword(current, next);

  /// Registers the collar for [forDog] (default: the dog on screen). A collar already paired
  /// here with another dog moves (the server keeps the old dog's history).
  Future<void> pairCollar(String collarId, {Dog? forDog, String? name}) async {
    final d = forDog ?? dog!;
    final r = await api!.registerDevice(d.id, collarId, name: name);
    collars = [
      for (final c in collars)
        if (c.id != collarId) c,
      PairedCollar(
        id: collarId,
        dogId: d.id,
        deviceId: r.deviceId,
        token: r.token,
        name: name,
      ),
    ];
    await _saveCollars();
    pairStepPending = false;
    notifyListeners();
  }

  /// Unpairs on the server (its token stops working) and forgets it on this phone.
  Future<void> unpairCollar(PairedCollar c) async {
    if (c.deviceId != null) {
      try {
        await api!.deleteDevice(c.deviceId!);
      } on ApiException catch (e) {
        // already gone on the server: just forget it here
        if (e.status != 404) rethrow;
      }
    }
    collars = [
      for (final x in collars)
        if (x.id != c.id) x,
    ];
    await store.write('sync_since_${c.id}', null);
    await _saveCollars();
    notifyListeners();
  }

  void skipPairing() {
    pairStepPending = false;
    notifyListeners();
  }

  Future<void> _loadCollars() async {
    final raw = await store.read('collars');
    collars = raw == null
        ? []
        : [
            for (final j in jsonDecode(raw) as List)
              PairedCollar.fromJson(j as Map<String, dynamic>),
          ];
    // app versions before several dogs kept one collar for the selected dog
    final legacy = await store.read('paired_collar');
    final legacyToken = await store.read('device_token');
    final legacyDog = int.tryParse(await store.read('dog') ?? '');
    if (legacy != null && legacyToken != null && legacyDog != null) {
      collars = [
        for (final c in collars)
          if (c.id != legacy) c,
        PairedCollar(id: legacy, dogId: legacyDog, token: legacyToken),
      ];
      await _saveCollars();
    }
    await store.write('paired_collar', null);
    await store.write('device_token', null);
  }

  Future<void> _saveCollars() =>
      store.write('collars', jsonEncode([for (final c in collars) c.toJson()]));

  /// LGPD: deletes the account and every record on the server, then forgets it here.
  Future<void> deleteAccount() async {
    await api!.deleteMe();
    collars = [];
    await _saveCollars();
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
    dogs = [];
    me = null;
    await store.write('token', null);
    await store.write('dog', null);
    await cache
        .clear(); // the dog's minutes do not stay on a phone after sign-out
    notifyListeners();
  }

  /// Syncs the paired collar (contract 4.8) and uploads. `auto` runs are silent, skipped
  /// when there is no paired collar and throttled, so opening the app often is cheap.
  /// Syncs every collar paired on this phone (all dogs, contract 4.8) and uploads. `auto`
  /// runs are silent and throttled, so opening the app often is cheap; a collar out of range
  /// does not stop the others.
  Future<SyncResult?> syncCollar(
    SyncTransport transport, {
    bool auto = false,
    Duration minInterval = const Duration(minutes: 10),
  }) async {
    if (syncing || collars.isEmpty || api == null) return null;
    final now = _clock();
    if (auto &&
        _lastAttempt != null &&
        now.difference(_lastAttempt!) < minInterval) {
      return null;
    }
    _lastAttempt = now;
    syncing = true;
    notifyListeners();
    final service = SyncService(
      transport: transport,
      api: api!,
      store: store,
      cache: cache,
    );
    final lines = <String>[];
    Object? firstError;
    SyncResult? total;
    try {
      for (final c in List.of(collars)) {
        final who =
            dogs.where((d) => d.id == c.dogId).firstOrNull?.name ?? c.id;
        try {
          final r = await service.syncAndUpload(c.id, c.token, dogId: c.dogId);
          if (r.records > 0) dataVersion++;
          lines.add(
            r.records == 0
                ? '$who: already up to date.'
                : r.uploaded
                ? '$who: synced ${r.records} minutes (${r.inserted} new on the server).'
                : '$who: got ${r.records} minutes; upload will be retried (server unreachable).',
          );
          total = SyncResult(
            records: (total?.records ?? 0) + r.records,
            inserted: (total?.inserted ?? 0) + r.inserted,
            duplicates: (total?.duplicates ?? 0) + r.duplicates,
            newestMinute: r.newestMinute ?? total?.newestMinute,
            uploadError: r.uploadError ?? total?.uploadError,
          );
        } catch (e) {
          firstError ??= e;
          lines.add('$who: not reached ($e).');
        }
      }
      if (total != null) lastSyncAt = _clock();
      // auto runs fail quietly (a collar out of range is normal); manual runs show it
      if (!auto || total != null) lastSyncMessage = lines.join('\n');
      if (total == null && !auto && firstError != null) throw firstError;
      return total;
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> _pickDog() async {
    dogs = await api!.dogs();
    final saved = int.tryParse(await store.read('dog') ?? '');
    dog = dogs.where((d) => d.id == saved).firstOrNull ?? dogs.firstOrNull;
  }
}

/// A collar paired from this phone.
class PairedCollar {
  const PairedCollar({
    required this.id,
    required this.dogId,
    required this.token,
    this.deviceId,
    this.name,
  });
  final String id; // BLE id
  final int dogId;
  final String token; // device upload token (shown once by the server)
  final int? deviceId; // server row; null for pairings from older app versions
  final String? name;

  factory PairedCollar.fromJson(Map<String, dynamic> j) => PairedCollar(
    id: j['id'] as String,
    dogId: j['dog_id'] as int,
    token: j['token'] as String,
    deviceId: j['device_id'] as int?,
    name: j['name'] as String?,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'dog_id': dogId,
    'token': token,
    'device_id': deviceId,
    'name': name,
  };
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
