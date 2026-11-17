/// MCUmgr's Simple Management Protocol (SMP) over BLE, the part a firmware update needs
/// (ADR 0015), and the MCUboot image format.
///
/// Frame: 8-byte header (op, flags, length BE, group BE, seq, command) + CBOR payload.
library;

import 'dart:typed_data';

import 'cbor.dart';

const smpServiceUuid = '8d53dc1d-1db7-4cd3-868b-8a527460aa84';
const smpCharUuid = 'da2e7828-fbce-4e01-ae9e-261174997c48';

class SmpOp {
  static const read = 0, readRsp = 1, write = 2, writeRsp = 3;
}

class SmpGroup {
  static const os = 0, image = 1;
}

class SmpCmd {
  static const osReset = 5, imageState = 0, imageUpload = 1;
}

class SmpFrame {
  const SmpFrame({
    required this.op,
    required this.group,
    required this.command,
    required this.seq,
    required this.payload,
  });

  final int op;
  final int group;
  final int command;
  final int seq;
  final Map<Object?, Object?> payload;

  static const headerSize = 8;

  Uint8List encode() {
    final body = cborEncode(payload);
    return Uint8List.fromList([
      op & 0x07,
      0,
      body.length >> 8,
      body.length & 0xff,
      group >> 8,
      group & 0xff,
      seq & 0xff,
      command,
      ...body,
    ]);
  }

  /// Total frame length announced by a header (to reassemble split notifications).
  static int? expectedLength(List<int> bytes) => bytes.length < headerSize
      ? null
      : headerSize + (bytes[2] << 8 | bytes[3]);

  static SmpFrame decode(List<int> bytes) {
    final n = expectedLength(bytes);
    if (n == null || bytes.length < n) {
      throw const FormatException('SMP: incomplete frame');
    }
    final body = cborDecode(bytes.sublist(headerSize, n));
    return SmpFrame(
      op: bytes[0] & 0x07,
      group: bytes[4] << 8 | bytes[5],
      command: bytes[7],
      seq: bytes[6],
      payload: body is Map ? body : const {},
    );
  }

  /// SMP v1 `rc` or v2 `err.rc`; 0 (or absent) means success.
  int get rc {
    final rc = payload['rc'];
    if (rc is int) return rc;
    final err = payload['err'];
    if (err is Map && err['rc'] is int) return err['rc'] as int;
    return 0;
  }
}

/// An MCUboot image (`zephyr.signed.bin`): header, code, TLV area with the SHA-256 that
/// MCUmgr uses to name the image.
class McubootImage {
  McubootImage._(this.bytes, this.version, this.hash);

  final Uint8List bytes;
  final String version;
  final Uint8List hash;

  static const _magic = 0x96f3b83d;
  static const _tlvInfo = 0x6907, _tlvProtInfo = 0x6908, _tlvSha256 = 0x10;

  static McubootImage parse(Uint8List b) {
    if (b.length < 32) throw const FormatException('not an MCUboot image');
    final d = ByteData.sublistView(b);
    if (d.getUint32(0, Endian.little) != _magic) {
      throw const FormatException('not an MCUboot image (bad magic)');
    }
    final hdrSize = d.getUint16(8, Endian.little);
    final imgSize = d.getUint32(12, Endian.little);
    final version =
        '${b[20]}.${b[21]}.${d.getUint16(22, Endian.little)}'
        '+${d.getUint32(24, Endian.little)}';
    var off = hdrSize + imgSize;
    if (off + 4 <= b.length &&
        d.getUint16(off, Endian.little) == _tlvProtInfo) {
      off += d.getUint16(off + 2, Endian.little);
    }
    if (off + 4 > b.length || d.getUint16(off, Endian.little) != _tlvInfo) {
      throw const FormatException('MCUboot image without TLV area');
    }
    final end = off + d.getUint16(off + 2, Endian.little);
    off += 4;
    while (off + 4 <= end && end <= b.length) {
      final type = d.getUint16(off, Endian.little);
      final len = d.getUint16(off + 2, Endian.little);
      if (type == _tlvSha256 && len == 32) {
        return McubootImage._(b, version, b.sublist(off + 4, off + 36));
      }
      off += 4 + len;
    }
    throw const FormatException('MCUboot image without SHA-256');
  }
}

/// One slot of `image state read`.
class ImageSlot {
  const ImageSlot({
    required this.slot,
    required this.version,
    required this.hash,
    required this.active,
    required this.confirmed,
    required this.pending,
  });

  final int slot;
  final String version;
  final Uint8List hash;
  final bool active;
  final bool confirmed;
  final bool pending;

  static List<ImageSlot> fromPayload(Map<Object?, Object?> p) {
    final images = p['images'];
    if (images is! List) return const [];
    return [
      for (final i in images.whereType<Map>())
        ImageSlot(
          slot: (i['slot'] as int?) ?? 0,
          version: (i['version'] as String?) ?? '?',
          hash: (i['hash'] as Uint8List?) ?? Uint8List(0),
          active: i['active'] == true,
          confirmed: i['confirmed'] == true,
          pending: i['pending'] == true,
        ),
    ];
  }
}

/// "1.2.3+4" vs "1.2.10+0" → negative, zero, positive (build number ignored).
int compareVersions(String a, String b) {
  List<int> parts(String v) =>
      v.split('+').first.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final pa = parts(a), pb = parts(b);
  for (var k = 0; k < 3; k++) {
    final x = k < pa.length ? pa[k] : 0, y = k < pb.length ? pb[k] : 0;
    if (x != y) return x - y;
  }
  return 0;
}
