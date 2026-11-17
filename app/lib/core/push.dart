/// Push notifications for new alerts. The app only hands the phone's token to our server
/// (PUT /v1/me/push-token); the server sends through Firebase Cloud Messaging.
library;

class PushToken {
  const PushToken(this.token, this.platform);
  final String token;
  final String platform; // android | ios
}

abstract class PushService {
  /// Asks for notification permission (once, by the OS) and returns this phone's token, or
  /// null when notifications are off or unavailable.
  Future<PushToken?> register();

  /// Tokens rotate; each new one must reach the server.
  Stream<PushToken> get tokenRefresh;
}

/// Used when the app is built without a Firebase project (the default for self-builders,
/// `app/README.md`, *Push notifications*) and in tests: alerts still show in the app.
class NoPush implements PushService {
  const NoPush();
  @override
  Future<PushToken?> register() async => null;
  @override
  Stream<PushToken> get tokenRefresh => const Stream.empty();
}
