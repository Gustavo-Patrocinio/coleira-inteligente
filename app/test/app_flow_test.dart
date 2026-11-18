// Widget test of the main flow with a fake backend: sign in → create dog → Today.
import 'dart:convert';

import 'package:collar_app/api/api_client.dart';
import 'package:collar_app/collar/collar_link.dart';
import 'package:collar_app/collar/summary_cache.dart';
import 'package:collar_app/collar/sync_service.dart';

import 'dart:typed_data';

import 'package:collar_app/main.dart';
import 'package:collar_app/ui/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

class _NoBle implements CollarLink {
  @override
  Stream<FoundCollar> scan({List<String> services = const []}) =>
      const Stream.empty();
  @override
  Future<void> stopScan() async {}
  @override
  Future<int> connect(String collarId) async => 247;
  @override
  Stream<List<int>> rawPackets(String collarId) => const Stream.empty();
  @override
  Future<void> disconnect(String collarId) async {}
}

class _NoSync implements SyncTransport {
  @override
  Future<void> connect(String collarId) async {}
  @override
  Future<void> write(
    String collarId,
    String characteristic,
    Uint8List value,
  ) async {}
  @override
  Stream<List<int>> notifications(String collarId, String characteristic) =>
      const Stream.empty();
  @override
  Future<void> subscribe(String collarId, String characteristic) async {}
  @override
  Future<void> disconnect(String collarId) async {}
}

void main() {
  testWidgets('sign in, create the dog and see Today', (tester) async {
    // a tall phone, so the whole dog form fits without scrolling
    tester.view.physicalSize = const Size(1170, 3600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final dogs = <Map<String, Object>>[];
    Map<String, Object?> me = {
      'email': 'a@b.com',
      'consent_version': null,
      'research_opt_in': false,
    };
    final backend = MockClient((req) async {
      final p = req.url.path;
      if (p == '/v1/auth/login') return http.Response('{"token":"jwt"}', 200);
      if (p == '/v1/me') return http.Response(jsonEncode(me), 200);
      if (p == '/v1/me/consent' && req.method == 'PUT') {
        final b = jsonDecode(req.body) as Map<String, dynamic>;
        me = {
          ...me,
          'consent_version': b['version'],
          'research_opt_in': b['research_opt_in'],
        };
        return http.Response(jsonEncode(me), 200);
      }
      if (p == '/v1/dogs' && req.method == 'GET') {
        return http.Response(jsonEncode(dogs), 200);
      }
      if (p == '/v1/dogs' && req.method == 'POST') {
        final b = jsonDecode(req.body) as Map<String, dynamic>;
        dogs.add({...b.cast<String, Object>(), 'id': '${dogs.length + 1}'});
        return http.Response(jsonEncode(dogs.last), 201);
      }
      if (p.startsWith('/v1/dogs/2/days/')) {
        return http.Response(
          jsonEncode({'day': '2026-11-17', 'totals': {}, 'blocks': []}),
          200,
        );
      }
      if (p.startsWith('/v1/dogs/1/days/')) {
        return http.Response(
          jsonEncode({
            'day': '2026-11-17',
            'timezone': 'America/Sao_Paulo',
            'totals': {
              'still_s': 3000,
              'walking_s': 2400,
              'running_s': 1920,
              'scratching_s': 660,
              'unknown_s': 0,
            },
            'night_wakeups': 2,
            'blocks': [
              {
                'block': '2026-11-17T10:00:00.000Z',
                'minutes': 15,
                'still_s': 0,
                'walking_s': 900,
                'running_s': 0,
                'scratching_s': 0,
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{"error":"not found"}', 404);
    });

    final state = AppState(
      store: MemorySessionStore(),
      apiFactory: (u) => CollarApi(baseUrl: u, client: backend),
      cache: MemorySummaryCache(),
    );
    await state.restore();
    await tester.pumpWidget(
      CollarApp(state: state, link: _NoBle(), sync: _NoSync()),
    );

    expect(find.text('Sign in'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.enterText(
      find.widgetWithText(TextField, 'Password (10+ characters)'),
      'correct horse battery',
    );
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    // onboarding: consent (LGPD) → dog → collar
    expect(find.text('Your data'), findsOneWidget);
    final agree = find.text('Agree and continue');
    await tester.scrollUntilVisible(agree, 200);
    FilledButton button() => tester.widget<FilledButton>(
      find.ancestor(of: agree, matching: find.byType(FilledButton)),
    );
    expect(button().onPressed, isNull); // nothing happens before agreeing
    await tester.tap(find.text('I have read this and agree'));
    await tester.pump();
    await tester.tap(agree);
    await tester.pumpAndSettle();
    expect(me['consent_version'], AppState.consentVersion);
    expect(me['research_opt_in'], false); // opt-in stays off unless ticked

    expect(find.text('What is your dog\'s name?'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Thor');
    await tester.tap(find.text('Male'));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Pair the collar'), findsOneWidget);
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();

    expect(find.text('Thor · today'), findsOneWidget);
    expect(find.text('1h12'), findsOneWidget); // 2400 + 1920 s of exercise
    expect(find.text('woke up 2×'), findsOneWidget);
    expect(find.text('scratched 11 min'), findsOneWidget);
    expect(find.text('compared with his normal in Trends'), findsOneWidget);
    expect(dogs.single['sex'], 'male');

    // a second dog from Profile; every tab follows the selected dog
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a dog'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Mel');
    await tester.tap(find.text('Female'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Weight (optional)'),
      '12,5',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      dogs.last,
      containsPair('weight_kg', 12.5),
    ); // comma typed, number sent
    expect(find.textContaining('Mel'), findsWidgets);

    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(find.text('Mel · today'), findsOneWidget);
    expect(find.text('compared with her normal in Trends'), findsOneWidget);

    await tester.tap(find.text('Mel · today')); // switcher (2 dogs)
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thor').last);
    await tester.pumpAndSettle();
    expect(find.text('Thor · today'), findsOneWidget);
    expect(find.text('scratched 11 min'), findsOneWidget);
  });
}
