import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collar_app/collar/firmware_update.dart';
import 'package:collar_app/core/cbor.dart';
import 'package:collar_app/core/smp.dart';
import 'package:collar_app/ui/firmware_card.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

/// A minimal MCUboot image: 32-byte header, code, TLV info with the SHA-256.
Uint8List fakeImage(int codeSize, {List<int> version = const [1, 2, 3]}) {
  final hdr = ByteData(32)
    ..setUint32(0, 0x96f3b83d, Endian.little)
    ..setUint16(8, 32, Endian.little)
    ..setUint32(12, codeSize, Endian.little)
    ..setUint8(20, version[0])
    ..setUint8(21, version[1])
    ..setUint16(22, version[2], Endian.little);
  final body = Uint8List.fromList([
    ...hdr.buffer.asUint8List(),
    for (var i = 0; i < codeSize; i++) i * 7 & 0xff,
  ]);
  final hash = sha256.convert(body).bytes;
  final tlv = ByteData(4 + 4 + 32)
    ..setUint16(0, 0x6907, Endian.little)
    ..setUint16(2, 40, Endian.little)
    ..setUint16(4, 0x10, Endian.little)
    ..setUint16(6, 32, Endian.little);
  final t = tlv.buffer.asUint8List()..setRange(8, 40, hash);
  return Uint8List.fromList([...body, ...t]);
}

/// Emulates the collar's MCUmgr: image upload, image state, reset. Splits responses into
/// 20-byte notifications to exercise reassembly.
class FakeCollar implements SmpTransport {
  FakeCollar({this.smp = true, this.mtu = 247});
  final bool smp;
  final int mtu;
  final _out = StreamController<List<int>>.broadcast();
  final received = BytesBuilder();
  int? announcedLen;
  Uint8List? testHash;
  bool reset = false;
  bool connected = false;
  int maxFrame = 0;
  bool failNextUpload = false;

  @override
  Future<int> connect(String collarId) async {
    connected = true;
    return mtu;
  }

  @override
  Future<bool> hasSmp(String collarId) async => smp;
  @override
  Future<void> subscribe(String collarId) async {}
  @override
  Stream<List<int>> notifications(String collarId) => _out.stream;
  @override
  Future<void> disconnect(String collarId) async => connected = false;

  void _reply(SmpFrame req, Map<Object?, Object?> payload) {
    final rsp = SmpFrame(
      op: req.op + 1,
      group: req.group,
      command: req.command,
      seq: req.seq,
      payload: payload,
    ).encode();
    for (var i = 0; i < rsp.length; i += 20) {
      _out.add(rsp.sublist(i, i + 20 > rsp.length ? rsp.length : i + 20));
    }
  }

  @override
  Future<void> send(String collarId, Uint8List frame) async {
    maxFrame = frame.length > maxFrame ? frame.length : maxFrame;
    final req = SmpFrame.decode(frame);
    scheduleMicrotask(() {
      final p = req.payload;
      if (req.group == SmpGroup.image && req.command == SmpCmd.imageUpload) {
        if (failNextUpload) {
          failNextUpload = false;
          return _reply(req, {'rc': 6});
        }
        if (p['off'] == 0) announcedLen = p['len'] as int;
        expect(p['off'], received.length);
        received.add(p['data'] as Uint8List);
        _reply(req, {'rc': 0, 'off': received.length});
      } else if (req.group == SmpGroup.image &&
          req.command == SmpCmd.imageState) {
        if (req.op == SmpOp.write) {
          testHash = p['hash'] as Uint8List;
          expect(p['confirm'], false);
          _reply(req, {'images': []});
        } else {
          _reply(req, {
            'images': [
              {
                'slot': 0,
                'version': '0.1.0',
                'hash': Uint8List(32),
                'active': true,
                'confirmed': true,
              },
            ],
          });
        }
      } else if (req.group == SmpGroup.os && req.command == SmpCmd.osReset) {
        reset = true;
        _reply(req, {});
      }
    });
  }
}

