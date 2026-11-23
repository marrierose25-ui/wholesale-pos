import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:pos_local_engine/pos_local_engine.dart';
import 'schema_snapshot.dart';

/// Runs the real [LocalDatabase] migration against genuinely historical
/// database files built from the DDL stored in git.
///
/// Nothing here is produced by opening a v22 database and deleting columns:
/// `tool/database_fixtures/build_historical_fixtures.py` extracts `_onCreate`
/// (and its index/trigger helpers) from the historical commits recorded in a
/// fixture's `fixture.json`.
///
/// Finding recorded by this test: on the current build a pre-v6 file cannot
/// reach v22. The `<6` upgrade step calls `_createIndexesAndTriggers`, which
/// creates indexes on `finance_entries` (first created at `<7`) and fails with
/// "no such table". This is a pre-existing limitation, so Stage 6.0 preserves
/// it and only characterises it: the migration is atomic, rolls back cleanly
/// and leaves the original file (and its `.bak` safety copy) untouched.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  final allVersions = <int>[2, 3, 4, 12, 19, 20, 21, 22];
  final upgradeableVersions = <int>[12, 19, 20, 21, 22];
  final blockedVersions = <int>[2, 3, 4];

  for (final version in allVersions) {
    group('genuine v$version fixture', () {
      late Directory tempDir;
      late File fixture;
      late File copy;
      late List<int> fixtureBytesBefore;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('stage60_v${version}_');
        fixture = File('test/fixtures/database/v$version/wholesale_pos.db');
        expect(
          fixture.existsSync(),
          isTrue,
          reason:
              'Run python tool/database_fixtures/build_historical_fixtures.py',
        );
        fixtureBytesBefore = fixture.readAsBytesSync();
        copy = File(p.join(tempDir.path, LocalDatabase.databaseName));
        await fixture.copy(copy.path);
      });

      tearDown(() async {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {
          // Windows can hold the SQLite handle for a moment.
        }
      });

      test('opens at its historical user_version with the expected pre-shape',
          () async {
        final db = await databaseFactoryFfi.openDatabase(
          copy.path,
          options: OpenDatabaseOptions(readOnly: true),
        );
        final pre = await SchemaSnapshot.capture(db);
        await db.close();

        expect(pre['user_version'], version);
        SchemaSnapshot.expectSnapshot(pre, 'v${version}_pre');
        await _expectPreMigrationData(version, copy.path);
      });

      if (upgradeableVersions.contains(version)) {
        test('migrates to v22 and preserves historical data', () async {
          final db = await LocalDatabase.openAt(copy.path);
          try {
            expect(
              (await db.rawQuery('PRAGMA user_version')).first.values.first,
              LocalDatabase.schemaVersion,
            );

            final post = await SchemaSnapshot.capture(db);
            SchemaSnapshot.expectSnapshot(post, 'v${version}_post');

            final integrity = await db.rawQuery('PRAGMA integrity_check');
            expect(integrity.first.values.first, 'ok');
            expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);

            await _expectHistoricalDataPreserved(version, db);
          } finally {
            await db.close();
          }

          expect(
            fixture.readAsBytesSync(),
            orderedEquals(fixtureBytesBefore),
            reason: 'migration must run against a copy, never the fixture',
          );

          if (version < LocalDatabase.schemaVersion) {
            final bak = File('${copy.path}${LocalDatabase.backupSuffix}');
            expect(bak.existsSync(), isTrue);
            expect(bak.readAsBytesSync(), orderedEquals(fixtureBytesBefore));
          } else {
            expect(
              File('${copy.path}${LocalDatabase.backupSuffix}').existsSync(),
              isFalse,
            );
          }

          // F-2, fully characterised:
          //  * v19 and older take the `<20` branch, which creates the index.
          //  * v20 and v21 were created without it and their upgrade skips the
          //    `<20` branch, so they still lack it at v22.
          //  * a fresh v22 install has never had it.
          final indexes = (await _indexNames(copy.path)).toSet();
          if (version < 20) {
            expect(
              indexes,
              contains('picklist_items_picklist_id'),
              reason: 'the v20 upgrade creates this index',
            );
          } else {
            expect(
              indexes,
              isNot(contains('picklist_items_picklist_id')),
              reason: 'F-2: v20/v21/v22 never create the picklist index',
            );
          }
        });
      }

      if (blockedVersions.contains(version)) {
        test(
          'known limitation: pre-v6 upgrade fails at <6 and rolls back '
          'atomically',
          () async {
            await expectLater(
              LocalDatabase.openAt(copy.path),
              throwsA(isA<DatabaseException>()),
              reason:
                  'the <6 step creates indexes on finance_entries, which does '
                  'not exist until <7; Stage 6.0 must not fix this',
            );

            // Whole-migration rollback: same schema, same version, same rows.
            final db = await databaseFactoryFfi.openDatabase(
              copy.path,
              options: OpenDatabaseOptions(readOnly: true),
            );
            try {
              final after = await SchemaSnapshot.capture(db);
              expect(after['user_version'], version);
              expect(
                after,
                equals(await _readSnapshot('v${version}_pre')),
                reason: 'a failed onUpgrade must not leave a partial schema',
              );
              expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
              expect(
                (await db.rawQuery('PRAGMA integrity_check'))
                    .first
                    .values
                    .first,
                'ok',
              );
              await _expectPreMigrationData(version, copy.path);
            } finally {
              await db.close();
            }

            // The safety copy was taken before the attempt and is intact.
            final bak = File('${copy.path}${LocalDatabase.backupSuffix}');
            expect(bak.existsSync(), isTrue);
            expect(bak.readAsBytesSync(), orderedEquals(fixtureBytesBefore));

            // The fixture itself was never touched.
            expect(
              fixture.readAsBytesSync(),
              orderedEquals(fixtureBytesBefore),
            );
          },
        );
      }
    });
  }
}

