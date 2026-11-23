import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:pos_contracts/pos_contracts.dart';

/// [AppLogSink] that writes the rolling `logs/app.log` next to the till's
/// database, in the per-user support directory (`%APPDATA%\com…\Support` on
/// Windows, `~/.local/share/…` on Linux, the app container on Android/iOS).
///
/// This file is the only place `dart:io` and `path_provider` are reachable from
/// the logger, and it is installed by the native entry point (`main.dart`)
/// only. The web/PWA entry never imports it, which is what keeps `dart:io` out
/// of the dart2js graph that `app_shell.dart` drags along.
final class FileLogSink extends AppLogSink {
  FileLogSink._(this._file);

  /// Rotation threshold. 5 MB is roughly 40k lines of the shape this app writes
  /// (a migration notice, a refused sync, a stack trace), which at a shop's
  /// real event rate is weeks of history — long enough to reproduce a
  /// heisenbug, short enough that a support bundle is an email attachment.
  static const int maxBytes = 5 * 1024 * 1024;

  static const String _fileName = 'app.log';
  static const String _directoryName = 'logs';

  final File _file;

  @override
  String? get location => _file.path;

  /// Resolves the support directory and prepares `logs/`. Returns null instead
  /// of throwing when the directory cannot be created: an app that cannot log
  /// must still open the register, and [AppLogger] keeps working on its buffer
  /// and the debug console.
  static Future<FileLogSink?> tryCreate({Directory? directory}) async {
    try {
      final base = directory ?? await getApplicationSupportDirectory();
      final dir = Directory(p.join(base.path, _directoryName));
      await dir.create(recursive: true);
      return FileLogSink._(File(p.join(dir.path, _fileName)));
    } catch (_) {
      return null;
    }
  }

  /// Appends one line and forces it to disk.
  ///
  /// `flush: true` costs a syscall per line, which is the wrong trade for a
  /// request hot path and the right one here: the lines this writes are the
  /// evidence left behind when a till crashes, and a buffered tail is exactly
  /// the part an abort loses. Volume is a handful of lines per session.
  ///
  /// Throws on I/O failure. Callers must not treat that as fatal — [AppLogger]
  /// swallows sink errors so a locked or full disk cannot fail a sale.
  @override
  Future<void> writeLine(String line) async {
    if (await _file.exists() && await _file.length() >= maxBytes) {
      await _rotate();
    }
    await _file.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  /// `app.log` -> `app.log.1`, one generation deep.
  ///
  /// The previous `.1` is deleted first because `rename` refuses an existing
  /// target on Windows, and because keeping more than one rotation would let
  /// the bundle grow past the size the operator has to send us.
  Future<void> _rotate() async {
    final previous = File('${_file.path}.1');
    if (await previous.exists()) {
      await previous.delete();
    }
    await _file.rename(previous.path);
  }
}
