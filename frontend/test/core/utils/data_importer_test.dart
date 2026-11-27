import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pos_local_engine/pos_local_engine.dart';

/// Backups written by schema 6 stored sale-item quantities as plain
/// integers. The importer must accept them and normalize rows to the
/// schema 7 shape instead of rejecting the whole restore.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  late Directory tempDir;
  late Database db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('wholesale_pos_import_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    db = await LocalDatabase.openInMemory();
    await db.insert('users', {
      'id': 'owner-1',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'OWNER',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
  });

  tearDown(() async {
    await db.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows occasionally holds a handle a moment longer.
    }
  });

  Map<String, dynamic> buildBackup({required int version}) {
    final now = DateTime.now().toIso8601String();
    final saleItem = <String, dynamic>{
      'id': 'item-1',
      'sale_id': 'sale-1',
      'product_id': 'prod-1',
      'product_name_snapshot': 'Sugar',
      'unit_price_snapshot_minor_units': 2000,
      'line_discount_minor_units': 0,
      'line_total_minor_units': 6000,
    };
    if (version < 7) {
      saleItem['quantity'] = 3; // legacy integer column
    } else {
      saleItem['quantity_text'] = '3 bags';
      saleItem['billing_quantity_milliunits'] = null;
      saleItem['notes'] = 'haggled price';
    }
    return {
      'exported_at': now,
      'version': version,
      'users': [
        {
          'id': 'owner-1',
          'username': 'owner',
          'password_hash': 'x',
          'salt': 'x',
          'role': 'OWNER',
          'is_active': 1,
          'created_at': now,
        },
      ],
      'products': <dynamic>[],
      'sales': [
        {
          'id': 'sale-1',
          'receipt_number': 'REC-001',
          'cashier_id': 'owner-1',
          'device_id': 'device-1',
          'shift_id': 'shift-1',
          'payment_method': 'CASH',
          'subtotal_minor_units': 6000,
          'discount_minor_units': 0,
          'total_minor_units': 6000,
          'amount_paid_minor_units': 6000,
          'change_minor_units': 0,
          'status': 'COMPLETED',
          'created_at': now,
        },
      ],
      'sale_items': [saleItem],
      'shifts': [
        {
          'id': 'shift-1',
          'cashier_id': 'owner-1',
          'opening_cash_minor_units': 0,
          'status': 'CLOSED',
          'opened_at': now,
        },
      ],
      'cash_movements': <dynamic>[],
      'audit_logs': [
        {
          'id': 'log-1',
          'user_id': 'owner-1',
          'action': 'SALE_COMPLETED',
          'created_at': now,
        },
      ],
      'devices': [
        {'id': 'device-1', 'name': 'PC', 'platform': 'Windows'},
      ],
      'counters': [
        {'name': 'receipt-20261022', 'value': 1},
      ],
      'settings': [
        {'key': 'theme_mode', 'value': 'light'},
      ],
      if (version >= 20) 'picklists': <dynamic>[],
      if (version >= 20) 'picklist_items': <dynamic>[],
      if (version >= 21) 'picklist_customers': <dynamic>[],
    };
  }

  Future<String> writeBackup(Map<String, dynamic> data) async {
    final path = p.join(tempDir.path, 'backup.json');
    await File(path).writeAsString(jsonEncode(data));
    return path;
  }

  test(
    'imports a v6 backup and normalizes legacy integer quantities',
    () async {
      final path = await writeBackup(buildBackup(version: 6));

      await DataImporter.importFromJson(db, path, requestingUserId: 'owner-1');

      final item = (await db.query(
        'sale_items',
        where: 'id = ?',
        whereArgs: ['item-1'],
      )).single;
      expect(item['quantity_text'], '3');
      expect(item['billing_quantity_milliunits'], 3000);

      final sale = (await db.query(
        'sales',
        where: 'id = ?',
        whereArgs: ['sale-1'],
      )).single;
      expect(sale['total_minor_units'], 6000);

      // V6 backups simply start with no finance records.
      expect(await db.query('finance_categories'), isEmpty);
      expect(await db.query('finance_entries'), isEmpty);
    },
  );

  test('imports a v7 backup with flexible quantities unchanged', () async {
    final path = await writeBackup(buildBackup(version: 7));

    await DataImporter.importFromJson(db, path, requestingUserId: 'owner-1');

    final item = (await db.query(
      'sale_items',
      where: 'id = ?',
      whereArgs: ['item-1'],
    )).single;
    expect(item['quantity_text'], '3 bags');
    expect(item['billing_quantity_milliunits'], isNull);
    expect(item['notes'], 'haggled price');
  });

  test('rejects backups older than v6 instead of guessing', () async {
    final path = await writeBackup(buildBackup(version: 5));

    await expectLater(
      DataImporter.importFromJson(db, path, requestingUserId: 'owner-1'),
      throwsException,
    );
    // The original data is untouched.
    expect(await db.query('sales'), isEmpty);
  });

  test('restores finance tables from a v7 backup', () async {
    final now = DateTime.now().toIso8601String();
    final data = buildBackup(version: 7)
      ..['finance_categories'] = [
        {'id': 'cat-1', 'name': 'Alem', 'created_at': now, 'updated_at': now},
      ]
      ..['finance_entries'] = [
        {
          'id': 'entry-1',
          'category_id': 'cat-1',
          'source': 'CBE Birr',
          'amount_minor_units': 500000,
          'description': null,
          'status': 'PENDING',
          'entry_date': now,
          'created_at': now,
          'created_by': 'owner-1',
          'completed_at': null,
          'completed_by': null,
          'updated_at': now,
        },
      ];
    final path = await writeBackup(data);

    await DataImporter.importFromJson(db, path, requestingUserId: 'owner-1');

    expect((await db.query('finance_categories')).length, 1);
    final entry = (await db.query('finance_entries')).single;
    expect(entry['source'], 'CBE Birr');
    expect(entry['status'], 'PENDING');
  });

  test(
    'warehouse picklists and tombstones round-trip through export and restore',
    () async {
      final now = DateTime.now().toIso8601String();
      await db.insert('picklist_customers', {
        'id': 'warehouse-customer-1',
        'name': 'Alem Shop',
        'phone': '0912345678',
        'created_at': now,
      });
      await db.insert('picklists', {
        'id': 'picklist-1',
        'customer_name': 'Alem Shop',
        'status': 'COMPLETED',
        'created_by': 'owner-1',
        'created_at': now,
        'updated_at': now,
        'deleted_at': now,
      });
      await db.insert('picklist_items', {
        'id': 'picklist-item-1',
        'picklist_id': 'picklist-1',
        'product_name': 'Sugar',
        'requested_qty': 10,
        'taken_qty': 8,
        'unit': 'kg',
        'unit_price_minor_units': 2500,
        'line_total_minor_units': 20000,
        'updated_at': now,
        'deleted_at': now,
      });

      final exportPath = await DataExporter.exportToJson(
        db,
        requestingUserId: 'owner-1',
      );
      final exported =
          jsonDecode(await File(exportPath).readAsString()) as Map;
      expect(exported['picklists'], hasLength(1));
      expect(exported['picklist_items'], hasLength(1));
      expect(exported['picklist_customers'], hasLength(1));
      expect((exported['picklists'] as List).single['deleted_at'], now);
      expect((exported['picklist_items'] as List).single['deleted_at'], now);

      // A post-export local row must be replaced, not left beside the backup.
      await db.insert('picklists', {
        'id': 'stale-picklist',
        'customer_name': 'Stale',
        'status': 'PENDING',
        'created_by': 'owner-1',
        'created_at': now,
        'updated_at': now,
      });

      await DataImporter.importFromJson(
        db,
        exportPath,
        requestingUserId: 'owner-1',
      );

      final restoredLists = await db.query('picklists', orderBy: 'id');
      final restoredItems = await db.query('picklist_items');
      final restoredCustomers = await db.query('picklist_customers');
      expect(restoredLists.map((row) => row['id']), ['picklist-1']);
      expect(restoredLists.single['deleted_at'], now);
      expect(restoredItems.single['taken_qty'], 8);
      expect(restoredItems.single['deleted_at'], now);
      expect(restoredCustomers.single['name'], 'Alem Shop');
    },
  );

  test(
    'legacy pre-v20 backup clears local picklists instead of leaving stale warehouse data',
    () async {
      final now = DateTime.now().toIso8601String();
      await db.insert('picklist_customers', {
        'id': 'old-directory-row',
        'name': 'Old Directory',
        'created_at': now,
      });
      await db.insert('picklists', {
        'id': 'old-picklist',
        'customer_name': 'Old',
        'status': 'PENDING',
        'created_by': 'owner-1',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('picklist_items', {
        'id': 'old-item',
        'picklist_id': 'old-picklist',
        'product_name': 'Old product',
        'requested_qty': 1,
        'taken_qty': 0,
        'updated_at': now,
      });

      final path = await writeBackup(buildBackup(version: 19));
      await DataImporter.importFromJson(
        db,
        path,
        requestingUserId: 'owner-1',
      );

      expect(await db.query('picklists'), isEmpty);
      expect(await db.query('picklist_items'), isEmpty);
      expect(await db.query('picklist_customers'), isEmpty);
    },
  );

  test(
    'pre-fix v24 backup without warehouse fields remains restorable and preserves local picklists',
    () async {
      final now = DateTime.now().toIso8601String();
      await db.insert('picklists', {
        'id': 'keep-picklist',
        'customer_name': 'Keep',
        'status': 'PENDING',
        'created_by': 'owner-1',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('picklist_items', {
        'id': 'keep-item',
        'picklist_id': 'keep-picklist',
        'product_name': 'Rice',
        'requested_qty': 2,
        'taken_qty': 1,
        'updated_at': now,
      });

      final legacyBackup = buildBackup(version: 24)
        ..remove('picklists')
        ..remove('picklist_items')
        ..remove('picklist_customers');
      final path = await writeBackup(legacyBackup);

      await DataImporter.importFromJson(
        db,
        path,
        requestingUserId: 'owner-1',
      );

      expect((await db.query('picklists')).single['id'], 'keep-picklist');
      expect((await db.query('picklist_items')).single['id'], 'keep-item');
    },
  );

  test(
    'malformed picklist backup is rejected before changing existing warehouse data',
    () async {
      final now = DateTime.now().toIso8601String();
      await db.insert('picklists', {
        'id': 'keep-picklist',
        'customer_name': 'Keep',
        'status': 'PENDING',
        'created_by': 'owner-1',
        'created_at': now,
        'updated_at': now,
      });
      final data = buildBackup(version: 24)
        ..['picklists'] = <dynamic>[]
        ..['picklist_items'] = [
          {
            'id': 'broken-item',
            // Missing picklist_id and other required values.
            'product_name': 'Bad row',
          },
        ]
        ..['picklist_customers'] = <dynamic>[];
      final path = await writeBackup(data);

      await expectLater(
        DataImporter.importFromJson(
          db,
          path,
          requestingUserId: 'owner-1',
        ),
        throwsException,
      );

      final unchanged = await db.query('picklists');
      expect(unchanged.single['id'], 'keep-picklist');
      expect(await db.query('picklist_items'), isEmpty);
    },
  );

  test('a cashier cannot restore a backup', () async {
    final path = await writeBackup(buildBackup(version: 7));

    await expectLater(
      DataImporter.importFromJson(db, path, requestingUserId: 'cashier-9'),
      throwsException,
    );
  });

  test('restores void_requests from a v8 backup', () async {
    final now = DateTime.now().toIso8601String();
    final data = buildBackup(version: 8)
      ..['void_requests'] = [
        {
          'id': 'vr-1',
          'sale_id': 'sale-1',
          'requested_by': 'owner-1',
          'reason': 'wrong price',
          'status': 'PENDING',
          'created_at': now,
          'decided_by': null,
          'decided_at': null,
        },
      ];
    final path = await writeBackup(data);

    await DataImporter.importFromJson(db, path, requestingUserId: 'owner-1');

    final request = (await db.query('void_requests')).single;
    expect(request['sale_id'], 'sale-1');
    expect(request['status'], 'PENDING');
    expect(request['reason'], 'wrong price');
  });

  test('v6 and v7 backups restore with an empty void_requests table', () async {
    // void_requests was introduced in schema 8; older backups omit it.
    final path = await writeBackup(buildBackup(version: 7));

    await DataImporter.importFromJson(db, path, requestingUserId: 'owner-1');

    expect(await db.query('void_requests'), isEmpty);
  });

  test('rejects a malformed void_requests record', () async {
    final data = buildBackup(version: 8)
      ..['void_requests'] = [
        {
          // Missing reason and status.
          'id': 'vr-bad',
          'sale_id': 'sale-1',
          'requested_by': 'owner-1',
          'created_at': DateTime.now().toIso8601String(),
        },
      ];
    final path = await writeBackup(data);

    await expectLater(
      DataImporter.importFromJson(db, path, requestingUserId: 'owner-1'),
      throwsException,
    );
    // Original data untouched.
    expect(await db.query('sales'), isEmpty);
  });

  // Audit #7: a plaintext backup must never carry replayable credentials or
  // licensing / session / device-identity secrets.
  test('export strips password_hash/salt and licensing secrets (#7)', () async {
    await db.insert('users', {
      'id': 'cashier-1',
      'username': 'sak',
      'password_hash': 'SECRET_HASH_SENTINEL',
      'salt': 'SECRET_SALT_SENTINEL',
      'role': 'CASHIER',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    for (final kv in const {
      'auth_session': 'SESSION_SENTINEL',
      'license_code': 'LICENSE_SENTINEL',
      'activation_code': 'ACTIVATION_SENTINEL',
      'device_hw_uuid': 'HWUUID_SENTINEL',
      'device_install_uuid': 'INSTALLUUID_SENTINEL',
      'theme_mode': 'light',
    }.entries) {
      await db.insert('settings', {'key': kv.key, 'value': kv.value});
    }

    final path = await DataExporter.exportToJson(
      db,
      requestingUserId: 'owner-1',
    );
    final raw = await File(path).readAsString();
    final data = jsonDecode(raw) as Map<String, dynamic>;

    // No user row carries a credential column, and no sentinel value leaks.
    for (final row in data['users'] as List) {
      expect((row as Map).containsKey('password_hash'), isFalse);
      expect(row.containsKey('salt'), isFalse);
    }
    // Only the safe setting survives; every secret key is dropped.
    final settingKeys = (data['settings'] as List)
        .map((r) => (r as Map)['key'])
        .toSet();
    expect(settingKeys, contains('theme_mode'));
    for (final secret in const [
      'auth_session',
      'license_code',
      'activation_code',
      'device_hw_uuid',
      'device_install_uuid',
    ]) {
      expect(settingKeys.contains(secret), isFalse);
    }
    for (final sentinel in const [
      'SECRET_HASH_SENTINEL',
      'SECRET_SALT_SENTINEL',
      'SESSION_SENTINEL',
      'LICENSE_SENTINEL',
      'ACTIVATION_SENTINEL',
      'HWUUID_SENTINEL',
      'INSTALLUUID_SENTINEL',
    ]) {
      expect(raw.contains(sentinel), isFalse, reason: 'leaked $sentinel');
    }
  });

  // A hash-free (safe) backup still restores: the owner keeps their live
  // password, every other account is re-seeded to an unusable hash.
  test(
    'restore re-seeds a hash-free backup; owner kept, others locked',
    () async {
      final now = DateTime.now().toIso8601String();
      final data = buildBackup(version: 8)
        ..['users'] = [
          {
            'id': 'owner-1',
            'username': 'owner',
            'role': 'OWNER',
            'is_active': 1,
            'created_at': now,
          },
          {
            'id': 'cashier-1',
            'username': 'sak',
            'role': 'CASHIER',
            'is_active': 1,
            'created_at': now,
          },
        ];
      final path = await writeBackup(data);

      await DataImporter.importFromJson(db, path, requestingUserId: 'owner-1');

      final users = await db.query('users');
      final owner = users.firstWhere((u) => u['id'] == 'owner-1');
      final cashier = users.firstWhere((u) => u['id'] == 'cashier-1');
      // Owner keeps the live credential seeded in setUp ('x'/'x').
      expect(owner['password_hash'], 'x');
      expect(owner['salt'], 'x');
      // Cashier gets a well-formed but random digest that no password matches.
      expect(cashier['password_hash'], isNotNull);
      expect(cashier['password_hash'], startsWith('pbkdf2-sha256\$'));
      expect(cashier['password_hash'], isNot('x'));
      expect(cashier['salt'], isNotNull);
    },
  );

  // Feature permissions are non-secret and must survive export → import so a
  // restored staff account keeps exactly the tabs the owner ticked.
  test('permissions round-trip through export/import', () async {
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'cashier-1',
      'username': 'sak',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'CASHIER',
      'is_active': 1,
      'permissions': jsonEncode(['pos', 'finance']),
      'created_at': now,
    });

    final path = await DataExporter.exportToJson(
      db,
      requestingUserId: 'owner-1',
    );
    final data =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    final exported = (data['users'] as List).firstWhere(
      (u) => (u as Map)['id'] == 'cashier-1',
    ) as Map<String, dynamic>;
    expect(exported['permissions'], jsonEncode(['pos', 'finance']));

    await DataImporter.importFromJson(db, path, requestingUserId: 'owner-1');

    final cashier = (await db.query(
      'users',
      where: 'id = ?',
      whereArgs: ['cashier-1'],
    )).single;
    expect(cashier['permissions'], jsonEncode(['pos', 'finance']));
  });

  test(
    'backups predating the permissions column restore with defaults',
    () async {
      // buildBackup users carry no permissions key at all (schema ≤10 exports).
      final now = DateTime.now().toIso8601String();
      final data = buildBackup(version: 10)
        ..['users'] = [
          ...buildBackup(version: 10)['users'] as List,
          {
            'id': 'cashier-1',
            'username': 'sak',
            'role': 'CASHIER',
            'is_active': 1,
            'created_at': now,
          },
        ];
      final path = await writeBackup(data);

      await DataImporter.importFromJson(db, path, requestingUserId: 'owner-1');

      final owner = (await db.query(
        'users',
        where: 'id = ?',
        whereArgs: ['owner-1'],
      )).single;
      final cashier = (await db.query(
        'users',
        where: 'id = ?',
        whereArgs: ['cashier-1'],
      )).single;
      // Owners bypass the tick list; staff get today's cashier matrix.
      expect(jsonDecode(owner['permissions'] as String), isEmpty);
      expect(jsonDecode(cashier['permissions'] as String), [
        'pos',
        'register',
        'reports',
      ]);
    },
  );

  // F-001: restoring a backup must not leave stale unsynced outbox rows,
  // orphaned proof photos, or stale sync cursors that would cause the next
  // drain to re-push pre-restore state to the cloud.
  test(
    'restore clears the sync outbox, movement photos and sync cursors',
    () async {
      // Stale pre-restore state that must not survive the restore.
      await db.insert('sync_outbox', {
        'id': 'outbox-1',
        'entity_type': 'sale',
        'entity_id': 'sale-1',
        'operation': 'UPSERT',
        'payload': '{}',
        'created_at': DateTime.now().toIso8601String(),
        'synced_at': null,
      });
      await db.insert('shifts', {
        'id': 'shift-1',
        'cashier_id': 'owner-1',
        'opening_cash_minor_units': 0,
        'status': 'OPEN',
        'opened_at': DateTime.now().toIso8601String(),
      });
      await db.insert('cash_movements', {
        'id': 'move-1',
        'shift_id': 'shift-1',
        'type': 'DEPOSIT',
        'amount_minor_units': 1000,
        'reason': 'Float top-up',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('cash_movement_photos', {
        'movement_id': 'move-1',
        'jpeg_bytes': Uint8List.fromList([1, 2, 3]),
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('settings', {
        'key': 'sync_cursor.sales',
        'value': '{"received_at":"2026-01-01T00:00:00Z","id":"sale-1"}',
      });

      final path = await writeBackup(buildBackup(version: 8));
      await DataImporter.importFromJson(db, path, requestingUserId: 'owner-1');

      expect(await db.query('sync_outbox'), isEmpty);
      expect(await db.query('cash_movement_photos'), isEmpty);
      final cursors = await db.query(
        'settings',
        where: 'key LIKE ?',
        whereArgs: ['sync_cursor.%'],
      );
      expect(cursors, isEmpty);
      // Non-secret theme setting survives.
      expect(
        (await db.query("settings", where: "key = 'theme_mode'")).isNotEmpty,
        isTrue,
      );
    },
  );
}
