/// Minimal CBOR (RFC 8949) for MCUmgr/SMP messages: unsigned and negative integers, byte
/// and text strings, arrays, maps, booleans and null. Decodes definite and indefinite
/// lengths (Zephyr's zcbor writes indefinite-length maps). No floats or tags: SMP does
/// not use them.
library;

import 'dart:convert';
import 'dart:typed_data';

Uint8List cborEncode(Object? value) {
  final out = BytesBuilder();
  _encode(out, value);
  return out.toBytes();
}

void _head(BytesBuilder out, int major, int n) {
  final m = major << 5;
  if (n < 24) {
    out.addByte(m | n);
  } else if (n < 0x100) {
    out
      ..addByte(m | 24)
      ..addByte(n);
  } else if (n < 0x10000) {
    out
      ..addByte(m | 25)
      ..addByte(n >> 8)
      ..addByte(n & 0xff);
  } else if (n < 0x100000000) {
    out.addByte(m | 26);
    for (var s = 24; s >= 0; s -= 8) {
      out.addByte((n >> s) & 0xff);
    }
  } else {
    out.addByte(m | 27);
    for (var s = 56; s >= 0; s -= 8) {
      out.addByte((n >> s) & 0xff);
    }
  }
}

void _encode(BytesBuilder out, Object? v) {
  switch (v) {
    case null:
      out.addByte(0xf6);
    case bool b:
      out.addByte(b ? 0xf5 : 0xf4);
    case int i when i >= 0:
      _head(out, 0, i);
    case int i:
      _head(out, 1, -1 - i);
    case Uint8List b:
      _head(out, 2, b.length);
      out.add(b);
    case String s:
      final b = utf8.encode(s);
      _head(out, 3, b.length);
      out.add(b);
    case List l:
      _head(out, 4, l.length);
      for (final e in l) {
        _encode(out, e);
      }
    case Map m:
      _head(out, 5, m.length);
      m.forEach((k, e) {
        _encode(out, k);
        _encode(out, e);
      });
    default:
      throw ArgumentError('CBOR: unsupported type ${v.runtimeType}');
  }
}

class CborFormatException implements Exception {
  CborFormatException(this.message);
  final String message;
  @override
  String toString() => 'CborFormatException: $message';
}

Object? cborDecode(List<int> bytes) {
  final r = _Reader(bytes);
  final v = r.item();
  return v;
}

class _Break {
  const _Break();
}

class _Reader {
  _Reader(this.b);
  final List<int> b;
  int i = 0;

  int _byte() {
    if (i >= b.length) throw CborFormatException('truncated');
    return b[i++];
  }

  int _arg(int info) {
    if (info < 24) return info;
    final n = switch (info) {
      24 => 1,
      25 => 2,
      26 => 4,
      27 => 8,
      _ => throw CborFormatException('bad length $info'),
    };
    var v = 0;
    for (var k = 0; k < n; k++) {
      v = (v << 8) | _byte();
    }
    return v;
  }

  Uint8List _bytes(int n) {
    if (i + n > b.length) throw CborFormatException('truncated');
    final out = Uint8List.fromList(b.sublist(i, i + n));
    i += n;
    return out;
  }

  Object? item() {
    final v = _item();
    if (v is _Break) throw CborFormatException('unexpected break');
    return v;
  }

  Object? _item() {
    final first = _byte();
    final major = first >> 5, info = first & 0x1f;
    if (info == 31) return _indefinite(major);
    switch (major) {
      case 0:
        return _arg(info);
      case 1:
        return -1 - _arg(info);
      case 2:
        return _bytes(_arg(info));
      case 3:
        return utf8.decode(_bytes(_arg(info)));
      case 4:
        return [for (var n = _arg(info); n > 0; n--) item()];
      case 5:
        final m = <Object?, Object?>{};
        for (var n = _arg(info); n > 0; n--) {
          final k = item();
          m[k] = item();
        }
        return m;
      case 7:
        return switch (info) {
          20 => false,
          21 => true,
          22 || 23 => null,
          _ => throw CborFormatException('unsupported simple/float $info'),
        };
      default:
        throw CborFormatException('unsupported major type $major');
    }
  }

  Object? _indefinite(int major) {
    switch (major) {
      case 7:
        return const _Break();
      case 2 || 3:
        final out = BytesBuilder();
        while (true) {
          final chunk = _item();
          if (chunk is _Break) break;
          out.add(chunk is String ? utf8.encode(chunk) : chunk as List<int>);
        }
        return major == 2 ? out.toBytes() : utf8.decode(out.toBytes());
      case 4:
        final l = <Object?>[];
        while (true) {
          final e = _item();
          if (e is _Break) return l;
          l.add(e);
        }
      case 5:
        final m = <Object?, Object?>{};
        while (true) {
          final k = _item();
          if (k is _Break) return m;
          m[k] = item();
        }
      default:
        throw CborFormatException('indefinite length on major type $major');
    }
  }
}
