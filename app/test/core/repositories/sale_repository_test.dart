import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/features/sales/sale.dart';
import 'package:wholesale_pos_app/features/sales/sale_item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SaleRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = SaleRepository(db);

    // Insert foreign key dependencies
    await db.insert('users', {
      'id': 'user-1',
      'username': 'abebe',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'OWNER',
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('devices', {
      'id': 'device-1',
      'name': 'PC',
      'platform': 'Windows',
    });
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'user-1',
      'opening_cash_minor_units': 0,
      'status': 'OPEN',
      'opened_at': DateTime.now().toIso8601String(),
    });
  });

  tearDown(() async {
    await db.close();
  });

  Sale buildSale({
    required String id,
    required String receiptNumber,
    required List<SaleItem> items,
    String? customerName,
    int totalMinorUnits = 5000,
  }) {
    return Sale(
      id: id,
      receiptNumber: receiptNumber,
      cashierId: 'user-1',
      deviceId: 'device-1',
      shiftId: 'shift-1',
      customerName: customerName,
      subtotalMinorUnits: totalMinorUnits,
      discountMinorUnits: 0,
      totalMinorUnits: totalMinorUnits,
      amountPaidMinorUnits: totalMinorUnits,
      changeMinorUnits: 0,
      createdAt: DateTime.now(),
      items: items,
    );
  }

  test(
    'Saves a complete sale with numeric quantity lines transactionally',
    () async {
      final sale = buildSale(
        id: 'sale-1',
        receiptNumber: 'REC-001',
        totalMinorUnits: 5000,
        items: [
          SaleItem(
            id: 'item-1',
            saleId: 'sale-1',
            productId: 'prod-1',
            productNameSnapshot: 'Sugar',
            unitPriceSnapshotMinorUnits: 5000,
            quantityText: '1',
            billingQuantityMilliunits: 1000,
            lineTotalMinorUnits: 5000,
          ),
        ],
      );

      await repository.saveSale(sale);

      final sales = await db.query('sales');
      expect(sales.length, 1);

      final items = await db.query('sale_items');
      expect(items.length, 1);
      expect(items.first['quantity_text'], '1');
      expect(items.first['billing_quantity_milliunits'], 1000);

      final logs = await db.query('audit_logs');
      expect(logs.length, 1);
    },
  );

  test(
    'Saves a descriptive quantity with a manually entered line amount',
    () async {
      // "2 boxes and 1 piece" cannot be a number; the total was typed by hand
      // and the billing quantity is stored as NULL, never guessed.
      final sale = buildSale(
        id: 'sale-2',
        receiptNumber: 'REC-002',
        totalMinorUnits: 137500,
        customerName: 'Kebede Trading',
        items: [
          SaleItem(
            id: 'item-2',
            saleId: 'sale-2',
            productId: 'MANUAL',
            productNameSnapshot: 'Berbere',
            unitPriceSnapshotMinorUnits: 25000,
            quantityText: '2 boxes and 1 piece',
            billingQuantityMilliunits: null,
            lineTotalMinorUnits: 137500,
            notes: 'mixed boxes',
          ),
        ],
      );

      await repository.saveSale(sale);

      final items = await db.query('sale_items');
      expect(items.single['quantity_text'], '2 boxes and 1 piece');
      expect(items.single['billing_quantity_milliunits'], isNull);
      expect(items.single['notes'], 'mixed boxes');
    },
  );

  test('Rejects a line total that does not match price and quantity', () async {
    // The cashier described "2 boxes" but the total is for a single box.
    // The repository must refuse rather than silently misinterpret.
    final sale = buildSale(
      id: 'sale-3',
      receiptNumber: 'REC-003',
      totalMinorUnits: 5000,
      items: [
        SaleItem(
          id: 'item-3',
          saleId: 'sale-3',
          productId: 'prod-1',
          productNameSnapshot: 'Sugar',
          unitPriceSnapshotMinorUnits: 5000,
          quantityText: '2 boxes',
          billingQuantityMilliunits: 2000,
          lineTotalMinorUnits: 5000, // correct value would be 10000
        ),
      ],
    );

    await expectLater(repository.saveSale(sale), throwsException);
    expect(await db.query('sales'), isEmpty);
    expect(await db.query('sale_items'), isEmpty);
  });

  test('Rejects a manual line amount of zero', () async {
    final sale = buildSale(
      id: 'sale-4',
      receiptNumber: 'REC-004',
      totalMinorUnits: 0,
      items: [
        SaleItem(
          id: 'item-4',
          saleId: 'sale-4',
          productId: 'MANUAL',
          productNameSnapshot: 'Sugar',
          unitPriceSnapshotMinorUnits: 5000,
          quantityText: 'some bags',
          billingQuantityMilliunits: null,
          lineTotalMinorUnits: 0,
        ),
      ],
    );

    await expectLater(repository.saveSale(sale), throwsException);
    expect(await db.query('sales'), isEmpty);
  });

  test('rejects a sale when its referenced shift is closed', () async {
    await db.update(
      'shifts',
      {'status': 'CLOSED'},
      where: 'id = ?',
      whereArgs: ['shift-1'],
    );
    final sale = buildSale(
      id: 'closed-shift-sale',
      receiptNumber: 'REC-CLOSED',
      totalMinorUnits: 100,
      items: [
        SaleItem(
          id: 'closed-item',
          saleId: 'closed-shift-sale',
          productId: 'MANUAL',
          productNameSnapshot: 'Manual item',
          unitPriceSnapshotMinorUnits: 100,
          quantityText: '1',
          billingQuantityMilliunits: 1000,
          lineTotalMinorUnits: 100,
        ),
      ],
    );

    await expectLater(repository.saveSale(sale), throwsException);
    expect(await db.query('sales'), isEmpty);
    expect(await db.query('audit_logs'), isEmpty);
  });

  group('getSales search', () {
    late String sugarSaleId;
    late String flourSaleId;

    setUp(() async {
      sugarSaleId = 'sale-sugar';
      flourSaleId = 'sale-flour';
      await repository.saveSale(
        buildSale(
          id: sugarSaleId,
          receiptNumber: 'REC-SUGAR',
          totalMinorUnits: 5000,
          customerName: 'Kebede Trading',
          items: [
            SaleItem(
              id: 'item-sugar',
              saleId: sugarSaleId,
              productId: 'MANUAL',
              productNameSnapshot: 'Sugar 50kg',
              unitPriceSnapshotMinorUnits: 5000,
              quantityText: '1 bag',
              billingQuantityMilliunits: 1000,
              lineTotalMinorUnits: 5000,
              notes: 'deliver tomorrow',
            ),
          ],
        ),
      );
      await repository.saveSale(
        buildSale(
          id: flourSaleId,
          receiptNumber: 'REC-FLOUR',
          totalMinorUnits: 1500,
          items: [
            SaleItem(
              id: 'item-flour',
              saleId: flourSaleId,
              productId: 'MANUAL',
              productNameSnapshot: 'Flour',
              unitPriceSnapshotMinorUnits: 1500,
              quantityText: '1',
              billingQuantityMilliunits: 1000,
              lineTotalMinorUnits: 1500,
            ),
          ],
        ),
      );
    });

    test('finds sales by product name', () async {
      final sales = await repository.getSales(searchQuery: 'sugar');
      expect(sales.length, 1);
      expect(sales.first.id, sugarSaleId);
      expect(sales.first.items.first.productNameSnapshot, 'Sugar 50kg');
    });

    test('finds sales by customer name', () async {
      final sales = await repository.getSales(searchQuery: 'kebede');
      expect(sales.length, 1);
      expect(sales.first.id, sugarSaleId);
    });

    test('finds sales by cashier username', () async {
      final sales = await repository.getSales(searchQuery: 'abebe');
      expect(sales.length, 2);
    });

    test('finds sales by quantity text and notes', () async {
      expect((await repository.getSales(searchQuery: 'bag')).map((s) => s.id), [
        sugarSaleId,
      ]);
      expect(
        (await repository.getSales(searchQuery: 'deliver')).map((s) => s.id),
        [sugarSaleId],
      );
    });

    test('never matches receipt numbers', () async {
      // Receipt numbers are internal identifiers; searching them must find
      // nothing even though they exist on the rows.
      expect(await repository.getSales(searchQuery: 'REC-SUGAR'), isEmpty);
      expect(await repository.getSales(searchQuery: 'rec'), isEmpty);
    });

    test('LIKE wildcards in the query match literally', () async {
      expect(await repository.getSales(searchQuery: '%'), isEmpty);
      expect(await repository.getSales(searchQuery: '_'), isEmpty);
      expect(await repository.getSales(searchQuery: 'S_gar'), isEmpty);
    });

    test('filters by status', () async {
      await repository.voidSale(sugarSaleId, 'user-1', 'wrong entry');
      final voided = await repository.getSales(status: 'VOIDED');
      expect(voided.length, 1);
      expect(voided.first.id, sugarSaleId);
      final completed = await repository.getSales(status: 'COMPLETED');
      expect(completed.length, 1);
      expect(completed.first.id, flourSaleId);
    });
  });
  // F-002: native repository reads enforce feature-tick authorization, mirroring
  // the cloud pos-api RBAC. Owners bypass; staff must hold the relevant tick.
  group('F-002 authorization', () {
    Future<void> insertStaff({
      required String id,
      required String username,
      required List<String> permissions,
    }) async {
      await db.insert('users', {
        'id': id,
        'username': username,
        'password_hash': 'x',
        'salt': 'x',
        'role': 'CASHIER',
        'is_active': 1,
        'permissions': jsonEncode(permissions),
        'created_at': DateTime.now().toIso8601String(),
      });
    }

    test('getSales rejects staff without history/register_history', () async {
      await insertStaff(
        id: 'staff-no-ticks',
        username: 'sak',
        permissions: const [],
      );
      await expectLater(
        repository.getSales(userId: 'staff-no-ticks'),
        throwsException,
      );
      await insertStaff(
        id: 'staff-history',
        username: 'sak2',
        permissions: const ['history'],
      );
      expect(
        (await repository.getSales(userId: 'staff-history')).isEmpty,
        isTrue,
      );
      expect((await repository.getSales(userId: 'user-1')).isEmpty, isTrue);
    });

    test('getDashboardStats requires the dashboard tick', () async {
      await insertStaff(
        id: 'staff-no-ticks',
        username: 'sak',
        permissions: const [],
      );
      await expectLater(
        repository.getDashboardStats(userId: 'staff-no-ticks'),
        throwsException,
      );
      await insertStaff(
        id: 'staff-dashboard',
        username: 'sak3',
        permissions: const ['dashboard'],
      );
      expect(
        (await repository.getDashboardStats(userId: 'staff-dashboard'))
            .isNotEmpty,
        isTrue,
      );
      expect(
        (await repository.getDashboardStats(userId: 'user-1')).isNotEmpty,
        isTrue,
      );
    });

    test('getProductSalesSummary requires the reports tick', () async {
      await insertStaff(
        id: 'staff-no-ticks',
        username: 'sak',
        permissions: const [],
      );
      await expectLater(
        repository.getProductSalesSummary(userId: 'staff-no-ticks'),
        throwsException,
      );
      await insertStaff(
        id: 'staff-reports',
        username: 'sak4',
        permissions: const ['reports'],
      );
      expect(
        (await repository.getProductSalesSummary(userId: 'staff-reports'))
            .isEmpty,
        isTrue,
      );
      expect(
        (await repository.getProductSalesSummary(userId: 'user-1')).isEmpty,
        isTrue,
      );
    });

    test('getAuditLogs requires the audit tick', () async {
      await insertStaff(
        id: 'staff-no-ticks',
        username: 'sak',
        permissions: const [],
      );
      await expectLater(
        repository.getAuditLogs(userId: 'staff-no-ticks'),
        throwsException,
      );
      await insertStaff(
        id: 'staff-audit',
        username: 'sak5',
        permissions: const ['audit'],
      );
      expect(
        (await repository.getAuditLogs(userId: 'staff-audit')).isEmpty,
        isTrue,
      );
      expect((await repository.getAuditLogs(userId: 'user-1')).isEmpty, isTrue);
    });

    test('getPendingVoidRequests is owner-only', () async {
      await insertStaff(
        id: 'staff-no-ticks',
        username: 'sak',
        permissions: const [],
      );
      await expectLater(
        repository.getPendingVoidRequests(userId: 'staff-no-ticks'),
        throwsException,
      );
      expect(
        (await repository.getPendingVoidRequests(userId: 'user-1')).isEmpty,
        isTrue,
      );
    });
  });
}
