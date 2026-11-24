import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:pos_local_engine/pos_local_engine.dart';

/// Stage 0: a process killed while `onUpgrade` holds its transaction must
/// leave the database at the complete previous schema — never partially
/// migrated — and the next open must finish the migration cleanly.
///
/// The worker (`tool/db_migration_kill_worker.dart`) is a real `dart run`
/// process executing the production `LocalDatabase.openAt` through the
/// pure-Dart `package:pos_local_engine/database.dart` entry point. A
/// test-only pause hook inside `_onUpgrade` stops it deterministically
/// mid-transaction; the test then kills the OS process (not a Dart
/// exception) and reopens the file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String workerScript;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pos_kill_test');
    workerScript = p.absolute('tool/db_migration_kill_worker.dart');
    expect(
      File(workerScript).existsSync(),
      isTrue,
      reason: 'worker script must exist for the kill test',
    );
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows can hold the SQLite handle for a moment.
    }
  });

  setUpAll(() {
    sqfliteFfiInit();
  });

  /// Copies the v12 fixture (a mid-chain historical version) and returns the
  /// copy path plus the fixture bytes for later comparison.
  Future<({String path, List<int> bytes})> stageV12() async {
    final fixture = File('test/fixtures/database/v12/wholesale_pos.db');
    final copy = File(p.join(tempDir.path, LocalDatabase.databaseName));
    await fixture.copy(copy.path);
    return (path: copy.path, bytes: fixture.readAsBytesSync());
  }

  /// Resolves a spawnable Dart SDK executable. On Windows `dart` on PATH is
  /// a shim, so the real `dart.exe` is located inside the Flutter SDK that
  /// contains the currently running test binary.
  Future<String> dartExecutable() async {
    if (!Platform.isWindows) return 'dart';
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 10; i++) {
      final candidate = p.join(
        dir.path,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        'dart.exe',
      );
      if (await File(candidate).exists()) return candidate;
      dir = dir.parent;
    }
    fail('could not locate dart.exe inside the Flutter SDK');
  }

  /// `dart run` goes through the Dart frontend, which can keep the kernel
  /// alive as a child process. `Process.kill()` only terminates the
  /// frontend, so the orphaned child could keep the SQLite file locked and
  /// let the "killed" migration finish anyway — the intermittent failure
  /// this test was seeing. On Windows, taskkill /T takes the whole tree;
  /// elsewhere dart run executes in-process and a plain kill suffices.
  Future<void> killTree(Process process) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', [
        '/PID',
        '${process.pid}',
        '/T',
        '/F',
      ]);
    } else {
      process.kill();
    }
  }

  /// Runs the worker, waits until it reports the named checkpoint via the
  /// marker file, then kills the process — a real OS-level termination while
  /// the migration transaction is open, not a simulated Dart exception.
  Future<void> killWorkerAt(String dbPath, String checkpoint) async {
    final marker = p.join(tempDir.path, 'checkpoint_$checkpoint.marker');
    final process = await Process.start(
      await dartExecutable(),
      ['run', workerScript, dbPath, checkpoint, marker],
      workingDirectory: Directory.current.path,
    );

    final output = StringBuffer();
    process.stdout
        .transform(const SystemEncoding().decoder)
        .listen(output.write);
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen(output.write);

    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (!File(marker).existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        await killTree(process);
        fail(
          'worker never reached checkpoint "$checkpoint".\n$output',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await killTree(process);
    await process.exitCode;
  }

  /// After an OS-level kill, Windows can lag a moment releasing the SQLite
  /// file handle and locks — `taskkill /T /F` returns once termination is
  /// issued, but the kernel finishes reaping the process tree (and dropping
  /// its handles) asynchronously. Opening the file in that window fails with
  /// SQLITE_BUSY ("database is locked") even though the kill succeeded and
  /// the rollback is correct. Poll the read-only open until the lock clears
  /// instead of racing it: every assertion below is unchanged, and a lock
  /// that NEVER clears (a genuinely leaked handle) still fails the test.
  Future<Database> openWhenUnlocked(String path) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      Database? db;
      try {
        db = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(readOnly: true),
        );
        // `openDatabase` can succeed while the first statement still hits a
        // lingering lock, so force a real read before declaring success.
        await db.rawQuery('PRAGMA user_version');
        return db;
      } catch (e) {
        try {
          await db?.close();
        } catch (_) {
          // A handle that failed mid-open may not close cleanly; the next
          // attempt opens a fresh one regardless.
        }
        final message = e.toString();
        final isLock = message.contains('database is locked') ||
            message.contains('database is busy') ||
            message.contains('database table is locked');
        if (!isLock || DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  /// Asserts the on-disk file is still exactly the pre-migration v12
  /// database: version, schema snapshot and rows all intact.
  Future<void> expectStillV12(String path, List<int> fixtureBytes) async {
    final db = await openWhenUnlocked(path);
    try {
      expect(
        (await db.rawQuery('PRAGMA user_version')).first.values.first,
        12,
        reason: 'killed migration must roll back to the previous version',
      );
      expect(
        (await db.rawQuery('PRAGMA integrity_check')).first.values.first,
        'ok',
      );
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(await db.query('sales'), hasLength(2));
      expect(await db.query('users'), hasLength(2));
    } finally {
      await db.close();
    }
    // The file may differ in SQLite header bookkeeping after the crash, so
    // compare the safety copy (a byte snapshot taken before the attempt)
    // against the fixture instead of the live file.
    final bak = File('$path${LocalDatabase.backupSuffix}');
    expect(await bak.exists(), isTrue);
    expect(await bak.readAsBytes(), fixtureBytes);
  }

  /// Reopens through the application and asserts a complete v23 database.
  Future<void> expectMigratedToV23(String path) async {
    final db = await LocalDatabase.openAt(path);
    try {
      expect(await db.getVersion(), LocalDatabase.schemaVersion);
      expect(
        (await db.rawQuery('PRAGMA integrity_check')).first.values.first,
        'ok',
      );
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(await db.query('sales'), hasLength(2));
      expect(await db.query('users'), hasLength(2));
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND name = 'picklist_items_picklist_id'",
      );
      expect(indexes, hasLength(1));
    } finally {
      await db.close();
    }
  }

  for (final checkpoint in <String>['start', 'mid', 'late']) {
    test(
      'process killed at "$checkpoint" rolls back and recovers cleanly',
      () async {
        final staged = await stageV12();
        await killWorkerAt(staged.path, checkpoint);

        // The killed transaction left no partial schema: still v12.
        await expectStillV12(staged.path, staged.bytes);

        // The next application open completes the whole migration.
        await expectMigratedToV23(staged.path);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
