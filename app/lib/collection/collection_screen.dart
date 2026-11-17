/// Collection mode (Phase 1, docs/protocols/collection.md): connect to the collar logger,
/// film the dog and record imu.csv + meta.json at the same time, then share the session.
library;

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../collar/collar_link.dart';
import 'session_recorder.dart';

class CollectionScreen extends StatefulWidget {
  const CollectionScreen({super.key, required this.link});
  final CollarLink link;
  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  final _dog = TextEditingController();
  final List<FoundCollar> _found = [];
  StreamSubscription<FoundCollar>? _scanSub;
  StreamSubscription<List<int>>? _packetSub;
  FoundCollar? _collar;
  int _mtu = 0;
  CameraController? _camera;
  SessionRecorder? _rec;
  Directory? _lastSession;
  Timer? _ticker;
  String? _status;

  @override
  void dispose() {
    _ticker?.cancel();
    _scanSub?.cancel();
    _packetSub?.cancel();
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _found.clear();
      _status = 'Scanning for the collar…';
    });
    await _scanSub?.cancel();
    _scanSub = widget.link.scan().listen((c) {
      if (_found.every((f) => f.id != c.id)) setState(() => _found.add(c));
    });
    Future.delayed(const Duration(seconds: 15), () async {
      await widget.link.stopScan();
      if (mounted) {
        setState(
          () => _status = _found.isEmpty
              ? 'No collar found. Is it on and nearby?'
              : null,
        );
      }
    });
  }

  Future<void> _connect(FoundCollar c) async {
    await widget.link.stopScan();
    setState(() => _status = 'Connecting…');
    try {
      final mtu = await widget.link.connect(c.id);
      final cams = await availableCameras();
      final back = cams.firstWhere(
        (x) => x.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final cam = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await cam.initialize();
      setState(() {
        _collar = c;
        _mtu = mtu;
        _camera = cam;
        _status = null;
      });
    } catch (e) {
      setState(() => _status = 'Could not connect: $e');
    }
  }

  Future<void> _start() async {
    final collar = _collar!;
    final dogId = _dog.text.trim().isEmpty ? 'dog' : _dog.text.trim();
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(
      '${root.path}/sessions/${sessionIdFor(DateTime.now(), dogId)}',
    );
    final rec = SessionRecorder(dir: dir, dogId: dogId, deviceId: collar.id);
    await rec.start();
    _packetSub = widget.link.rawPackets(collar.id).listen(rec.addPacket);
    await _camera!.startVideoRecording();
    rec.markVideoStart();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
    setState(() => _rec = rec);
  }

  Future<void> _stop() async {
    final rec = _rec!;
    _ticker?.cancel();
    final video = await _camera!.stopVideoRecording();
    await _packetSub?.cancel();
    final ext = video.path.contains('.')
        ? video.path.substring(video.path.lastIndexOf('.'))
        : '.mp4';
    final videoName = 'video$ext';
    await File(video.path).copy('${rec.dir.path}/$videoName');
    await rec.stop(videoFile: videoName);
    setState(() {
      _lastSession = rec.dir;
      _rec = null;
    });
  }

  Future<void> _share() async {
    final files = _lastSession!
        .listSync()
        .whereType<File>()
        .map((f) => XFile(f.path))
        .toList();
    await SharePlus.instance.share(
      ShareParams(files: files, subject: 'Collar session'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rec = _rec;
    return Scaffold(
      appBar: AppBar(title: const Text('Record a session')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Film the dog while the collar records. Tap the case 3 times in front of the camera '
            'at the start and at the end (sync taps).',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dog,
            enabled: rec == null,
            decoration: const InputDecoration(
              labelText: 'Dog code (no owner names)',
              hintText: 'thor',
            ),
          ),
          const SizedBox(height: 12),
          if (_collar == null) ...[
            FilledButton.icon(
              onPressed: _scan,
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Find collar'),
            ),
            for (final c in _found)
              ListTile(
                leading: const Icon(Icons.sensors),
                title: Text(c.name),
                subtitle: Text(
                  '${c.id}${c.rssi != null ? ' · ${c.rssi} dBm' : ''}',
                ),
                onTap: () => _connect(c),
              ),
          ] else ...[
            Text(
              'Connected to ${_collar!.name} · MTU ${_mtu == 0 ? 'auto' : _mtu}',
            ),
            const SizedBox(height: 8),
            if (_camera != null)
              AspectRatio(
                aspectRatio: 3 / 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CameraPreview(_camera!),
                ),
              ),
            const SizedBox(height: 8),
            if (rec != null)
              Text(
                'Recording · packets ${rec.loss.received}/${rec.loss.expected} · '
                'loss ${(rec.loss.loss * 100).toStringAsFixed(2)}% (target < 1%)',
              ),
            const SizedBox(height: 8),
            rec == null
                ? FilledButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.fiber_manual_record),
                    label: const Text('Start recording'),
                  )
                : FilledButton.icon(
                    onPressed: _stop,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFC92A2A),
                    ),
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
          ],
          if (_lastSession != null) ...[
            const SizedBox(height: 12),
            Text(
              'Saved ${_lastSession!.uri.pathSegments.where((s) => s.isNotEmpty).last}. '
              'Share it to your computer and open it in the labeler.',
            ),
            OutlinedButton.icon(
              onPressed: _share,
              icon: const Icon(Icons.ios_share),
              label: const Text('Share session'),
            ),
          ],
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_status!),
            ),
        ],
      ),
    );
  }
}
