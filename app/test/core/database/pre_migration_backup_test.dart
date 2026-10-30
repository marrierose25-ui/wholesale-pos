import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';

/// The recovery hook this file exists for: a migration that completes and is
/// wrong is unrecoverable without a copy of the file from *before* it ran, so
/// [LocalDatabase.openAt] copies the database aside whenever the on-disk schema
/// version is not the one the code is about to write.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late String dbPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pos_backup_test');
    dbPath = '${temp.path}/till.db';
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  String backupPath() => '$dbPath${LocalDatabase.backupSuffix}';

  Future<void> rewindToVersion(int version) async {
    final db = await LocalDatabase.openAt(dbPath);
    await db.execute('PRAGMA user_version = $version');
    await db.close();
  }

  Future<int> rowCount(String table) async {
    final db = await LocalDatabase.openAt(dbPath);
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM $table'),
    );
    await db.close();
    return count ?? -1;
  }

  test('a fresh install writes no backup', () async {
    final db = await LocalDatabase.openAt(dbPath);
    expect(await db.getVersion(), LocalDatabase.schemaVersion);
    await db.close();

    expect(await File(backupPath()).exists(), isFalse);
  });

  test(
    'an upgrade copies the pre-migration file aside, byte for byte',
    () async {
      // A till on the previous release, with real trading data in it.
      final first = await LocalDatabase.openAt(dbPath);
      await first.insert('users', {
        'id': 'u-owner',
        'username': 'owner',
        'password_hash': 'hash',
        'salt': 'salt',
        'role': 'OWNER',
        'is_active': 1,
        'created_at': '2026-10-30T08:00:00.000Z',
      });
      await first.close();

      await rewindToVersion(LocalDatabase.schemaVersion - 1);
      final before = await File(dbPath).readAsBytes();

      // The upgrade runs on open; the copy must be the file as it stood.
      final upgraded = await LocalDatabase.openAt(dbPath);
      expect(await upgraded.getVersion(), LocalDatabase.schemaVersion);
      await upgraded.close();

      final backup = File(backupPath());
      expect(await backup.exists(), isTrue);
      expect(await backup.readAsBytes(), before);
      expect(await rowCount('users'), 1);
    },
  );

  test(
    'reopening a current database does not clobber an older backup',
    () async {
      // A till that upgraded and lost data in the new schema: the only copy of
      // the good rows is the backup, and an ordinary restart must not overwrite
      // it with the broken file.
      final first = await LocalDatabase.openAt(dbPath);
      await first.close();
      await rewindToVersion(LocalDatabase.schemaVersion - 1);

      final upgraded = await LocalDatabase.openAt(dbPath);
      await upgraded.close();
      final goodCopy = await File(backupPath()).readAsBytes();
      expect(goodCopy, isNotEmpty);

      // Now open the current file twice more, as a till's daily restarts would.
      final again = await LocalDatabase.openAt(dbPath);
      await again.close();
      final third = await LocalDatabase.openAt(dbPath);
      await third.close();

      expect(await File(backupPath()).readAsBytes(), goodCopy);
    },
  );

  test('a database newer than this build is backed up before the stamp down', () async {
    // Nothing in this app downgrades on purpose, but sqflite with
    // onDowngrade == null silently writes the lower version without the
    // migration, which is a real-data hazard when a beta build has touched the
    // file. The backup must happen before that write.
    final db = await LocalDatabase.openAt(dbPath);
    await db.execute(
      'PRAGMA user_version = ${LocalDatabase.schemaVersion + 1}',
    );
    await db.close();

    final before = await File(dbPath).readAsBytes();
    final reopened = await LocalDatabase.openAt(dbPath);
    expect(await reopened.getVersion(), LocalDatabase.schemaVersion);
    await reopened.close();

    expect(await File(backupPath()).readAsBytes(), before);
  });
}
