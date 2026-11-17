/// Over-the-air firmware update from the app (ADR 0015): find the newest firmware on the
/// project's GitHub releases, upload it over BLE with MCUmgr/SMP, mark it for test and
/// restart the collar. The collar confirms the new image itself after a health check; if
/// it does not start properly, MCUboot goes back to the previous one.
///
/// Unit-tested with a fake collar (test/firmware_update_test.dart).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:universal_ble/universal_ble.dart';

import '../core/smp.dart';

/// The BLE operations an update needs.
abstract class SmpTransport {
  /// Connects and returns the usable ATT MTU.
  Future<int> connect(String collarId);

  /// False when the collar runs the USB-only (UF2) firmware: no SMP service.
  Future<bool> hasSmp(String collarId);
  Future<void> subscribe(String collarId);
  Stream<List<int>> notifications(String collarId);
  Future<void> send(String collarId, Uint8List frame);
  Future<void> disconnect(String collarId);
}

class UniversalBleSmpTransport implements SmpTransport {
  @override
  Future<int> connect(String collarId) async {
    await UniversalBle.connect(collarId, timeout: const Duration(seconds: 20));
    try {
      return await UniversalBle.requestMtu(collarId, 247);
    } catch (_) {
      return 23; // smallest legal MTU: slow but safe
    }
  }

  @override
  Future<bool> hasSmp(String collarId) async {
    final services = await UniversalBle.discoverServices(collarId);
    return services.any((s) => s.uuid.toLowerCase() == smpServiceUuid);
  }

  @override
  Future<void> subscribe(String collarId) =>
      UniversalBle.subscribeNotifications(
        collarId,
        smpServiceUuid,
        smpCharUuid,
      );

  @override
  Stream<List<int>> notifications(String collarId) =>
      UniversalBle.characteristicValueStream(collarId, smpCharUuid);

  @override
  Future<void> send(String collarId, Uint8List frame) => UniversalBle.write(
    collarId,
    smpServiceUuid,
    smpCharUuid,
    frame,
    withoutResponse: true,
  );

  @override
  Future<void> disconnect(String collarId) => UniversalBle.disconnect(collarId);
}

class FirmwareUpdateException implements Exception {
  FirmwareUpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// An SMP session with one connected collar: request → response, one at a time.
class SmpClient {
  SmpClient(
    this.transport,
    this.collarId, {
    this.timeout = const Duration(seconds: 10),
  });

  final SmpTransport transport;
  final String collarId;
  final Duration timeout;
  int _seq = 0;
  StreamSubscription<List<int>>? _sub;
  final _buf = <int>[];
  Completer<SmpFrame>? _pending;

  void start() {
    _sub = transport.notifications(collarId).listen((chunk) {
      _buf.addAll(chunk);
      final n = SmpFrame.expectedLength(_buf);
      if (n == null || _buf.length < n) {
        return; // response split over notifications
      }
      final frame = SmpFrame.decode(_buf.sublist(0, n));
      _buf.removeRange(0, n);
      final p = _pending;
      if (p != null && !p.isCompleted && frame.seq == (_seq - 1) & 0xff) {
        p.complete(frame);
      }
    });
  }

  Future<void> stop() async => _sub?.cancel();

  Future<SmpFrame> request(
    int op,
    int group,
    int command,
    Map<Object?, Object?> payload,
  ) async {
    final frame = SmpFrame(
      op: op,
      group: group,
      command: command,
      seq: _seq++ & 0xff,
      payload: payload,
    );
    final c = _pending = Completer<SmpFrame>();
    await transport.send(collarId, frame.encode());
    final rsp = await c.future.timeout(
      timeout,
      onTimeout: () => throw FirmwareUpdateException(
        'The collar stopped answering. Keep the phone close and try again.',
      ),
    );
    if (rsp.rc != 0) {
      throw FirmwareUpdateException(
        'The collar refused the request (error ${rsp.rc}).',
      );
    }
    return rsp;
  }
}

class FirmwareUpdater {
  FirmwareUpdater(this.transport, {this.timeout = const Duration(seconds: 10)});

  final SmpTransport transport;
  final Duration timeout;

