/// Client for the backend API (backend/README.md). Plain `http`, unit-tested with MockClient.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'ApiException($status): $message';
}

class Dog {
  const Dog({required this.id, required this.name, required this.timezone});
  final int id;
  final String name;
  final String timezone;

  factory Dog.fromJson(Map<String, dynamic> j) => Dog(
    id: _int(j['id']),
    name: j['name'] as String,
    timezone: j['timezone'] as String,
  );
}

/// A 15-minute block of the day (backend: time_bucket of activity_minute).
class DayBlock {
  const DayBlock({
    required this.start,
    required this.minutes,
    required this.secondsByClass,
  });
  final DateTime start;
  final int minutes;
  final Map<String, int> secondsByClass; // still_s, walking_s, ... unknown_s

  factory DayBlock.fromJson(Map<String, dynamic> j) => DayBlock(
    start: DateTime.parse(j['block'] as String),
    minutes: _int(j['minutes']),
    secondsByClass: {
      for (final e in j.entries)
        if (e.key.endsWith('_s')) e.key: _int(e.value),
    },
  );
}

class DayView {
  const DayView({
    required this.day,
    required this.totals,
    required this.blocks,
    this.nightWakeups,
  });
  final String day;
  final Map<String, int> totals;
  final List<DayBlock> blocks;
  final int? nightWakeups;

  factory DayView.fromJson(Map<String, dynamic> j) => DayView(
    day: j['day'] as String,
    totals: (j['totals'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, _int(v)),
    ),
    blocks: [
      for (final b in j['blocks'] as List)
        DayBlock.fromJson(b as Map<String, dynamic>),
    ],
    nightWakeups: j['night_wakeups'] == null ? null : _int(j['night_wakeups']),
  );
}

class DayMetric {
  const DayMetric({
    required this.day,
    required this.coverageMin,
    required this.activeS,
    required this.scratchingS,
    required this.nightWakeups,
  });
  final String day;
  final int coverageMin;
  final int activeS;
  final int scratchingS;
  final int nightWakeups;

  factory DayMetric.fromJson(Map<String, dynamic> j) => DayMetric(
    day: j['day'] as String,
    coverageMin: _int(j['coverage_min']),
    activeS: _int(j['active_s']),
    scratchingS: _int(j['scratching_s']),
    nightWakeups: _int(j['night_wakeups']),
  );
}

class AlertItem {
  const AlertItem({
    required this.id,
    required this.day,
    required this.metric,
    required this.direction,
    required this.value,
    required this.median,
    this.feedback,
  });
  final int id;
  final String day;
  final String metric; // activity | scratching | night_wakeups
  final String direction; // high | low
  final double value;
  final double median;
  final String? feedback;

  factory AlertItem.fromJson(Map<String, dynamic> j) => AlertItem(
    id: _int(j['id']),
    day: j['day'] as String,
    metric: j['metric'] as String,
    direction: j['direction'] as String,
    value: (j['value'] as num).toDouble(),
    median: (j['median'] as num).toDouble(),
    feedback: j['feedback'] as String?,
  );
}

class IngestResult {
  const IngestResult(
    this.received,
    this.inserted,
    this.duplicates,
    this.rejected,
  );
  final int received;
  final int inserted;
  final int duplicates;
  final int rejected;
}

/// The logged-in account (GET /v1/me): which privacy notice version was accepted.
class Me {
  const Me({
    required this.email,
    this.consentVersion,
    this.researchOptIn = false,
  });
  final String email;
  final int? consentVersion;
  final bool researchOptIn;

  factory Me.fromJson(Map<String, dynamic> j) => Me(
    email: j['email'] as String,
    consentVersion: j['consent_version'] == null
        ? null
        : _int(j['consent_version']),
    researchOptIn: j['research_opt_in'] == true,
  );
}

class CollarApi {
  CollarApi({required this.baseUrl, http.Client? client, this.token})
    : _http = client ?? http.Client();

