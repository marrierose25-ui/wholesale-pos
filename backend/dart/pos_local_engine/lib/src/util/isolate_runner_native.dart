import 'dart:isolate';

/// Runs [body] on a background isolate so the UI stays responsive during
/// expensive PBKDF2 iterations. On platforms without isolates (the web build
/// and unit-test hosts) the generic stub in isolate_runner.dart is used.
Future<T> runIsolated<T>(Future<T> Function() body) async {
  return Isolate.run(body);
}