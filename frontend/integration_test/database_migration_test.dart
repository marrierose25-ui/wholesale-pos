import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:sqflite/sqflite.dart';

/// Stage 0 native-platform verification: exercises the REAL sqflite plugin
/// (not sqflite_common_ffi) on Android/iOS — factory selection, migration
/// transaction, downgrade refusal and index convergence on device SQLite.
///
/// Run: flutter test integration_test -d <android|ios device>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory workDir;
  late String dbPath;

  setUpAll(() async {
    final support = await getApplicationSupportDirectory();
    workDir = await Directory(
      p.join(support.path, 'stage0_it'),
    ).create(recursive: true);
    dbPath = p.join(workDir.path, LocalDatabase.databaseName);
  });

  tearDownAll(() async {
    try {
      await workDir.delete(recursive: true);
    } catch (_) {}
  });

  test('historical v12 database upgrades to v23 with data intact', () async {
    // Seed the genuine v12 fixture (bundled as a test asset).
    final bytes = await rootBundle.load(
      'integration_test/fixtures/v12_wholesale_pos.db',
    );
    await File(dbPath).writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );

    final db = await LocalDatabase.openAt(dbPath);
    try {
      expect(await db.getVersion(), LocalDatabase.schemaVersion);
      expect(
        (await db.rawQuery('PRAGMA integrity_check')).first.values.first,
        'ok',
      );
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(await db.query('sales'), hasLength(2));
      expect(await db.query('users'), hasLength(2));
      final index = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND name = 'picklist_items_picklist_id'",
      );
      expect(index, hasLength(1));
    } finally {
      await db.close();
    }

    // Reopen: idempotent, no duplicate index/trigger errors.
    final again = await LocalDatabase.openAt(dbPath);
    await again.close();
  });

  test('a newer-version database is refused on device', () async {
    final db = await LocalDatabase.openAt(dbPath);
    await db.execute(
      'PRAGMA user_version = ${LocalDatabase.schemaVersion + 1}',
    );
    await db.close();

    await expectLater(
      LocalDatabase.openAt(dbPath),
      throwsA(isA<UnsupportedDatabaseVersionException>()),
    );

    final check = await openDatabase(
      dbPath,
      options: OpenDatabaseOptions(readOnly: true),
    );
    try {
      expect(
        (await check.rawQuery('PRAGMA user_version')).first.values.first,
        LocalDatabase.schemaVersion + 1,
      );
      expect(await check.query('sales'), hasLength(2));
    } finally {
      await check.close();
    }
  });
}
