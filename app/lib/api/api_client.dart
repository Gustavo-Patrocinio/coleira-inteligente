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
  const Dog({
    required this.id,
    required this.name,
    required this.timezone,
    this.sex,
    this.neutered,
    this.breed,
    this.birthDate,
    this.weightKg,
  });
  final int id;
  final String name;
  final String timezone;
  final String? sex; // male | female
  final bool? neutered;
  final String? breed;
  final String? birthDate; // YYYY-MM-DD
  final double? weightKg;

  factory Dog.fromJson(Map<String, dynamic> j) => Dog(
    id: _int(j['id']),
    name: j['name'] as String,
    timezone: j['timezone'] as String,
    sex: j['sex'] as String?,
    neutered: j['neutered'] as bool?,
    breed: j['breed'] as String?,
    birthDate: j['birth_date'] as String?,
    weightKg: j['weight_kg'] == null ? null : double.parse('${j['weight_kg']}'),
  );

  /// Pronouns for app copy: from the profile's sex, "they/their" when not set.
  String get subject => switch (sex) {
    'male' => 'he',
    'female' => 'she',
    _ => 'they',
  };
  String get possessive => switch (sex) {
    'male' => 'his',
    'female' => 'her',
    _ => 'their',
  };

  /// Whole years and months on `today`, e.g. "3 years", "7 months"; null without a birth date.
  String? ageText(DateTime today) {
    final b = birthDate == null ? null : DateTime.tryParse(birthDate!);
    if (b == null) return null;
    var months = (today.year - b.year) * 12 + today.month - b.month;
    if (today.day < b.day) months--;
    if (months < 0) return null;
    if (months < 12) return '$months month${months == 1 ? '' : 's'}';
    final y = months ~/ 12;
    return '$y year${y == 1 ? '' : 's'}';
  }
}

/// What the profile form sends (create or edit). `null` clears a field on edit.
class DogProfile {
  const DogProfile({
    required this.name,
    this.sex,
    this.neutered,
    this.breed,
    this.birthDate,
    this.weightKg,
  });
  final String name;
  final String? sex;
  final bool? neutered;
  final String? breed;
  final String? birthDate;
  final double? weightKg;

  Map<String, Object?> toJson() => {
    'name': name,
    'sex': sex,
    'neutered': neutered,
    'breed': (breed == null || breed!.trim().isEmpty) ? null : breed!.trim(),
    'birth_date': birthDate,
    'weight_kg': weightKg,
  };
}

/// A collar registered to a dog on the server (GET /v1/dogs/:id/devices).
class CollarInfo {
  const CollarInfo({
    required this.deviceId,
    required this.serial,
    this.name,
    this.lastMinute,
    this.batteryPct,
  });
  final int deviceId;
  final String serial;
  final String? name;
  final DateTime? lastMinute;
  final int? batteryPct;

