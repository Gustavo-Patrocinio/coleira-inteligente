import 'dart:convert';
import 'dart:io';

import 'package:collar_app/collection/session_recorder.dart';
import 'package:collar_app/core/raw_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('session id format matches the PC recorder', () {
    expect(
      sessionIdFor(DateTime(2026, 11, 27, 9, 5), 'Thor Jr'),
      '20261127-0905-thor-jr',
    );
  });

  test(
    'writes contract 4.5 CSV and meta.json with the video start time',
    () async {
      final tmp = await Directory.systemTemp.createTemp('session');
      var clock = 1000000;
      final rec = SessionRecorder(
        dir: Directory('${tmp.path}/s1'),
        dogId: 'thor',
        deviceId: 'AA:BB',
        now: () => clock,
      );
      await rec.start();
      final s = [
        for (var i = 0; i < 10; i++) [i, 0, 2048, 0, 0, i],
      ];

      clock += 100;
      rec.markVideoStart();
      for (final seq in [65534, 65535, 1]) {
        // seq 0 lost after the wrap
        clock += 200;
        rec.addPacket(packRawPacket(seq, 5000 + seq, s));
      }
      rec.addPacket([1, 2, 3]); // garbage
      await rec.stop(videoFile: 'video.mov', notes: 'test');

      final lines = await rec.csvFile.readAsLines();
      expect(lines.first, 'phone_ts_ms,device_ms,seq,ax,ay,az,gx,gy,gz');
      expect(lines, hasLength(1 + 30));
      expect(lines[1], '1000300,70534,65534,0,0,2048,0,0,0');

      final meta =
          jsonDecode(await rec.metaFile.readAsString()) as Map<String, dynamic>;
      expect(meta['session_id'], 's1');
      expect(meta['start_phone_ts'], 1000000);
      expect(meta['video_start_phone_ts_ms'], 1000100);
      expect(meta['video_file'], 'video.mov');
      expect(meta['accel_range'], 16);
      expect(meta['sync_taps'], isEmpty);
      expect(meta['notes'], contains('packet loss 25.00%'));
      expect(meta['notes'], contains('1 bad packets'));
      expect(rec.loss.expected, 4);
      await tmp.delete(recursive: true);
    },
  );
}
