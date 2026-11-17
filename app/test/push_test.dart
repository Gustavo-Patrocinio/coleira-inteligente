// The app hands the phone's push token to the server only after consent, keeps it updated
// when FCM rotates it, and withdraws it on sign-out.
import 'dart:async';
import 'dart:convert';

import 'package:collar_app/api/api_client.dart';
import 'package:collar_app/collar/summary_cache.dart';
import 'package:collar_app/core/push.dart';
import 'package:collar_app/ui/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakePush implements PushService {
  int asked = 0;
  final refresh = StreamController<PushToken>.broadcast();
  @override
  Future<PushToken?> register() async {
    asked++;
    return const PushToken('fcm-token-1', 'ios');
  }

  @override
  Stream<PushToken> get tokenRefresh => refresh.stream;
}

void main() {
  test('push token: after consent, refreshed, removed on sign-out', () async {
    final calls = <String>[];
    var consent = <String, dynamic>{
      'email': 'a@b.com',
      'consent_version': null,
    };
    final backend = MockClient((req) async {
      final p = req.url.path;
      if (p.startsWith('/v1/me/push-token')) {
        calls.add('${req.method} ${jsonDecode(req.body)['token']}');
        return http.Response('', 204);
      }
      if (p == '/v1/auth/login') return http.Response('{"token":"jwt"}', 200);
      if (p == '/v1/me') return http.Response(jsonEncode(consent), 200);
      if (p == '/v1/me/consent') {
        consent = {...consent, 'consent_version': 1};
        return http.Response(jsonEncode(consent), 200);
      }
      if (p == '/v1/dogs') return http.Response('[]', 200);
      return http.Response('{"error":"not found"}', 404);
    });
    final push = _FakePush();
    final state = AppState(
      store: MemorySessionStore(),
      apiFactory: (u) => CollarApi(baseUrl: u, client: backend),
      cache: MemorySummaryCache(),
      push: push,
    );
    await state.restore();
    await state.signIn(
      'http://server',
      'a@b.com',
      'correct horse battery',
      register: false,
    );
    await pumpEventQueue();
    expect(push.asked, 0); // no permission prompt before the consent screen

    await state.acceptConsent(researchOptIn: false);
    await pumpEventQueue();
    expect(calls, ['PUT fcm-token-1']);

    push.refresh.add(const PushToken('fcm-token-2', 'ios'));
    await pumpEventQueue();
    expect(calls.last, 'PUT fcm-token-2');

    await state.signOut();
    expect(calls.last, 'DELETE fcm-token-2');
  });
}