  Future<T> _session<T>(
    String collarId,
    Future<T> Function(SmpClient, int mtu) body,
  ) async {
    final mtu = await transport.connect(collarId);
    try {
      if (!await transport.hasSmp(collarId)) {
        throw FirmwareUpdateException(
          'This collar has the USB-only firmware. Flash the wireless-update version once '
          '(see the flashing guide), then updates work from here.',
        );
      }
      await transport.subscribe(collarId);
      final smp = SmpClient(transport, collarId, timeout: timeout)..start();
      try {
        return await body(smp, mtu);
      } finally {
        await smp.stop();
      }
    } finally {
      await transport.disconnect(collarId);
    }
  }

  /// The images on the collar (slot 0 = running).
  Future<List<ImageSlot>> readState(String collarId) =>
      _session(collarId, (smp, _) async {
        final rsp = await smp.request(
          SmpOp.read,
          SmpGroup.image,
          SmpCmd.imageState,
          {},
        );
        return ImageSlot.fromPayload(rsp.payload);
      });

  /// Upload → mark for test → restart. `onProgress` gets 0..1.
  Future<void> update(
    String collarId,
    McubootImage image, {
    void Function(double)? onProgress,
  }) => _session(collarId, (smp, mtu) async {
    final data = image.bytes;
    final sha = Uint8List.fromList(sha256.convert(data).bytes);
    var off = 0;
    while (off < data.length) {
      final first = off == 0;
      Map<Object?, Object?> payload(Uint8List chunk) => {
        if (first) 'image': 0,
        if (first) 'len': data.length,
        if (first) 'sha': sha,
        'off': off,
        'data': chunk,
      };
      // the whole frame must fit in one write: MTU − 3 bytes of ATT header
      // (+2: the byte-string length grows from 1 to 3 bytes once data ≥ 24 bytes)
      final overhead =
          SmpFrame.headerSize + _cborSize(payload(Uint8List(0))) + 2;
      final room = mtu - 3 - overhead;
      if (room < 16) {
        throw FirmwareUpdateException('Bluetooth MTU too small ($mtu).');
      }
      final end = (off + room).clamp(0, data.length);
      final rsp = await smp.request(
        SmpOp.write,
        SmpGroup.image,
        SmpCmd.imageUpload,
        payload(Uint8List.sublistView(data, off, end)),
      );
      final next = rsp.payload['off'];
      off = next is int ? next : end;
      onProgress?.call(off / data.length);
    }
    await smp.request(SmpOp.write, SmpGroup.image, SmpCmd.imageState, {
      'hash': image.hash,
      'confirm': false,
    });
    await smp.request(SmpOp.write, SmpGroup.os, SmpCmd.osReset, {});
  });
}

int _cborSize(Map<Object?, Object?> m) =>
    SmpFrame(op: 0, group: 0, command: 0, seq: 0, payload: m).encode().length -
    SmpFrame.headerSize;

/// The newest collar firmware published on the project's GitHub releases.
class FirmwareRelease {
  const FirmwareRelease({
    required this.tag,
    required this.url,
    required this.notesUrl,
  });
  final String tag;
  final Uri url;
  final Uri notesUrl;

  String get version => tag.startsWith('v') ? tag.substring(1) : tag;
}

class ReleaseSource {
  ReleaseSource({http.Client? client, this.repo = defaultRepo})
    : _client = client ?? http.Client();

  static const defaultRepo = 'Gustavo-Patrocinio/coleira-inteligente';
  final http.Client _client;
  final String repo;

  /// Newest release (pre-releases included) that has a collar OTA image.
  Future<FirmwareRelease?> latest() async {
    final rsp = await _client.get(
      Uri.parse('https://api.github.com/repos/$repo/releases?per_page=10'),
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (rsp.statusCode != 200) {
      throw FirmwareUpdateException(
        'Could not reach GitHub (${rsp.statusCode}).',
      );
    }
    for (final r in (jsonDecode(rsp.body) as List).whereType<Map>()) {
      if (r['draft'] == true) continue;
      for (final a in (r['assets'] as List? ?? const []).whereType<Map>()) {
        final name = a['name'] as String? ?? '';
        if (name.startsWith('collar-ota-update') && name.endsWith('.bin')) {
          return FirmwareRelease(
            tag: r['tag_name'] as String,
            url: Uri.parse(a['browser_download_url'] as String),
            notesUrl: Uri.parse(r['html_url'] as String),
          );
        }
      }
    }
    return null;
  }

  Future<McubootImage> download(FirmwareRelease r) async {
    final rsp = await _client.get(r.url);
    if (rsp.statusCode != 200) {
      throw FirmwareUpdateException('Download failed (${rsp.statusCode}).');
    }
    return McubootImage.parse(rsp.bodyBytes);
  }
}
