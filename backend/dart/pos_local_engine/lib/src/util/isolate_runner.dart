/// Runs [body] on a background isolate so the UI stays responsive during
/// expensive PBKDF2 iterations. On platforms without isolates (the web build
/// and unit-test hosts) the generic stub below resolves to an inline call
/// instead.
Future<T> runIsolated<T>(Future<T> Function() body) async {
  // Stub implementation for web/test; native version lives in
  // isolate_runner_native.dart (guarded by dart.library.io).
  return body();
}