import 'dart:convert';
import 'dart:typed_data';

import 'package:collar_app/api/alert_text.dart';
import 'package:collar_app/api/api_client.dart';
import 'package:collar_app/api/day_summary.dart';
import 'package:collar_app/core/contracts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('CollarApi', () {
    test('logs in, keeps the token and sends it', () async {
      final seen = <http.Request>[];
      final api = CollarApi(
        baseUrl: Uri.parse('http://server:3000'),
        client: MockClient((req) async {
          seen.add(req);
          if (req.url.path == '/v1/auth/login') {
            return http.Response('{"token":"jwt1"}', 200);
          }
          return http.Response(
            '[{"id":"7","name":"Thor","timezone":"America/Sao_Paulo"}]',
            200,
          );
        }),
      );
      await api.login('a@b.com', 'correct horse battery');
      final dogs = await api.dogs();
      expect(dogs.single.id, 7); // bigint ids arrive as strings from pg
      expect(seen.last.headers['authorization'], 'Bearer jwt1');
      expect(jsonDecode(seen.first.body), {
        'email': 'a@b.com',
        'password': 'correct horse battery',
      });
    });

    test('ingest sends base64 records with the device token', () async {
      late http.Request sent;
      final api = CollarApi(
        baseUrl: Uri.parse('http://server:3000'),
        token: 'user-jwt',
        client: MockClient((req) async {
          sent = req;
          return http.Response(
            '{"received":2,"inserted":1,"duplicates":1,"rejected":[]}',
            200,
          );
        }),
      );
      final r = await api.ingest(
        'dev_abc',
        Uint8List.fromList(List.filled(30, 1)),
      );
      expect(sent.headers['authorization'], 'Bearer dev_abc');
      expect(jsonDecode(sent.body)['via'], 'app');
      expect(
        base64Decode(jsonDecode(sent.body)['records'] as String),
        hasLength(30),
      );
      expect([r.inserted, r.duplicates], [1, 1]);
    });

    test(
      'turns validation errors into ApiException with the server message',
      () async {
        final api = CollarApi(
          baseUrl: Uri.parse('http://server:3000'),
          client: MockClient(
            (_) async => http.Response(
              '{"error":"Bad Request","message":"body/password too short"}',
              400,
            ),
          ),
        );
        expect(
          () => api.register('a@b.com', 'x'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.message,
              'message',
              'body/password too short',
            ),
          ),
        );
      },
    );
  });

  group('day summary', () {
    DayBlock block(String startUtc, Map<String, int> s) => DayBlock(
      start: DateTime.parse(startUtc),
      minutes: 15,
      secondsByClass: s,
    );

    test(
      'dominant behavior: short events win when they add up to a minute',
      () {
        expect(
          dominantBehavior(
            block('2026-10-01T12:00:00Z', {'still_s': 800, 'walking_s': 100}),
          ),
          Behavior.still,
        );
        expect(
          dominantBehavior(
            block('2026-10-01T12:00:00Z', {'still_s': 800, 'scratching_s': 60}),
          ),
          Behavior.scratching,
        );
        expect(
          dominantBehavior(
            block('2026-10-01T12:00:00Z', {'still_s': 800, 'shaking_s': 20}),
          ),
          Behavior.still,
        );
        expect(
          dominantBehavior(block('2026-10-01T12:00:00Z', {})),
          Behavior.unknown,
        );
      },
    );

    test('timeline slots use the local time of each block', () {
      final day = DayView(
        day: '2026-10-01',
        totals: const {},
        blocks: [
          block('2026-10-01T03:00:00Z', {
            'still_s': 900,
          }), // 00:00 local (UTC−3)
          block('2026-10-01T12:15:00Z', {'walking_s': 900}), // 09:15 local
        ],
      );
      final slots = timelineSlots(day, const Duration(hours: -3));
      expect(slots[0], Behavior.still);
      expect(slots[9 * 4 + 1], Behavior.walking);
      expect(slots.whereType<Behavior>(), hasLength(2));
    });

    test('durations', () {
      expect(formatDuration(150), '3 min');
      expect(formatDuration(4320), '1h12');
    });
  });

  test('alert copy is plain language and compares with the dog\'s normal', () {
    const a = AlertItem(
      id: 1,
      day: '2026-09-22',
      metric: 'scratching',
      direction: 'high',
      value: 900,
      median: 180,
    );
    final c = alertCopy(a, 'Thor');
    expect(c.title, 'Scratched 5.0× more than usual');
    expect(c.body, contains('15 min'));
    expect(c.body, contains('3 min'));
    const low = AlertItem(
      id: 2,
      day: '2026-09-22',
      metric: 'activity',
      direction: 'low',
      value: 3600,
      median: 10800,
    );
    expect(alertCopy(low, 'Thor').title, 'Activity 67% below normal');
  });
}