Future<Map<String, dynamic>> _readSnapshot(String name) async {
  // Snapshot comparison helper lives in schema_snapshot.dart; this local read
  // keeps the rollback assertion explicit without rewriting the golden file.
  final file = File('${SchemaSnapshot.snapshotDir}/$name.json');
  final decoded = jsonDecodeFile(file);
  return (decoded as Map).cast<String, dynamic>();
}

Map<String, dynamic> jsonDecodeFile(File file) {
  final text = file.readAsStringSync();
  return (const JsonDecoder().convert(text) as Map).cast<String, dynamic>();
}

Future<Set<String>> _indexNames(String path) async {
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(readOnly: true),
  );
  try {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND name NOT LIKE 'sqlite_%'",
    );
    return rows.map((row) => row['name'] as String).toSet();
  } finally {
    await db.close();
  }
}

/// Minimal pre-migration assertions that prove each fixture carries the
/// representative history. Version-specific columns are checked only where
/// they exist.
Future<void> _expectPreMigrationData(int version, String path) async {
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(readOnly: true),
  );
  try {
    final users = await db.query('users', orderBy: 'username');
    expect(users, hasLength(2), reason: 'v$version users');
    expect(users.map((row) => row['username']), ['cashier', 'owner']);

    final products = await db.query('products', orderBy: 'code');
    expect(products, hasLength(2));

    final shifts = await db.query('shifts');
    expect(shifts, hasLength(2));
    expect(
      shifts.where((row) => row['status'] == 'OPEN'),
      hasLength(1),
    );

    final sales = await db.query('sales', orderBy: 'id');
    expect(sales, hasLength(2));
    expect(sales.first['total_minor_units'], 24000);
    expect(sales.last['status'], 'VOIDED');

    final items = await db.query('sale_items');
    expect(items, hasLength(2));

    if (version < 12) {
      expect(
        (await db.rawQuery('PRAGMA table_info(sale_items)'))
            .map((row) => row['name']),
        contains('quantity'),
      );
    } else {
      expect(
        (await db.rawQuery('PRAGMA table_info(sale_items)'))
            .map((row) => row['name']),
        contains('quantity_text'),
      );
    }
  } finally {
    await db.close();
  }
}