  final Uri baseUrl;
  final http.Client _http;
  String? token;

  Future<String> register(String email, String password) =>
      _auth('register', email, password);
  Future<String> login(String email, String password) =>
      _auth('login', email, password);

  Future<String> _auth(String path, String email, String password) async {
    final j = await _send(
      'POST',
      '/v1/auth/$path',
      body: {'email': email, 'password': password},
      auth: false,
    );
    token = j['token'] as String;
    return token!;
  }

  Future<List<Dog>> dogs() async => [
    for (final d in await _send('GET', '/v1/dogs') as List)
      Dog.fromJson(d as Map<String, dynamic>),
  ];

  Future<Dog> createDog(
    String name, {
    String timezone = 'America/Sao_Paulo',
  }) async => Dog.fromJson(
    await _send('POST', '/v1/dogs', body: {'name': name, 'timezone': timezone}),
  );

  /// Returns the device token (shown once by the backend).
  Future<String> registerDevice(int dogId, String serial) async =>
      (await _send(
            'POST',
            '/v1/dogs/$dogId/devices',
            body: {'serial': serial},
          ))['token']
          as String;

  Future<DayView> day(int dogId, String day) async =>
      DayView.fromJson(await _send('GET', '/v1/dogs/$dogId/days/$day'));

  Future<List<DayMetric>> trends(int dogId, {int days = 30}) async {
    final j = await _send('GET', '/v1/dogs/$dogId/trends?days=$days');
    return [
      for (final d in j['days'] as List)
        DayMetric.fromJson(d as Map<String, dynamic>),
    ];
  }

  Future<List<AlertItem>> alerts(int dogId) async => [
    for (final a in await _send('GET', '/v1/dogs/$dogId/alerts') as List)
      AlertItem.fromJson(a as Map<String, dynamic>),
  ];

  Future<void> alertFeedback(int alertId, {required bool useful}) => _send(
    'POST',
    '/v1/alerts/$alertId/feedback',
    body: {'feedback': useful ? 'useful' : 'false_alarm'},
  );

  Future<Me> me() async => Me.fromJson(await _send('GET', '/v1/me'));

  Future<Me> putConsent(int version, {required bool researchOptIn}) async =>
      Me.fromJson(
        await _send(
          'PUT',
          '/v1/me/consent',
          body: {'version': version, 'research_opt_in': researchOptIn},
        ),
      );

  /// Everything the server holds about the account (LGPD), as pretty JSON.
  Future<String> exportMe() async =>
      const JsonEncoder.withIndent('  ')
          .convert(await _send('GET', '/v1/me/export'));

  /// Deletes the account and all of its data on the server (LGPD).
  Future<void> deleteMe() => _send('DELETE', '/v1/me');

  /// Uploads raw contract 4.7 records with the collar's device token.
  Future<IngestResult> ingest(
    String deviceToken,
    Uint8List records, {
    String via = 'app',
  }) async {
    final j = await _send(
      'POST',
      '/v1/ingest',
      body: {'records': base64Encode(records), 'via': via},
      bearer: deviceToken,
    );
    return IngestResult(
      _int(j['received']),
      _int(j['inserted']),
      _int(j['duplicates']),
      (j['rejected'] as List).length,
    );
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    String? bearer,
  }) async {
    final req = http.Request(method, baseUrl.resolve(path));
    final b = bearer ?? (auth ? token : null);
    if (b != null) req.headers['authorization'] = 'Bearer $b';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await _http.send(req));
    final decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    if (res.statusCode >= 400) {
      final msg = decoded is Map && decoded['message'] != null
          ? decoded['message']
          : (decoded is Map ? decoded['error'] : res.reasonPhrase);
      throw ApiException(res.statusCode, '$msg');
    }
    return decoded;
  }
}

int _int(Object? v) => v is int ? v : int.parse('$v');
