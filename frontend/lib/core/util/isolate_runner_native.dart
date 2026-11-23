import 'dart:isolate';

/// Native isolate runner: offloads a heavy computation to a background isolate
/// so the UI thread stays responsive. Selected via a conditional import when
/// `dart:io` is available (Windows / Android / iOS); the web build resolves the
/// import to the inline default instead, keeping this `dart:isolate`-dependent
/// file out of the browser compile graph.
Future<T> runIsolated<T>(Future<T> Function() computation) =>
    Isolate.run(computation);
