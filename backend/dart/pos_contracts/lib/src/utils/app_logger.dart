import 'package:meta/meta.dart';

/// How loud a message is. Written into every line so a support file can be
/// grepped for `[ERROR]` without reading the whole thing.
enum LogLevel { debug, info, warn, error }

/// Where finished log lines go. Deliberately free of `dart:io`: this file is
/// reachable from `app_shell.dart`, which `main_web.dart` imports, so anything
/// platform-specific lives in a sink implementation the web entry never
/// installs (see `app_logger_io.dart`).
abstract class AppLogSink {
  const AppLogSink();

  /// Absolute path a human (or the startup error screen) can copy. Null for a
  /// sink that does not write to a file.
  String? get location;

  /// Appends one already-formatted line. May be slow — [AppLogger] serialises
  /// these calls and never makes a caller wait on one.
  Future<void> writeLine(String line);
}

/// The app's own diagnostic record.
///
/// A shop till has no console attached and the operator cannot read a stack
/// trace, so the only way support ever learns what happened is a file this
/// process wrote. `print()` went to a stream nobody collects.
///
/// Three rules this class exists to keep:
///   * **Never throw.** A locked log file (antivirus scanning the folder on a
///     shop PC) must not take down a register that is mid-sale. Every sink
///     failure is swallowed after mirroring to the console.
///   * **Never lose the earliest messages.** The failure that produces the
///     startup error screen happens before an async path lookup can finish, so
///     lines written before [install] are buffered and flushed when a sink
///     arrives.
///   * **Never block the caller.** Writes are queued onto a single serial
///     chain, which keeps lines in order and keeps a disk hiccup off the UI
///     thread's critical path.
/// True in debug/profile builds; false in release.
const bool _isDebugBuild = !bool.fromEnvironment('dart.vm.product');

final class AppLogger {
  AppLogger._();

  static AppLogSink? _sink;
  static final List<String> _buffered = <String>[];
  static Future<void> _queue = Future<void>.value();

  /// Cap on messages kept before a sink exists. A till that cannot resolve its
  /// support directory must not grow this list forever; the newest lines are the
  /// useful ones, so the oldest go.
  static const int _maxBufferedLines = 500;

  /// Path of the active log file, or null on a build with no file sink (the
  /// web/PWA bundle, or a native build whose directory could not be created).
  /// `_StartupErrorApp` offers this to the operator to send to support.
  static String? get logFilePath => _sink?.location;

  /// Installs the file sink and writes whatever was buffered first. Await this
  /// before logging anything you must not lose — [AppLogger] is usable before
  /// it completes, it just cannot reach the disk yet.
  static Future<void> install(AppLogSink sink) async {
    final pending = List<String>.of(_buffered);
    _buffered.clear();
    _sink = sink;
    for (final line in pending) {
      await _enqueue(line);
    }
  }

  static void debug(String message) => _emit(LogLevel.debug, message);
  static void info(String message) => _emit(LogLevel.info, message);
  static void warn(String message) => _emit(LogLevel.warn, message);
  static void error(String message) => _emit(LogLevel.error, message);

  /// Logs an error plus its stack trace on the line the error started with.
  static void failure(Object error, [StackTrace? stackTrace]) {
    final text = stackTrace == null ? '$error' : '$error\n$stackTrace';
    _emit(LogLevel.error, text);
  }

  static void _emit(LogLevel level, String message) {
    final line = format(level, message, DateTime.now().toUtc());
    // Debug builds keep the console output developers work from; a release
    // build has no console to talk to, so the file is the only record.
    if (_isDebugBuild) {
      print(line);
    }
    final sink = _sink;
    if (sink == null) {
      _buffered.add(line);
      if (_buffered.length > _maxBufferedLines) {
        _buffered.removeAt(0);
      }
      return;
    }
    _queue = _queue.then((_) => sink.writeLine(line)).catchError((Object e) {
      // A log write must never become the reason a sale failed.
      if (_isDebugBuild) {
        print('AppLogger sink failed: $e');
      }
    });
  }

  static Future<void> _enqueue(String line) async {
    final sink = _sink;
    if (sink == null) return;
    _queue = _queue.then((_) => sink.writeLine(line)).catchError((Object e) {
      if (_isDebugBuild) {
        print('AppLogger sink failed: $e');
      }
    });
    return _queue;
  }

  /// Resolves once every queued line has reached the sink. Tests and the
  /// startup error screen use this so a file they are about to read is whole.
  static Future<void> flush() => _queue;

  /// `2026-10-30T07:58:04.123456Z [ERROR] message`. UTC because every cloud
  /// row, sync cursor and server log this gets compared against is UTC;
  /// local wall-clock in Addis (UTC+3) made cross-checking a shop incident
  /// against the server a manual arithmetic exercise.
  @visibleForTesting
  static String format(LogLevel level, String message, DateTime timestamp) {
    final tag = level.name.toUpperCase().padRight(5);
    return '${timestamp.toIso8601String()} [$tag] $message';
  }

  /// Lines written before a sink was installed, oldest first. Test-only view of
  /// the buffer that `install()` later flushes.
  @visibleForTesting
  static List<String> bufferedLines() => List<String>.unmodifiable(_buffered);

  @visibleForTesting
  static Future<void> resetForTest() async {
    await _queue;
    _sink = null;
    _buffered.clear();
    _queue = Future<void>.value();
  }
}