Future<void> _expectHistoricalDataPreserved(int version, Database db) async {
  // Users: both accounts, their roles and activity survive every path.
  final users = await db.query('users', orderBy: 'username');
  expect(users, hasLength(2), reason: 'v$version users');
  expect(users.map((row) => row['username']), ['cashier', 'owner']);
  final cashier = users.firstWhere((row) => row['id'] == 'U-cashier');
  final owner = users.firstWhere((row) => row['id'] == 'U-owner');
  expect(cashier['role'], 'CASHIER');
  expect(owner['role'], 'OWNER');
  expect(cashier['is_active'], 1);

  // The v11 upgrade backfills existing cashiers with the tabs they already
  // had; owners stay on the bypass list.
  expect(cashier['permissions'], '["pos","register","reports"]');
  expect(owner['permissions'], '[]');

  // The v19 upgrade stamps updated_at from created_at for older files; v19+
  // fixtures already carry it.
  expect(owner['updated_at'], owner['created_at']);

  // Products, including the inactive historical row.
  final products = await db.query('products', orderBy: 'code');
  expect(products, hasLength(2));
  expect(products.first['code'], 'SKU-001');
  expect(products.first['selling_price_minor_units'], 12000);
  expect(products.last['code'], 'SKU-002');
  expect(products.last['is_active'], 0);

  // Device registration row.
  final devices = await db.query('devices');
  expect(devices.single['id'], 'D-till-1');

  // Shifts, open and closed.
  final shifts = await db.query('shifts', orderBy: 'id');
  expect(shifts, hasLength(2));
  expect(shifts.firstWhere((row) => row['id'] == 'S-open')['status'], 'OPEN');
  expect(
    shifts.firstWhere((row) => row['id'] == 'S-closed')['status'],
    'CLOSED',
  );

  // Sales. payment_method is the only v2->v3 change; existing v2 rows receive
  // the 'CASH' default rather than being dropped.
  final sales = await db.query('sales', orderBy: 'id');
  expect(sales, hasLength(2));
  final sale1 = sales.firstWhere((row) => row['id'] == 'SALE-1');
  final sale2 = sales.firstWhere((row) => row['id'] == 'SALE-2');
  expect(sale1['payment_method'], 'CASH');
  expect(sale2['payment_method'], 'BANK');
  expect(sale1['status'], 'COMPLETED');
  expect(sale1['total_minor_units'], 24000);
  expect(sale2['status'], 'VOIDED');
  expect(sale2['total_minor_units'], 3500);
  expect(sale1['shift_id'], 'S-closed');
  expect(sale2['void_reason'], 'Customer changed mind');
  if (version < 5) {
    expect(sale2['voided_at'], isNull);
  } else {
    expect(sale2['voided_at'], '2024-02-01T11:00:00.000Z');
    expect(sale2['voided_by'], 'U-owner');
    expect(sale2['voided_shift_id'], 'S-closed');
  }

  // Sale lines: legacy integer quantities are copied into the flexible text +
  // milliunit columns by the v7 rebuild.
  final items = await db.query('sale_items', orderBy: 'id');
  expect(items, hasLength(2));
  final item1 = items.firstWhere((row) => row['id'] == 'ITEM-1');
  expect(item1['quantity_text'], '2');
  expect(item1['billing_quantity_milliunits'], 2000);
  expect(item1['line_total_minor_units'], 24000);
  if (version < 12) {
    expect(item1['notes'], isNull);
  } else {
    expect(
      items.firstWhere((row) => row['id'] == 'ITEM-2')['notes'],
      'historic descriptive quantity',
    );
  }

  // Audit history survives.
  final audit = await db.query('audit_logs', orderBy: 'id');
  expect(audit, hasLength(2));
  expect(audit.first['action'], 'SALE_CREATED');

  // Cash movements: the table appears at v4, user_id is added at v5 without a
  // backfill, and the v6 rebuild adds the missing user foreign key.
  final movements = await db.query('cash_movements', orderBy: 'id');
  if (version < 4) {
    expect(movements, isEmpty);
  } else {
    expect(movements, hasLength(2));
    final movement2 = movements.firstWhere((row) => row['id'] == 'CM-2');
    expect(movement2['amount_minor_units'], 2500);
    expect(movement2['type'], 'EXPENSE');
    if (version < 12) {
      expect(movement2['user_id'], isNull);
    } else {
      expect(movement2['user_id'], 'U-owner');
    }
    if (version >= 19) {
      expect(movement2['source_finance_entry_id'], 'FE-2');
    } else {
      expect(movement2['source_finance_entry_id'], isNull);
    }
  }
  final movementFks = await db.rawQuery(
    'PRAGMA foreign_key_list(cash_movements)',
  );
  expect(
    movementFks.map((row) => row['table']),
    containsAll(['shifts', 'users']),
  );

  // Proof photos: schema 16 moves base64 TEXT into the BLOB table.
  final photos = await db.query('cash_movement_photos');
  if (version >= 19) {
    expect(photos, hasLength(1));
    expect(photos.single['movement_id'], 'CM-2');
    expect(photos.single['jpeg_bytes'], isA<List<int>>());
  } else {
    expect(photos, isEmpty);
  }

  // Finance: tables first appear at v7, so pre-v7 files upgrade to empty
  // finance history; v12+ preserves rows, statuses and the recycle tombstone.
  final categories = await db.query('finance_categories', orderBy: 'id');
  final entries = await db.query('finance_entries', orderBy: 'id');
  final voidRequests = await db.query('void_requests', orderBy: 'id');
  if (version < 12) {
    expect(categories, isEmpty);
    expect(entries, isEmpty);
    expect(voidRequests, isEmpty);
  } else {
    expect(categories, hasLength(2));
    expect(
      categories.firstWhere((row) => row['id'] == 'FC-2')['deleted_at'],
      '2024-02-01T00:00:00.000Z',
    );
    expect(entries, hasLength(2));
    final completed = entries.firstWhere((row) => row['id'] == 'FE-2');
    expect(completed['status'], 'COMPLETED');
    expect(completed['payment_method'], 'CASH');
    expect(voidRequests, hasLength(1));
    expect(voidRequests.single['status'], 'APPROVED');
  }

  // Settings/outbox/counters arrive at v6/v9. Their keys are not touched by any
  // later migration, including the deliberately preserved secrets.
  final settings = {
    for (final row in await db.query('settings'))
      row['key'] as String: row['value'],
  };
  if (version < 12) {
    expect(settings, isEmpty);
  } else {
    expect(settings['theme_mode'], 'dark');
    expect(settings['remember_login'], 'true');
    expect(settings['license_code'], 'LEGACY-LICENSE-CODE');
    expect(settings['legacy_probe'], 'preserved-through-migration');
  }
  final outbox = await db.query('sync_outbox', orderBy: 'id');
  if (version < 12) {
    expect(outbox, isEmpty);
  } else {
    expect(outbox, hasLength(2));
    expect(outbox.first['synced_at'], '2024-02-01T10:01:00.000Z');
    expect(outbox.last['synced_at'], isNull);
  }
  final counters = await db.query('counters');
  if (version < 12) {
    expect(counters, isEmpty);
  } else {
    expect(counters.single['name'], 'receipt_number');
    expect(counters.single['value'], 1002);
  }

  // Warehouse picklists arrive at v20, pricing at v21, tombstones at v22.
  final picklists = await db.query('picklists');
  final picklistItems = await db.query('picklist_items');
  final picklistCustomers = await db.query('picklist_customers');
  if (version < 20) {
    expect(picklists, isEmpty);
    expect(picklistItems, isEmpty);
    expect(picklistCustomers, isEmpty);
  } else {
    expect(picklists, hasLength(1));
    expect(picklists.single['customer_name'], 'Acme Traders');
    expect(picklists.single['deleted_at'], isNull);
    expect(picklistItems, hasLength(1));
    final line = picklistItems.single;
    expect(line['product_name'], 'Sugar 1kg');
    expect(line['requested_qty'], 5);
    expect(line['taken_qty'], 2);
    if (version < 21) {
      expect(line['unit'], isNull);
      expect(line['unit_price_minor_units'], 0);
      expect(line['line_total_minor_units'], 0);
    } else {
      expect(line['unit'], 'kg');
      expect(line['unit_price_minor_units'], 12000);
      expect(line['line_total_minor_units'], 24000);
    }
    expect(line['deleted_at'], isNull);
    if (version < 21) {
      expect(picklistCustomers, isEmpty);
    } else {
      expect(picklistCustomers, hasLength(1));
      expect(picklistCustomers.single['name'], 'Acme Traders');
    }
  }

  // Triggers that guard a single open drawer and a known cashier are present on
  // every v22 database.
  final triggers = (await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'trigger'",
  )).map((row) => row['name'] as String).toSet();
  expect(
    triggers,
    containsAll([
      'prevent_second_open_shift_insert',
      'prevent_second_open_shift_update',
      'shifts_cashier_must_exist_insert',
      'shifts_cashier_must_exist_update',
    ]),
  );
}
