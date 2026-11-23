import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
/// Stage 6.0 characterisation of the three backup/restore paths.
///
/// These tests freeze existing behaviour. In particular they record that a
/// JSON restore intentionally loses the license, activation, session and
/// device-identity settings, and that a failed pre-migration copy never stops
/// the application from opening.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('stage60_backup_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    dbPath = p.join(tempDir.path, 'till.db');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows can hold a SQLite or read-only handle for a moment.
    }
  });

  Future<void> setReadOnly(String path, bool readOnly) async {
    final result = await Process.run('attrib', [
      readOnly ? '+R' : '-R',
      path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  Future<void> seedOwner(Database db) async {
    await db.insert('users', {
      'id': 'owner-1',
      'username': 'owner',
      'password_hash': 'LIVE_HASH',
      'salt': 'LIVE_SALT',
      'role': 'OWNER',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Map<String, dynamic> buildBackup({
    List<Map<String, dynamic>> devices = const [
      {'id': 'restored-device', 'name': 'Restored PC', 'platform': 'Windows'},
    ],
    List<Map<String, dynamic>> products = const [],
  }) {
    final now = DateTime.now().toIso8601String();
    return {
      'exported_at': now,
      'version': LocalDatabase.schemaVersion,
      'users': [
        {
          'id': 'owner-1',
          'username': 'owner',
          'role': 'OWNER',
          'is_active': 1,
          'created_at': now,
        },
      ],
      'products': products,
      'sales': <dynamic>[],
      'sale_items': <dynamic>[],
      'shifts': <dynamic>[],
      'cash_movements': <dynamic>[],
      'audit_logs': <dynamic>[],
      'devices': devices,
      'counters': <dynamic>[],
      'settings': <dynamic>[],
    };
  }

  Future<String> writeBackup(Map<String, dynamic> data) async {
    final path = p.join(tempDir.path, 'restore.json');
    await File(path).writeAsString(jsonEncode(data));
    return path;
  }

  test(
    'a failed pre-migration copy is logged but never blocks the upgrade',
    () async {
      final first = await LocalDatabase.openAt(dbPath);
      await seedOwner(first);
      await first.close();

      // Rewind so the next open must migrate, then make the target of the
      // safety copy unwritable. Dart's File.copy fails on a read-only
      // destination on Windows, which is the failure this path must survive.
      final rewind = await LocalDatabase.openAt(dbPath);
      await rewind.execute('PRAGMA user_version = 21');
      await rewind.close();

      final backup = File('$dbPath${LocalDatabase.backupSuffix}');
      await backup.writeAsString('PREVIOUS-GOOD-BACKUP');
      await setReadOnly(backup.path, true);

      try {
        final upgraded = await LocalDatabase.openAt(dbPath);
        expect(
          (await upgraded.rawQuery('PRAGMA user_version')).first.values.first,
          LocalDatabase.schemaVersion,
        );
        expect((await upgraded.query('users')).single['id'], 'owner-1');
        await upgraded.close();

        // The failed copy did not destroy the older good backup.
        expect(await backup.readAsString(), 'PREVIOUS-GOOD-BACKUP');
      } finally {
        await setReadOnly(backup.path, false);
      }
    },
    skip: Platform.isWindows
        ? false
        : 'read-only destination failure is Windows-specific',
  );

  test('export strips secrets, and restore loses them by design', () async {
    final db = await LocalDatabase.openAt(dbPath);
    try {
      await seedOwner(db);
      for (final entry in const {
        'auth_session': 'SESSION-SENTINEL',
        'license_code': 'LICENSE-SENTINEL',
        'activation_code': 'ACTIVATION-SENTINEL',
        'device_hw_uuid': 'HW-SENTINEL',
        'device_install_uuid': 'INSTALL-SENTINEL',
        'theme_mode': 'dark',
        'remember_login': '0',
        'demo_password_version': '2',
        'sync_cursor.sales':
            '{"received_at":"2026-01-01T00:00:00Z","id":"sale-1"}',
        'sync_cursor.sales_by_day':
            '{"received_at":"2026-01-01T00:00:00Z","id":"row-1"}',
      }.entries) {
        await db.insert('settings', {
          'key': entry.key,
          'value': entry.value,
        });
      }

      final exportedPath = await DataExporter.exportToJson(
        db,
        requestingUserId: 'owner-1',
      );
      final exported =
          jsonDecode(await File(exportedPath).readAsString()) as Map;
      final exportedKeys = (exported['settings'] as List)
          .map((row) => (row as Map)['key'])
          .toSet();
      for (final secret in const [
        'auth_session',
        'license_code',
        'activation_code',
        'device_hw_uuid',
        'device_install_uuid',
      ]) {
        expect(exportedKeys, isNot(contains(secret)));
      }
      expect(exportedKeys, containsAll(<String>[
        'theme_mode',
        'remember_login',
        'demo_password_version',
        'sync_cursor.sales',
      ]));

      // Change live state after the backup was taken. The restore must keep
      // the owner's live credential but replace preferences with the backup's
      // values and never resurrect a stripped secret.
      await db.update('settings', {'value': 'light'}, where: 'key = ?',
          whereArgs: ['theme_mode']);
      await db.insert('settings', {
        'key': 'license_code',
        'value': 'LIVE-LICENSE-AFTER-BACKUP',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('settings', {
        'key': 'activation_code',
        'value': 'LIVE-ACTIVATION-AFTER-BACKUP',
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await DataImporter.importFromJson(
        db,
        exportedPath,
        requestingUserId: 'owner-1',
      );

      final settings = {
        for (final row in await db.query('settings'))
          row['key'] as String: row['value'],
      };
      expect(settings['theme_mode'], 'dark');
      expect(settings['remember_login'], '0');
      expect(settings['demo_password_version'], '2');
      for (final secret in const [
        'auth_session',
        'license_code',
        'activation_code',
        'device_hw_uuid',
        'device_install_uuid',
      ]) {
        expect(settings.containsKey(secret), isFalse, reason: secret);
      }
      // Sync cursors are deliberately dropped so the restored till re-reads
      // the cloud from the beginning.
      expect(
        settings.keys.where((key) => key.startsWith('sync_cursor.')),
        isEmpty,
      );

      // The restoring owner is not locked out of their own machine.
      final owner = (await db.query('users')).single;
      expect(owner['password_hash'], 'LIVE_HASH');
      expect(owner['salt'], 'LIVE_SALT');
    } finally {
      await db.close();
    }
  });

  test('restore writes a recovery snapshot and re-registers this device',
      () async {
    final deviceFile = File(p.join(tempDir.path, LocalDatabase.deviceIdFileName));
    await deviceFile.writeAsString('this-machine-device');

    final db = await LocalDatabase.openAt(dbPath);
    try {
      await seedOwner(db);
      await db.insert('products', {
        'id': 'local-product',
        'name': 'Local Before Restore',
        'code': 'LOCAL-1',
        'unit': 'kg',
        'selling_price_minor_units': 1000,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      final backupPath = await writeBackup(
        buildBackup(
          products: [
            {
              'id': 'restored-product',
              'name': 'Restored Sugar',
              'code': 'RESTORED-1',
              'unit': 'kg',
              'selling_price_minor_units': 2000,
              'is_active': 1,
              'created_at': DateTime.now().toIso8601String(),
              'updated_at': DateTime.now().toIso8601String(),
            },
          ],
        ),
      );

      await SqliteLocalDataOps(db).restoreBackup(
        backupPath,
        userId: 'owner-1',
      );

      // Backup contents landed.
      expect((await db.query('products')).single['id'], 'restored-product');

      // This machine still has a device row, taken from device_id.txt rather
      // than from another till's backup. The backup's own device row remains
      // because it is real history from another register.
      final devices = await db.query('devices', orderBy: 'id');
      expect(
        devices.map((row) => row['id']),
        containsAll(<String>['restored-device', 'this-machine-device']),
      );

      // A pre-restore export was written, and the audit row points at it.
      final recoveryFiles = tempDir
          .listSync()
          .whereType<File>()
          .where((file) =>
              file.uri.pathSegments.last.startsWith('wholesale_pos_backup_'))
          .toList();
      expect(recoveryFiles, hasLength(1));
      final recovery =
          jsonDecode(recoveryFiles.single.readAsStringSync()) as Map;
      expect(
        ((recovery['products'] as List).single as Map)['id'],
        'local-product',
      );

      final audit = await db.query(
        'audit_logs',
        where: 'action = ?',
        whereArgs: ['BACKUP_RESTORED'],
      );
      expect(audit, hasLength(1));
      expect(audit.single['details'], contains('recovery copy saved at'));
      expect(
        audit.single['details'],
        contains(recoveryFiles.single.path),
      );
    } finally {
      await db.close();
    }
  });
}