  factory CollarInfo.fromJson(Map<String, dynamic> j) => CollarInfo(
    deviceId: _int(j['id']),
    serial: j['serial'] as String,
    name: j['name'] as String?,
    lastMinute: j['last_minute'] == null
        ? null
        : DateTime.parse(j['last_minute'] as String),
    batteryPct: j['battery_pct'] == null ? null : _int(j['battery_pct']),
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

/// Last night's sleep, estimated from movement (GET /v1/dogs/:id/sleep/:day, backend/src/sleep.ts).
class SleepNight {
  const SleepNight({
    required this.bedtime,
    required this.wakeTime,
    required this.inBedMin,
    required this.restMin,
    required this.awakenings,
    required this.longestRestMin,
    required this.missingMin,
  });
  final DateTime bedtime;
  final DateTime wakeTime;
  final int inBedMin;
  final int restMin;
  final int awakenings;
  final int longestRestMin;
  final int missingMin;

  factory SleepNight.fromJson(Map<String, dynamic> j) => SleepNight(
    bedtime: DateTime.parse(j['bedtime'] as String),
    wakeTime: DateTime.parse(j['wake_time'] as String),
    inBedMin: _int(j['in_bed_min']),
    restMin: _int(j['rest_min']),
    awakenings: _int(j['awakenings']),
    longestRestMin: _int(j['longest_rest_min']),
    missingMin: _int(j['missing_min']),
  );
}

class SleepView {
  const SleepView({
    required this.day,
    required this.nightCoverage,
    required this.napCount,
    required this.napMin,
    this.night,
  });
  final String day;
  final double nightCoverage; // 0..1 of the 20:00–11:00 window with data
  final SleepNight? night; // null when no main rest period was found
  final int napCount;
  final int napMin;

  factory SleepView.fromJson(Map<String, dynamic> j) => SleepView(
    day: j['day'] as String,
    nightCoverage: (j['night_coverage'] as num).toDouble(),
    night: j['night'] == null
        ? null
        : SleepNight.fromJson(j['night'] as Map<String, dynamic>),
    napCount: _int((j['naps'] as Map<String, dynamic>)['count']),
    napMin: _int((j['naps'] as Map<String, dynamic>)['total_min']),
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
    this.name,
    this.consentVersion,
    this.researchOptIn = false,
  });
  final String email;
  final String? name;
  final int? consentVersion;
  final bool researchOptIn;

  factory Me.fromJson(Map<String, dynamic> j) => Me(
    email: j['email'] as String,
    name: j['name'] as String?,
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
    DogProfile profile, {
    String timezone = 'America/Sao_Paulo',
  }) async => Dog.fromJson(
    await _send(
      'POST',
      '/v1/dogs',
      body: {
        for (final e in profile.toJson().entries)
          if (e.value != null) e.key: e.value,
        'timezone': timezone,
      },
    ),
  );

  Future<Dog> updateDog(int dogId, DogProfile profile) async => Dog.fromJson(
    await _send('PATCH', '/v1/dogs/$dogId', body: profile.toJson()),
  );

  /// Removes the dog and all of its minutes, alerts and collars on the server.
  Future<void> deleteDog(int dogId) => _send('DELETE', '/v1/dogs/$dogId');

  /// Registers a collar for a dog; the token is shown once by the backend.
  Future<({int deviceId, String token})> registerDevice(
    int dogId,
    String serial, {
    String? name,
  }) async {
    final j = await _send(
      'POST',
      '/v1/dogs/$dogId/devices',
      body: {'serial': serial, 'name': ?name},
    );
    return (deviceId: _int(j['device_id']), token: j['token'] as String);
  }

  Future<List<CollarInfo>> devices(int dogId) async => [
    for (final d in await _send('GET', '/v1/dogs/$dogId/devices') as List)
      CollarInfo.fromJson(d as Map<String, dynamic>),
  ];

  /// Unpairs a collar: its token stops working; its minutes stay with the dog.
  Future<void> deleteDevice(int deviceId) =>
      _send('DELETE', '/v1/devices/$deviceId');

  Future<DayView> day(int dogId, String day) async =>
      DayView.fromJson(await _send('GET', '/v1/dogs/$dogId/days/$day'));

  Future<SleepView> sleep(int dogId, String day) async =>
      SleepView.fromJson(await _send('GET', '/v1/dogs/$dogId/sleep/$day'));

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

  Future<Me> updateMe({String? name}) async =>
      Me.fromJson(await _send('PATCH', '/v1/me', body: {'name': name}));

  Future<void> changePassword(String current, String next) => _send(
    'POST',
    '/v1/me/password',
    body: {'current_password': current, 'new_password': next},
  );

  Future<Me> putConsent(int version, {required bool researchOptIn}) async =>
      Me.fromJson(
        await _send(
          'PUT',
          '/v1/me/consent',
          body: {'version': version, 'research_opt_in': researchOptIn},
        ),
      );

  /// This phone gets push notifications for new alerts.
  Future<void> putPushToken(String token, String platform) => _send(
    'PUT',
    '/v1/me/push-token',
    body: {'token': token, 'platform': platform},
  );

  Future<void> deletePushToken(String token) =>
      _send('DELETE', '/v1/me/push-token', body: {'token': token});

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
