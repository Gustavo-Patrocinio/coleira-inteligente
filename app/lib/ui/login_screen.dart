import 'package:material_ui/material_ui.dart';

import '../core/errors.dart';
import 'app_state.dart';
import 'forgot_password_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_server.text.isEmpty) _server.text = AppScope.of(context).server;
  }

  Future<void> _go({required bool register}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.of(
        context,
      ).signIn(_server.text, _email.text, _password.text, register: register);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reason = AppScope.of(context).signedOutReason;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),
            Text(
              'Smart Collar',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Sign in to see your dog\'s day. You can also record training sessions '
              'without an account from the Collar tab after signing in.',
            ),
            if (reason != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(reason),
                ),
              ),
            ],
            const SizedBox(height: 24),
            TextField(
              controller: _server,
              decoration: const InputDecoration(
                labelText: 'Server',
                helperText: 'e.g. https://collar.example.com or http://192.168.0.10:3000',
              ),
              keyboardType: TextInputType.url,
            ),
            TextField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'Email'),
              keyboardType: TextInputType.emailAddress,
            ),
            TextField(
              controller: _password,
              decoration: const InputDecoration(
                labelText: 'Password (10+ characters)',
              ),
              obscureText: true,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : () => _go(register: false),
              child: const Text('Sign in'),
            ),
            TextButton(
              onPressed: _busy ? null : () => _go(register: true),
              child: const Text('Create account'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ForgotPasswordScreen(
                          server: _server.text,
                          email: _email.text,
                        ),
                      ),
                    ),
              child: const Text('Forgot password?'),
            ),
          ],
        ),
      ),
    );
  }
}
