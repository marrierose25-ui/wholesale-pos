import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:pos_local_engine/pos_local_engine.dart';

/// Stage 0: a database whose `user_version` is newer than this build's
/// [LocalDatabase.schemaVersion] must be refused, never silently stamped
/// down. Before the fix, sqflite's default (no `onDowngrade`) rewrote
/// `user_version` to the lower number while leaving the newer schema in
/// place — quiet metadata damage on a till that had been rolled back to an
/// older installer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    sqfliteFfiInit();
    tempDir = await Directory.systemTemp.createTemp('pos_downgrade_test');
    dbPath = p.join(tempDir.path, LocalDatabase.databaseName);
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows can hold the SQLite handle for a moment.
    }
  });

  Future<Database> openRaw() => databaseFactoryFfi.openDatabase(dbPath);

  Future<int> onDiskVersion() async {
    final db = await openRaw();
    try {
      return (await db.rawQuery('PRAGMA user_version')).first.values.first
          as int;
    } finally {
      await db.close();
    }
  }

  test(
    'a newer-version database is rejected and left completely untouched',
    () async {
      // A till last written by a newer build: current schema plus one extra
      // table only that build knows about, stamped with a newer version.
      final newer = await LocalDatabase.openAt(dbPath);
      await newer.execute('CREATE TABLE future_only_table (id TEXT)');
      await newer.insert('users', {
        'id': 'u-1',
        'username': 'owner',
        'password_hash': 'hash',
        'salt': 'salt',
        'role': 'OWNER',
        'is_active': 1,
        'created_at': '2026-11-23T08:00:00.000Z',
      });
      await newer.execute(
        'PRAGMA user_version = ${LocalDatabase.schemaVersion + 3}',
      );
      await newer.close();

      final bytesBefore = await File(dbPath).readAsBytes();

      // 1 + 5. The open is rejected with an understandable error.
      Object? caught;
      try {
        await LocalDatabase.openAt(dbPath);
        fail('opening a newer-version database must throw');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<UnsupportedDatabaseVersionException>());
      final message = caught.toString();
      expect(message, contains('schema v${LocalDatabase.schemaVersion + 3}'));
      expect(message, contains('v${LocalDatabase.schemaVersion}'));
      expect(message, contains('not modified'));

      // 2. user_version was never rewritten.
      expect(await onDiskVersion(), LocalDatabase.schemaVersion + 3);

      // 3 + 4. Every table, the newer build's own table, and the rows
      // survive; nothing was dropped, migrated or stamped.
      final check = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        final tables = (await check.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        )).map((row) => row['name'] as String).toSet();
        expect(tables, containsAll(['users', 'sales', 'future_only_table']));
        expect((await check.query('users')).single['id'], 'u-1');
        expect(await check.query('future_only_table'), isEmpty);
        expect(
          (await check.rawQuery('PRAGMA integrity_check')).first.values.first,
          'ok',
        );
      } finally {
        await check.close();
      }

      // The database file itself was not silently modified: SQLite may
      // update the header change counter on open, so compare the schema
      // version and content rather than raw bytes — but the pre-open
      // safety copy must equal the file as it was handed to us.
      final bak = File('$dbPath${LocalDatabase.backupSuffix}');
      expect(await bak.exists(), isTrue);
      expect(await bak.readAsBytes(), bytesBefore);

      // Refusing is stable: every later attempt fails the same way and the
      // version still never moves.
      await expectLater(
        LocalDatabase.openAt(dbPath),
        throwsA(isA<UnsupportedDatabaseVersionException>()),
      );
      expect(await onDiskVersion(), LocalDatabase.schemaVersion + 3);
    },
  );

  test(
    'a database last opened by an older build still upgrades normally',
    () async {
      // The mirror case: a till on the previous release must keep working.
      final db = await LocalDatabase.openAt(dbPath);
      await db.insert('users', {
        'id': 'u-1',
        'username': 'owner',
        'password_hash': 'hash',
        'salt': 'salt',
        'role': 'OWNER',
        'is_active': 1,
        'created_at': '2026-11-23T08:00:00.000Z',
      });
      await db.execute(
        'PRAGMA user_version = ${LocalDatabase.schemaVersion - 1}',
      );
      await db.close();

      final upgraded = await LocalDatabase.openAt(dbPath);
      try {
        expect(await upgraded.getVersion(), LocalDatabase.schemaVersion);
        expect((await upgraded.query('users')).single['id'], 'u-1');
      } finally {
        await upgraded.close();
      }
    },
  );

  test('reopening a current database is unaffected', () async {
    final first = await LocalDatabase.openAt(dbPath);
    await first.close();
    final second = await LocalDatabase.openAt(dbPath);
    expect(await second.getVersion(), LocalDatabase.schemaVersion);
    await second.close();
  });
}
