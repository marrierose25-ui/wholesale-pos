import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pos_contracts/pos_contracts.dart';
import 'package:wholesale_pos_app/core/utils/app_logger_io.dart';

/// Collects lines in memory so ordering and filtering can be asserted.
class _MemorySink extends AppLogSink {
  final List<String> lines = <String>[];

  @override
  String? get location => 'memory://app.log';

  @override
  Future<void> writeLine(String line) async {
    lines.add(line);
  }
}

/// A sink whose disk is full or file is locked: the logger must swallow it.
class _BrokenSink extends AppLogSink {
  int attempts = 0;

  @override
  String? get location => null;

  @override
  Future<void> writeLine(String line) async {
    attempts++;
    throw const FileSystemException('The process cannot access the file');
  }
}

void main() {
  setUp(() async {
    await AppLogger.resetForTest();
  });

  tearDown(() async {
    await AppLogger.resetForTest();
  });

  group('AppLogger', () {
    test('formats one line as UTC timestamp, padded level, message', () {
      final line = AppLogger.format(
        LogLevel.warn,
        'sync refused',
        DateTime.utc(2026, 10, 30, 8, 5, 9, 123),
      );

      expect(line, '2026-10-30T08:05:09.123Z [WARN ] sync refused');
      expect(
        AppLogger.format(LogLevel.error, 'boom', DateTime.utc(2026)),
        '2026-01-01T00:00:00.000Z [ERROR] boom',
      );
    });

    test(
      'keeps lines written before install and flushes them in order',
      () async {
        AppLogger.info('during startup');
        AppLogger.error('before the sink existed');

        expect(AppLogger.logFilePath, isNull);
        expect(AppLogger.bufferedLines(), hasLength(2));

        final sink = _MemorySink();
        await AppLogger.install(sink);
        await AppLogger.flush();

        expect(AppLogger.bufferedLines(), isEmpty);
        expect(AppLogger.logFilePath, 'memory://app.log');
        expect(sink.lines, hasLength(2));
        expect(sink.lines[0], contains('during startup'));
        expect(sink.lines[1], contains('[ERROR] before the sink existed'));
      },
    );

    test('a failing sink never reaches the caller', () async {
      final sink = _BrokenSink();
      await AppLogger.install(sink);

      // A till whose log file is locked must still complete a sale.
      AppLogger.error('disk is on fire');
      await AppLogger.flush();

      expect(sink.attempts, 1);
    });

    test('failure() records the error and its stack', () async {
      final sink = _MemorySink();
      await AppLogger.install(sink);

      AppLogger.failure(StateError('no such table'), StackTrace.current);
      await AppLogger.flush();

      expect(sink.lines.single, contains('[ERROR] Bad state: no such table'));
      expect(sink.lines.single, contains('app_logger_test.dart'));
    });
  });

  group('FileLogSink', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('pos_log_test');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('creates logs/ under the support directory and appends', () async {
      final sink = await FileLogSink.tryCreate(directory: temp);
      expect(sink, isNotNull);
      expect(sink!.location, p.join(temp.path, 'logs', 'app.log'));

      await sink.writeLine('first');
      await sink.writeLine('second');

      final file = File(sink.location!);
      expect(await file.readAsString(), 'first\nsecond\n');
    });

    test('rotates to app.log.1 at 5 MB and keeps writing', () async {
      final sink = await FileLogSink.tryCreate(directory: temp);
      final file = File(sink!.location!);
      final rotated = File('${sink.location!}.1');

      // Stand in for weeks of trading without writing 5 MB through the logger.
      await file.writeAsString('x' * FileLogSink.maxBytes);
      expect(await file.length(), FileLogSink.maxBytes);

      await sink.writeLine('after rotation');

      expect(await rotated.exists(), isTrue);
      expect(await rotated.length(), FileLogSink.maxBytes);
      expect(await file.readAsString(), 'after rotation\n');

      // One generation deep: a second rotation deletes the older copy rather
      // than growing the bundle.
      await file.writeAsString('y' * FileLogSink.maxBytes);
      await sink.writeLine('second rotation');
      expect(await rotated.readAsString(), 'y' * FileLogSink.maxBytes);
      expect(await File('$rotated.1').exists(), isFalse);
    });

    test(
      'returns null instead of throwing when logs/ cannot be created',
      () async {
        // A path under a regular file can never be a directory.
        final blocker = File(p.join(temp.path, 'blocker'));
        await blocker.writeAsString('not a directory');

        final sink = await FileLogSink.tryCreate(
          directory: Directory(p.join(blocker.path, 'logs')),
        );

        expect(sink, isNull);
      },
    );
  });
}
