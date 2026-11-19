/// Turns exceptions into sentences an owner can act on, instead of
/// "SocketException: Connection refused (OS Error: ...)".
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../api/api_client.dart';

/// A problem with what the user typed, shown as is.
class FormProblem implements Exception {
  const FormProblem(this.message);
  final String message;
  @override
  String toString() => message;
}

String friendlyError(Object e) {
  if (e is FormProblem) return e.message;
  if (e is ApiException) {
    // 401 with the server's own words ("invalid email or password") is shown as is
    if (e.status == 401 && e.message == 'unauthorized') {
      return 'Your session ended. Sign in again.';
    }
    if (e.status == 429) {
      return 'Too many attempts. Wait a few minutes and try again.';
    }
    if (e.status >= 500 && e.status != 501) {
      return 'The server had a problem (${e.status}). Try again in a moment.';
    }
    final m = e.message.trim();
    return m.isEmpty ? 'Request failed (${e.status}).' : _sentence(m);
  }
  if (e is HandshakeException || e is TlsException) {
    return 'Could not open a secure connection. Check the server address.';
  }
  if (e is SocketException ||
      e is http.ClientException ||
      e is TimeoutException) {
    return 'Could not reach the server. Check the address and your internet connection.';
  }
  if (e is FormatException) {
    return 'The server answered something unexpected. Is the address right?';
  }
  return 'Something went wrong ($e).';
}

String _sentence(String m) {
  final s = m[0].toUpperCase() + m.substring(1);
  return s.endsWith('.') ? s : '$s.';
}