void main() {
  group('CBOR', () {
    test('round trip', () {
      final v = {
        'off': 70000,
        'neg': -3,
        'data': Uint8List.fromList([1, 2, 3]),
        'ok': true,
        'list': [1, 'a', null],
      };
      expect(cborDecode(cborEncode(v)), v);
    });

    test('indefinite-length map, as zcbor writes it', () {
      // {_ "rc": 0, "off": 512}
      final bytes = [
        0xbf,
        0x62,
        0x72,
        0x63,
        0x00,
        0x63,
        0x6f,
        0x66,
        0x66,
        0x19,
        0x02,
        0x00,
        0xff,
      ];
      expect(cborDecode(bytes), {'rc': 0, 'off': 512});
    });
  });

  test('MCUboot image: version and SHA-256 from the TLV area', () {
    final b = fakeImage(1000);
    final img = McubootImage.parse(b);
    expect(img.version, '1.2.3+0');
    expect(img.hash, sha256.convert(b.sublist(0, 1032)).bytes);
    expect(() => McubootImage.parse(Uint8List(64)), throwsFormatException);
  });

  test('version comparison ignores the build number', () {
    expect(compareVersions('0.2.0', '0.10.0'), lessThan(0));
    expect(compareVersions('1.0.0+3', '1.0.0+0'), 0);
    expect(compareVersions('1.0.1', '1.0.0'), greaterThan(0));
  });

  test(
    'update uploads the whole image, marks it for test and resets',
    () async {
      final collar = FakeCollar(mtu: 247);
      final image = McubootImage.parse(fakeImage(5000));
      final progress = <double>[];
      await FirmwareUpdater(collar)
          .update('c1', image, onProgress: progress.add);
      expect(collar.received.toBytes(), image.bytes);
      expect(collar.announcedLen, image.bytes.length);
      expect(collar.testHash, image.hash);
      expect(collar.reset, isTrue);
      expect(collar.maxFrame, lessThanOrEqualTo(247 - 3));
      expect(progress.last, 1.0);
      expect(collar.connected, isFalse);
    },
  );

  test('reads the running image version', () async {
    final slots = await FirmwareUpdater(FakeCollar()).readState('c1');
    expect(slots.single.version, '0.1.0');
    expect(slots.single.active, isTrue);
  });

  test(
    'USB-only firmware gets a clear message, and the link is closed',
    () async {
      final collar = FakeCollar(smp: false);
      await expectLater(
        FirmwareUpdater(collar).readState('c1'),
        throwsA(
          isA<FirmwareUpdateException>().having(
            (e) => e.message,
            'message',
            contains('USB-only'),
          ),
        ),
      );
      expect(collar.connected, isFalse);
    },
  );

  test('an error code from the collar stops the upload', () async {
    final collar = FakeCollar()..failNextUpload = true;
    await expectLater(
      FirmwareUpdater(collar).update('c1', McubootImage.parse(fakeImage(300))),
      throwsA(isA<FirmwareUpdateException>()),
    );
    expect(collar.reset, isFalse);
  });

  test('release source picks the newest release with an OTA image', () async {
    final image = fakeImage(100);
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/releases')) {
        return http.Response(
          jsonEncode([
            {'tag_name': 'v0.3.0', 'draft': true, 'assets': []},
            {
              'tag_name': 'v0.2.0',
              'html_url': 'https://github.com/x/y/releases/v0.2.0',
              'assets': [
                {
                  'name': 'collar.uf2',
                  'browser_download_url': 'https://dl/collar.uf2',
                },
                {
                  'name': 'collar-ota-update-devkey.bin',
                  'browser_download_url': 'https://dl/ota.bin',
                },
              ],
            },
          ]),
          200,
        );
      }
      expect(req.url.toString(), 'https://dl/ota.bin');
      return http.Response.bytes(image, 200);
    });
    final src = ReleaseSource(client: client);
    final r = (await src.latest())!;
    expect(r.version, '0.2.0');
    expect((await src.download(r)).version, '1.2.3+0');
  });

  testWidgets('firmware card: check, confirm, update', (tester) async {
    final collar = FakeCollar();
    final image = fakeImage(2000, version: [0, 2, 0]);
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/releases')) {
        return http.Response(
          jsonEncode([
            {
              'tag_name': 'v0.2.0',
              'html_url': 'https://x',
              'assets': [
                {
                  'name': 'collar-ota-update.bin',
                  'browser_download_url': 'https://dl/ota.bin',
                },
              ],
            },
          ]),
          200,
        );
      }
      return http.Response.bytes(image, 200);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FirmwareCard(
            collarId: 'c1',
            updater: FirmwareUpdater(collar),
            releases: ReleaseSource(client: client),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Check for updates'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('On the collar: 0.1.0'), findsOneWidget);
    await tester.tap(find.text('Update to 0.2.0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('restarting with 0.2.0'), findsOneWidget);
    expect(collar.received.toBytes(), image);
    expect(collar.reset, isTrue);
  });
}
