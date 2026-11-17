import 'package:material_ui/material_ui.dart';

import '../collar/firmware_update.dart';
import '../core/smp.dart';

/// "Collar firmware" card: compares the collar's version with the newest release and
/// updates it over Bluetooth (ADR 0015).
class FirmwareCard extends StatefulWidget {
  const FirmwareCard({
    super.key,
    required this.collarId,
    required this.updater,
    required this.releases,
  });

  final String collarId;
  final FirmwareUpdater updater;
  final ReleaseSource releases;

  @override
  State<FirmwareCard> createState() => _FirmwareCardState();
}

class _FirmwareCardState extends State<FirmwareCard> {
  bool _busy = false;
  String? _collarVersion;
  FirmwareRelease? _latest;
  bool _checked = false;
  double? _progress;
  String? _message;

  bool get _newer =>
      _latest != null &&
      _collarVersion != null &&
      compareVersions(_latest!.version, _collarVersion!) > 0;

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final latest = await widget.releases.latest();
      final slots = await widget.updater.readState(widget.collarId);
      final running =
          slots.where((s) => s.active).firstOrNull ?? slots.firstOrNull;
      setState(() {
        _latest = latest;
        _collarVersion = running?.version;
        _checked = true;
        if (latest == null) _message = 'No firmware release published yet.';
      });
    } catch (e) {
      setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _update() async {
    final r = _latest!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Update to ${r.version}?'),
        content: const Text(
          'Takes 1–3 minutes. Keep the phone next to the collar and this screen open. '
          'The collar keeps its stored minutes, restarts at the end and checks itself: '
          'if the new version does not start properly, it goes back to the current one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _message = 'Downloading…';
    });
    try {
      final image = await widget.releases.download(r);
      setState(() => _message = 'Sending to the collar…');
      await widget.updater.update(
        widget.collarId,
        image,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      setState(() {
        _message =
            'Done. The collar is restarting with ${r.version}; it confirms the new '
            'version by itself after about 30 seconds.';
        _collarVersion = null;
        _checked = false;
      });
    } catch (e) {
      setState(
        () => _message =
            'Update failed: $e. The collar keeps its current version.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Collar firmware', style: text.titleMedium),
            if (_checked && _collarVersion != null)
              Text(
                'On the collar: $_collarVersion'
                '${_latest != null ? ' · newest: ${_latest!.version}' : ''}',
                style: text.bodySmall,
              ),
            if (_checked && _latest != null && !_newer)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Up to date.'),
              ),
            const SizedBox(height: 12),
            if (_progress != null) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 4),
              Text(
                '${((_progress ?? 0) * 100).round()}%',
                style: text.bodySmall,
              ),
            ] else if (_newer)
              FilledButton.icon(
                onPressed: _busy ? null : _update,
                icon: const Icon(Icons.system_update),
                label: Text('Update to ${_latest!.version}'),
              )
            else
              OutlinedButton.icon(
                onPressed: _busy ? null : _check,
                icon: const Icon(Icons.refresh),
                label: Text(_busy ? 'Checking…' : 'Check for updates'),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_message!),
              ),
          ],
        ),
      ),
    );
  }
}
