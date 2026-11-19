import 'package:material_ui/material_ui.dart';

import '../core/errors.dart';
import 'app_state.dart';

/// Forgot password: the server emails a 6-digit code (15 minutes), then the code and a new
/// password sign this phone in. Every other phone of the account is signed out.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, required this.server, this.email});
  final String server;
  final String? email;
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _run(() async {
    if (!_email.text.contains('@')) {
      throw const FormProblem('Type your email address.');
    }
    await AppScope.of(context).requestPasswordReset(widget.server, _email.text);
    setState(() {
      _sent = true;
      _info =
          'If ${_email.text.trim()} has an account, a 6-digit code is on its way. '
          'Check the spam folder too. It works for 15 minutes.';
    });
  });

  Future<void> _reset() => _run(() async {
    if (!RegExp(r'^\d{6}$').hasMatch(_code.text.trim())) {
      throw const FormProblem('The code has 6 digits.');
    }
    if (_password.text.length < 10) {
      throw const FormProblem('The new password needs 10+ characters.');
    }
    final nav = Navigator.of(context);
    await AppScope.of(context)
        .resetPassword(widget.server, _email.text, _code.text, _password.text);
    nav.pop(); // signed in: the app underneath is now the home screen
  });

  @override
  Widget build(BuildContext context) {
    final error = _error == null
        ? null
        : Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          );
    return Scaffold(
      appBar: AppBar(title: const Text('Forgot password')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'We email you a code to choose a new password. Your dogs and their data stay '
            'as they are.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _email,
            enabled: !_sent,
            decoration: const InputDecoration(labelText: 'Email'),
            keyboardType: TextInputType.emailAddress,
          ),
          if (!_sent) ...[
            if (error != null) ...[const SizedBox(height: 12), error],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _send,
              child: const Text('Send code'),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Text(_info!),
            TextField(
              controller: _code,
              decoration: const InputDecoration(labelText: 'Code'),
              keyboardType: TextInputType.number,
              maxLength: 6,
            ),
            TextField(
              controller: _password,
              decoration: const InputDecoration(
                labelText: 'New password (10+ characters)',
              ),
              obscureText: true,
            ),
            if (error != null) ...[const SizedBox(height: 12), error],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _reset,
              child: const Text('Set new password'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _sent = false;
                      _error = null;
                    }),
              child: const Text('Send another code'),
            ),
          ],
        ],
      ),
    );
  }
}
