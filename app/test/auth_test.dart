// Accounts: forgot password, password change keeping this phone signed in, being signed
// out when the server rejects the token, and readable error messages.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collar_app/api/api_client.dart';
import 'package:collar_app/collar/collar_link.dart';
import 'package:collar_app/collar/summary_cache.dart';
import 'package:collar_app/collar/sync_service.dart';
import 'package:collar_app/core/errors.dart';
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
  Future<void> write(String c, String ch, Uint8List v) async {}
  @override
  Stream<List<int>> notifications(String c, String ch) => const Stream.empty();
  @override
  Future<void> subscribe(String c, String ch) async {}
  @override
  Future<void> disconnect(String collarId) async {}
}

/// A tiny account server: one user, one dog, tokens that can be revoked.
class _Server {
  String password = 'correct horse battery';
  String? pendingCode;
  bool canEmail = true;
  int version = 0;
  final requests = <http.Request>[];

  String _token() => 'jwt-v$version';
  bool _authorized(http.Request r) =>
      r.headers['authorization'] == 'Bearer ${_token()}';

  late final client = MockClient((req) async {
    requests.add(req);
    final p = req.url.path;
    final body = req.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(req.body) as Map<String, dynamic>;
    http.Response json(Object o, [int status = 200]) =>
        http.Response(jsonEncode(o), status);
    switch (p) {
      case '/v1/auth/login':
        return body['password'] == password
            ? json({'token': _token()})
            : json({'error': 'invalid email or password'}, 401);
      case '/v1/auth/forgot':
        if (!canEmail) {
          return json({
            'error': 'this server cannot send email; ask whoever runs it to reset your password',
          }, 501);
        }
        pendingCode = '123456';
        return json({'ok': true}, 202);
      case '/v1/auth/reset':
        if (body['code'] != pendingCode) {
          return json({'error': 'invalid or expired code'}, 400);
        }
        password = body['new_password'] as String;
        version++;
        pendingCode = null;
        return json({'token': _token()});
    }
    if (!_authorized(req)) return json({'error': 'unauthorized'}, 401);
    switch (p) {
      case '/v1/me':
        return json({'email': 'a@b.com', 'consent_version': 1});
      case '/v1/me/password':
        if (body['current_password'] != password) {
          return json({'error': 'current password is wrong'}, 403);
        }
        password = body['new_password'] as String;
        version++;
        return json({'token': _token()});
      case '/v1/dogs':
        return json([
          {'id': '1', 'name': 'Thor', 'timezone': 'America/Sao_Paulo'},
        ]);
    }
    if (p.startsWith('/v1/dogs/1/')) {
      return json({'day': '2026-11-19', 'totals': {}, 'blocks': []});
    }
    return json({'error': 'not found'}, 404);
  });
}

AppState _state(_Server server, {SessionStore? store}) => AppState(
  store: store ?? MemorySessionStore(),
  apiFactory: (u) => CollarApi(baseUrl: u, client: server.client),
  cache: MemorySummaryCache(),
);

void main() {
  test(
    'password change keeps this phone signed in with the new token',
    () async {
      final server = _Server();
      final store = MemorySessionStore();
      final s = _state(server, store: store);
      await s.restore();
      await s.signIn('http://srv', 'a@b.com', server.password, register: false);
      expect(await store.read('token'), 'jwt-v0');

      await s.changePassword('correct horse battery', 'another long one');
      expect(s.api!.token, 'jwt-v1');
      expect(await store.read('token'), 'jwt-v1');
      expect(s.loggedIn, isTrue);
      await s.api!.me(); // still works
    },
  );

  test('a token the server rejects signs the phone out, saying why', () async {
    final server = _Server();
    final s = _state(server);
    await s.restore();
    await s.signIn('http://srv', 'a@b.com', server.password, register: false);
    server.version++; // the password changed on another phone

    await expectLater(s.api!.me(), throwsA(isA<ApiException>()));
    await pumpEventQueue();
    expect(s.loggedIn, isFalse);
    expect(s.signedOutReason, contains('password changed on another phone'));

    // signing in again clears the reason
    await s.signIn('http://srv', 'a@b.com', server.password, register: false);
    expect(s.signedOutReason, isNull);
  });

  test(
    'a wrong password or a retired collar does not sign anyone out',
    () async {
      final server = _Server();
      final s = _state(server);
      await s.restore();
      await s.signIn('http://srv', 'a@b.com', server.password, register: false);
      // a collar token the server no longer accepts
      await expectLater(
        s.api!.ingest('dev_retired', Uint8List(15)),
        throwsA(isA<ApiException>()),
      );
      await pumpEventQueue();
      expect(s.loggedIn, isTrue);
    },
  );

  testWidgets('forgot password: code by email, new password, signed in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 3600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final server = _Server();
    final s = _state(server);
    await s.restore();
    await tester.pumpWidget(
      CollarApp(state: s, link: _NoBle(), sync: _NoSync()),
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Server'),
      'https://collar.example.com',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(find.text('Forgot password'), findsOneWidget);
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();
    expect(server.requests.last.url.host, 'collar.example.com');
    expect(find.textContaining('a 6-digit code is on its way'), findsOneWidget);

    final code = find.widgetWithText(TextField, 'Code');
    final pass = find.widgetWithText(
      TextField,
      'New password (10+ characters)',
    );
    await tester.enterText(code, '12345');
    await tester.enterText(pass, 'a brand new password');
    await tester.tap(find.text('Set new password'));
    await tester.pumpAndSettle();
    expect(find.text('The code has 6 digits.'), findsOneWidget);

    await tester.enterText(code, '999999');
    await tester.tap(find.text('Set new password'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid or expired code.'), findsOneWidget);

    await tester.enterText(code, '123456');
    await tester.tap(find.text('Set new password'));
    await tester.pumpAndSettle();
    expect(s.loggedIn, isTrue);
    expect(server.password, 'a brand new password');
    expect(find.text('Forgot password'), findsNothing); // back on the app
    expect(find.text('Today'), findsWidgets);
  });

  testWidgets('a server without email says so', (tester) async {
    final server = _Server()..canEmail = false;
    final s = _state(server);
    await s.restore();
    await tester.pumpWidget(
      CollarApp(state: s, link: _NoBle(), sync: _NoSync()),
    );
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('This server cannot send email'),
      findsOneWidget,
    );
  });

  test('error messages an owner can act on', () {
    expect(
      friendlyError(const SocketException('Connection refused')),
      startsWith('Could not reach the server'),
    );
    expect(
      friendlyError(http.ClientException('Failed host lookup')),
      startsWith('Could not reach the server'),
    );
    expect(
      friendlyError(ApiException(401, 'invalid email or password')),
      'Invalid email or password.',
    );
    expect(
      friendlyError(ApiException(401, 'unauthorized')),
      'Your session ended. Sign in again.',
    );
    expect(
      friendlyError(ApiException(409, 'email already registered')),
      'Email already registered.',
    );
    expect(friendlyError(ApiException(429, 'x')), startsWith('Too many'));
    expect(friendlyError(ApiException(502, 'x')), contains('(502)'));
    expect(friendlyError(const FormProblem('Type it.')), 'Type it.');
  });
}
