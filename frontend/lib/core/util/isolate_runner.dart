/// Default (web + fallback) isolate runner. Browsers have no isolates, and the
/// only heavy PBKDF2 path in the app is the native SQLite login; the cloud/web
/// build authenticates server-side and never calls this, so running the
/// computation inline is correct and keeps `dart:isolate` out of the browser
/// compile graph.
Future<T> runIsolated<T>(Future<T> Function() computation) => computation();
