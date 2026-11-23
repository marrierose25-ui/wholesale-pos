import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pos_core/finance.dart';
import 'package:pos_core/sales.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';
/// Stage 6.0 characterisation of the write transactions in the repository
/// layer.
///
/// Every test induces a genuine SQLite failure *after* earlier statements in
/// the same repository method have already written. The assertion is always
/// that none of those earlier writes survived: no partial sale, no movement
/// without its audit/outbox row, no tombstones without their reversal.
///
/// Failures are induced with test-only `RAISE(ABORT)` triggers installed on the
/// in-memory database. The triggers never exist in production and no repository
/// code is aware of them.
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
    tempDir = await Directory.systemTemp.createTemp('stage60_rollback_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    db = await LocalDatabase.openInMemory();
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'owner-1',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'OWNER',
      'is_active': 1,
      'created_at': now,
    });
    await db.insert('users', {
      'id': 'cashier-1',
      'username': 'cashier',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'CASHIER',
      'is_active': 1,
      'permissions': '[]',
      'created_at': now,
    });
    await db.insert('devices', {
      'id': 'device-1',
      'name': 'PC',
      'platform': 'Windows',
    });
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'owner-1',
      'opening_cash_minor_units': 10000,
      'status': 'OPEN',
      'opened_at': now,
    });
  });

  tearDown(() async {
    await db.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows can hold the SQLite handle for a moment.
    }
  });

  Future<void> failOn(String triggerSql) => db.execute(triggerSql);

  Future<int> count(String table) async {
    final rows = await db.rawQuery('SELECT COUNT(*) FROM $table');
    return rows.first.values.first as int;
  }

  Sale buildSale({
    String id = 'sale-1',
    String receiptNumber = 'REC-1',
    required List<SaleItem> items,
    int total = 5000,
  }) {
    return Sale(
      id: id,
      receiptNumber: receiptNumber,
      cashierId: 'cashier-1',
      deviceId: 'device-1',
      shiftId: 'shift-1',
      subtotalMinorUnits: total,
      discountMinorUnits: 0,
      totalMinorUnits: total,
      amountPaidMinorUnits: total,
      changeMinorUnits: 0,
      createdAt: DateTime.now(),
      items: items,
    );
  }

  SaleItem line({
    String id = 'line-1',
    String saleId = 'sale-1',
    int unitPrice = 5000,
    int total = 5000,
  }) {
    return SaleItem(
      id: id,
      saleId: saleId,
      productId: 'product-1',
      productNameSnapshot: 'Sugar',
      unitPriceSnapshotMinorUnits: unitPrice,
      quantityText: '1',
      billingQuantityMilliunits: 1000,
      lineTotalMinorUnits: total,
    );
  }

  group('sales', () {
    test('saveSale rolls back the sale, lines, audit and outbox', () async {
      // The second line reuses the first line's primary key, so SQLite raises
      // UNIQUE after the sale row, the first line, and the first line's index
      // entry have already been written.
      final sale = buildSale(
        items: [
          line(id: 'duplicate-line', unitPrice: 2500, total: 2500),
          line(id: 'duplicate-line', unitPrice: 2500, total: 2500),
        ],
      );

      await expectLater(
        SqfliteSaleRepository(db).saveSale(sale),
        throwsA(isA<DatabaseException>()),
      );

      expect(await count('sales'), 0);
      expect(await count('sale_items'), 0);
      expect(await count('audit_logs'), 0);
      expect(await count('sync_outbox'), 0);
    });

    test('voidSale rolls back the sale update when the audit insert fails',
        () async {
      await SqfliteSaleRepository(db).saveSale(
        buildSale(items: [line()]),
      );
      await db.insert('void_requests', {
        'id': 'request-1',
        'sale_id': 'sale-1',
        'requested_by': 'cashier-1',
        'reason': 'wrong item',
        'status': 'PENDING',
        'created_at': DateTime.now().toIso8601String(),
      });
      final outboxBefore = await count('sync_outbox');

      await failOn('''
        CREATE TRIGGER fail_sale_void
        BEFORE INSERT ON audit_logs
        WHEN NEW.action = 'SALE_VOIDED'
        BEGIN SELECT RAISE(ABORT, 'induced audit failure'); END;
      ''');

      await expectLater(
        SqfliteSaleRepository(db).voidSale('sale-1', 'owner-1', 'mistake'),
        throwsA(isA<DatabaseException>()),
      );

      final sale = (await db.query('sales')).single;
      expect(sale['status'], 'COMPLETED');
      expect(sale['void_reason'], isNull);
      expect(sale['voided_at'], isNull);
      final request = (await db.query('void_requests')).single;
      expect(request['status'], 'PENDING');
      expect(request['decided_by'], isNull);
      expect(await count('sync_outbox'), outboxBefore);
    });

    test('approveVoidRequest rolls back both the sale and the decision',
        () async {
      await SqfliteSaleRepository(db).saveSale(buildSale(items: [line()]));
      await SqfliteSaleRepository(db).requestVoid('sale-1', 'cashier-1', 'duplicate');
      final request = (await db.query('void_requests')).single;

      await failOn('''
        CREATE TRIGGER fail_void_approval
        BEFORE INSERT ON audit_logs
        WHEN NEW.action = 'VOID_REQUEST_APPROVED'
        BEGIN SELECT RAISE(ABORT, 'induced approval failure'); END;
      ''');

      await expectLater(
        SqfliteSaleRepository(db).approveVoidRequest(
          request['id'] as String,
          'owner-1',
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect((await db.query('sales')).single['status'], 'COMPLETED');
      final after = (await db.query('void_requests')).single;
      expect(after['status'], 'PENDING');
      expect(after['decided_by'], isNull);
    });
  });

  group('finance', () {
    Future<FinanceEntry> addCashEntry(FinanceRepository repository) async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Supplier',
      );
      return repository.addEntry(
        ownerId: 'owner-1',
        categoryId: category.id,
        source: 'Cash drawer',
        amountMinorUnits: 5000,
        paymentMethod: 'CASH',
      );
    }

    test('markCompleted rolls back the status and outbox when the deposit fails',
        () async {
      final repository = SqfliteFinanceRepository(db);
      final entry = await addCashEntry(repository);
      final outboxBefore = await count('sync_outbox');

      await failOn('''
        CREATE TRIGGER fail_cash_deposit
        BEFORE INSERT ON cash_movements
        BEGIN SELECT RAISE(ABORT, 'induced deposit failure'); END;
      ''');

      await expectLater(
        repository.markCompleted(ownerId: 'owner-1', entryId: entry.id),
        throwsA(isA<DatabaseException>()),
      );

      final row = (await db.query('finance_entries')).single;
      expect(row['status'], FinanceEntry.statusPending);
      expect(row['completed_at'], isNull);
      expect(row['completed_by'], isNull);
      expect(await count('cash_movements'), 0);
      expect(await count('sync_outbox'), outboxBefore);
    });

    test('deleteEntry rolls back the reversal when the tombstone update fails',
        () async {
      final repository = SqfliteFinanceRepository(db);
      final entry = await addCashEntry(repository);
      await repository.markCompleted(ownerId: 'owner-1', entryId: entry.id);
      expect(await count('cash_movements'), 1);

      await failOn('''
        CREATE TRIGGER fail_entry_tombstone
        BEFORE UPDATE ON finance_entries
        WHEN NEW.status = 'DELETED'
        BEGIN SELECT RAISE(ABORT, 'induced tombstone failure'); END;
      ''');

      await expectLater(
        repository.deleteEntry(ownerId: 'owner-1', entryId: entry.id),
        throwsA(isA<DatabaseException>()),
      );

      // The WITHDRAWAL inserted before the update is gone, and the entry is
      // still COMPLETED rather than half-deleted.
      final movements = await db.query('cash_movements');
      expect(movements, hasLength(1));
      expect(movements.single['type'], 'DEPOSIT');
      final row = (await db.query('finance_entries')).single;
      expect(row['status'], FinanceEntry.statusCompleted);
    });
  });

  group('register', () {
    test('addCashMovement rolls back the movement and proof photo', () async {
      await failOn('''
        CREATE TRIGGER fail_cash_movement_audit
        BEFORE INSERT ON audit_logs
        WHEN NEW.action = 'CASH_MOVEMENT_ADDED'
        BEGIN SELECT RAISE(ABORT, 'induced movement failure'); END;
      ''');

      await expectLater(
        SqfliteShiftRepository(db).addCashMovement(
          'shift-1',
          'EXPENSE',
          2500,
          'Cleaning supplies',
          userId: 'owner-1',
          photo: base64Encode([1, 2, 3, 4]),
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect(await count('cash_movements'), 0);
      expect(await count('cash_movement_photos'), 0);
      expect(await count('audit_logs'), 0);
      expect(await count('sync_outbox'), 0);
    });

    test('closeShift leaves the drawer OPEN when its audit fails', () async {
      final repository = SqfliteShiftRepository(db);
      final shift = (await repository.getActiveShift())!;

      await failOn('''
        CREATE TRIGGER fail_shift_close
        BEFORE INSERT ON audit_logs
        WHEN NEW.action = 'SHIFT_CLOSED'
        BEGIN SELECT RAISE(ABORT, 'induced close failure'); END;
      ''');

      await expectLater(
        repository.closeShift(shift, 12000, userId: 'owner-1'),
        throwsA(isA<DatabaseException>()),
      );

      final row = (await db.query('shifts')).single;
      expect(row['status'], 'OPEN');
      expect(row['closing_cash_minor_units'], isNull);
      expect(row['closed_at'], isNull);
    });
  });

  group('restore', () {
    Map<String, dynamic> buildBackup() {
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
        'products': [
          {
            'id': 'restored-product',
            'name': 'Restored Sugar',
            'code': 'RESTORED-1',
            'unit': 'kg',
            'selling_price_minor_units': 1000,
            'is_active': 1,
            'created_at': now,
            'updated_at': now,
          },
        ],
        'sales': <dynamic>[],
        'sale_items': <dynamic>[],
        'shifts': <dynamic>[],
        'cash_movements': <dynamic>[],
        'audit_logs': <dynamic>[],
        'devices': [
          {'id': 'restored-device', 'name': 'Restored', 'platform': 'Windows'},
        ],
        'counters': <dynamic>[],
        'settings': <dynamic>[],
      };
    }

    Future<String> writeBackup(Map<String, dynamic> data) async {
      final path = '${tempDir.path}/backup.json';
      await File(path).writeAsString(jsonEncode(data));
      return path;
    }

    test('a failure mid-restore rolls back the deletes and re-inserts',
        () async {
      // Pre-restore trading data that must still be there afterwards.
      await db.insert('products', {
        'id': 'local-product',
        'name': 'Local Sugar',
        'code': 'LOCAL-1',
        'unit': 'kg',
        'selling_price_minor_units': 2000,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      await failOn('''
        CREATE TRIGGER fail_restore_sales
        BEFORE INSERT ON sales
        BEGIN SELECT RAISE(ABORT, 'induced restore failure'); END;
      ''');

      final backup = buildBackup()
        ..['sales'] = [
          {
            'id': 'restored-sale',
            'receipt_number': 'REC-R',
            'cashier_id': 'owner-1',
            'device_id': 'restored-device',
            'payment_method': 'CASH',
            'subtotal_minor_units': 1000,
            'discount_minor_units': 0,
            'total_minor_units': 1000,
            'amount_paid_minor_units': 1000,
            'change_minor_units': 0,
            'status': 'COMPLETED',
            'created_at': DateTime.now().toIso8601String(),
          },
        ];

      await expectLater(
        DataImporter.importFromJson(
          db,
          await writeBackup(backup),
          requestingUserId: 'owner-1',
        ),
        throwsA(anything),
      );

      final products = await db.query('products');
      expect(products, hasLength(1));
      expect(products.single['id'], 'local-product');
      expect(await count('sales'), 0);
      expect(await count('devices'), 1);
      expect((await db.query('devices')).single['id'], 'device-1');

      // The recovery snapshot is written before the replacement transaction,
      // so it survives a failed restore and contains the pre-restore row.
      final recoveryFiles = tempDir
          .listSync()
          .whereType<File>()
          .where((file) =>
              file.uri.pathSegments.last.startsWith('wholesale_pos_backup_'))
          .toList();
      expect(recoveryFiles, isNotEmpty);
      final recovery =
          jsonDecode(recoveryFiles.first.readAsStringSync()) as Map;
      expect(
        ((recovery['products'] as List).single as Map)['id'],
        'local-product',
      );
    });

    test('a foreign-key violation also rolls the whole restore back', () async {
      await db.insert('products', {
        'id': 'local-product',
        'name': 'Local Sugar',
        'code': 'LOCAL-1',
        'unit': 'kg',
        'selling_price_minor_units': 2000,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      final backup = buildBackup()
        ..['sales'] = [
          {
            'id': 'orphan-sale',
            'receipt_number': 'REC-X',
            'cashier_id': 'missing-user',
            'device_id': 'restored-device',
            'payment_method': 'CASH',
            'subtotal_minor_units': 1000,
            'discount_minor_units': 0,
            'total_minor_units': 1000,
            'amount_paid_minor_units': 1000,
            'change_minor_units': 0,
            'status': 'COMPLETED',
            'created_at': DateTime.now().toIso8601String(),
          },
        ];

      await expectLater(
        DataImporter.importFromJson(
          db,
          await writeBackup(backup),
          requestingUserId: 'owner-1',
        ),
        throwsA(anything),
      );

      expect((await db.query('products')).single['id'], 'local-product');
      expect(await count('sales'), 0);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    });
  });
}
