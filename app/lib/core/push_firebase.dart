/// Firebase Cloud Messaging implementation of [PushService]. Falls back to [NoPush] when the
/// app was built without Firebase configuration files.
library;

import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'push.dart';

class FirebasePush implements PushService {
  FirebasePush._(this._fm);
  final FirebaseMessaging _fm;

  static String get _platform => Platform.isIOS ? 'ios' : 'android';

  /// `google-services.json` (Android) / `GoogleService-Info.plist` (iOS) present → FCM;
  /// missing → [NoPush], so builds without a Firebase project keep working.
  static Future<PushService> create() async {
    try {
      await Firebase.initializeApp();
      return FirebasePush._(FirebaseMessaging.instance);
    } catch (_) {
      return const NoPush();
    }
  }

  @override
  Future<PushToken?> register() async {
    final settings = await _fm.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) return null;
    // The registration token our server sends to with FCM's HTTP v1 `token` field. The
    // newer register()/onRegistered API yields an installation ID for a different send path.
    // ignore: deprecated_member_use
    final t = await _fm.getToken();
    return t == null ? null : PushToken(t, _platform);
  }

  @override
  Stream<PushToken> get tokenRefresh =>
      // ignore: deprecated_member_use
      _fm.onTokenRefresh.map((t) => PushToken(t, _platform));
}
