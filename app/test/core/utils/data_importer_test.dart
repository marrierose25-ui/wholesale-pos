import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/utils/data_exporter.dart';
import 'package:wholesale_pos_app/core/utils/data_importer.dart';

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
}
