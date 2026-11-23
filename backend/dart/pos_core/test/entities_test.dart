import 'package:pos_core/pos_core.dart';
import 'package:test/test.dart';

void main() {
  group('SaleItem', () {
    test('preserves manual-entry fields verbatim', () {
      final item = SaleItem(
        id: 'i1',
        saleId: 's1',
        productId: 'p1',
        productNameSnapshot: 'Teff (Berbere) 1kg',
        unitPriceSnapshotMinorUnits: 12000,
        quantityText: '2 boxes and 1 piece',
        billingQuantityMilliunits: null,
        lineTotalMinorUnits: 95000,
        notes: 'negotiated price',
      );

      expect(item.hasManualLineTotal, isTrue);
      expect(item.quantityText, '2 boxes and 1 piece');
      expect(item.lineTotalMinorUnits, 95000);

      final map = item.toMap();
      expect(map['quantity_text'], '2 boxes and 1 piece');
      expect(map['billing_quantity_milliunits'], isNull);
      expect(map['line_total_minor_units'], 95000);
      expect(map['notes'], 'negotiated price');
    });

    test('fromMap tolerates double-typed numerics from JSON', () {
      final item = SaleItem.fromMap({
        'id': 'i1',
        'sale_id': 's1',
        'product_id': 'p1',
        'product_name_snapshot': 'Sugar 1kg',
        'unit_price_snapshot_minor_units': 11000.0,
        'quantity_text': '3',
        'billing_quantity_milliunits': 3000.0,
        'line_discount_minor_units': 0.0,
        'line_total_minor_units': 33000.0,
      });

      expect(item.unitPriceSnapshotMinorUnits, 11000);
      expect(item.billingQuantityMilliunits, 3000);
      expect(item.hasManualLineTotal, isFalse);
      expect(item.lineTotalMinorUnits, 33000);
    });

    test('round-trips through toMap/fromMap', () {
      final original = SaleItem(
        id: 'i2',
        saleId: 's2',
        productId: 'p2',
        productNameSnapshot: 'Rice 5kg',
        unitPriceSnapshotMinorUnits: 1450000,
        quantityText: '1.5',
        billingQuantityMilliunits: 1500,
        lineDiscountMinorUnits: 5000,
        lineTotalMinorUnits: 2167500,
        notes: null,
      );
      final restored = SaleItem.fromMap(original.toMap());
      expect(restored.id, original.id);
      expect(restored.quantityText, original.quantityText);
      expect(restored.billingQuantityMilliunits, 1500);
      expect(restored.lineTotalMinorUnits, 2167500);
      expect(restored.notes, isNull);
    });
  });

  group('Sale', () {
    test('toMap emits the persisted column names', () {
      final sale = Sale(
        id: 's1',
        receiptNumber: 'R-0001',
        cashierId: 'u1',
        deviceId: 'dev1',
        shiftId: 'sh1',
        customerName: 'Abebe Kebede',
        paymentMethod: 'BANK',
        subtotalMinorUnits: 100000,
        discountMinorUnits: 5000,
        totalMinorUnits: 95000,
        amountPaidMinorUnits: 100000,
        changeMinorUnits: 5000,
        status: 'COMPLETED',
        createdAt: DateTime(2026, 11, 18, 10, 30),
        items: const [],
      );

      final map = sale.toMap();
      expect(map['receipt_number'], 'R-0001');
      expect(map['cashier_id'], 'u1');
      expect(map['payment_method'], 'BANK');
      expect(map['total_minor_units'], 95000);
      expect(map['created_at'], '2026-11-18T10:30:00.000');
      expect(map['voided_at'], isNull);
      expect(map['synced_at'], isNull);
    });

    test('defaults preserve prior behavior', () {
      final sale = Sale(
        id: 's',
        receiptNumber: 'r',
        cashierId: 'c',
        deviceId: 'd',
        shiftId: 'sh',
        subtotalMinorUnits: 0,
        discountMinorUnits: 0,
        totalMinorUnits: 0,
        amountPaidMinorUnits: 0,
        changeMinorUnits: 0,
        createdAt: DateTime(2026),
        items: const [],
      );
      expect(sale.paymentMethod, 'CASH');
      expect(sale.status, 'COMPLETED');
      expect(sale.hasPendingVoidRequest, isFalse);
    });
  });

  group('Shift', () {
    test('discrepancy is null while open and computed when closed', () {
      final open = Shift(
        id: 'sh1',
        cashierId: 'u1',
        openingCashMinorUnits: 50000,
        status: 'OPEN',
        openedAt: DateTime(2026, 11, 18),
      );
      expect(open.discrepancy, isNull);

      final closed = Shift(
        id: 'sh2',
        cashierId: 'u1',
        openingCashMinorUnits: 50000,
        closingCashMinorUnits: 120000,
        expectedCashMinorUnits: 115000,
        status: 'CLOSED',
        openedAt: DateTime(2026, 11, 17),
        closedAt: DateTime(2026, 11, 18),
      );
      expect(closed.discrepancy, 5000);
    });

    test('fromMap tolerates double cash values', () {
      final shift = Shift.fromMap({
        'id': 'sh',
        'cashier_id': 'u',
        'opening_cash_minor_units': 50000.0,
        'closing_cash_minor_units': 100000.0,
        'expected_cash_minor_units': 99000.0,
        'status': 'CLOSED',
        'opened_at': '2026-11-17T08:00:00.000',
        'closed_at': '2026-11-18T20:00:00.000',
        'cashier_name': 'Owner',
      });
      expect(shift.openingCashMinorUnits, 50000);
      expect(shift.closingCashMinorUnits, 100000);
      expect(shift.cashierName, 'Owner');
      expect(shift.discrepancy, 1000);
    });
  });

  group('CashMovement', () {
    test('isDeposit reflects the movement type', () {
      CashMovement movement(String type) => CashMovement(
        id: 'm',
        shiftId: 'sh',
        type: type,
        amountMinorUnits: 1000,
        reason: 'r',
        createdAt: DateTime(2026),
      );
      expect(movement('DEPOSIT').isDeposit, isTrue);
      expect(movement('WITHDRAWAL').isDeposit, isFalse);
      expect(movement('EXPENSE').isDeposit, isFalse);
    });

    test('fromMap hydrates photo and user name', () {
      final m = CashMovement.fromMap({
        'id': 'm1',
        'shift_id': 'sh1',
        'type': 'WITHDRAWAL',
        'amount_minor_units': 25000,
        'reason': 'supplier cash',
        'created_at': '2026-11-18T12:00:00.000',
        'photo': 'aGk=',
        'user_name': 'Cashier One',
      });
      expect(m.amountMinorUnits, 25000);
      expect(m.photo, 'aGk=');
      expect(m.userName, 'Cashier One');
      expect(m.isDeposit, isFalse);
    });
  });

  group('VoidRequest', () {
    test('status constants and isPending', () {
      VoidRequest request(String status) => VoidRequest(
        id: 'v',
        saleId: 's',
        requestedBy: 'u',
        reason: 'mistake',
        status: status,
        createdAt: DateTime(2026),
      );
      expect(request(VoidRequest.statusPending).isPending, isTrue);
      expect(request(VoidRequest.statusApproved).isPending, isFalse);
      expect(request(VoidRequest.statusRejected).isPending, isFalse);
    });
  });

  group('Product', () {
    test('round-trips through toMap/fromMap', () {
      final now = DateTime(2026, 11, 18);
      final product = Product(
        id: 'p1',
        name: 'Teff (Berbere) 1kg',
        code: 'TEFF-1',
        category: 'Grains',
        unit: 'kg',
        sellingPriceMinorUnits: 12000,
        isActive: true,
        createdAt: now,
        updatedAt: now,
      );
      final restored = Product.fromMap(product.toMap());
      expect(restored.name, product.name);
      expect(restored.sellingPriceMinorUnits, 12000);
      expect(restored.isActive, isTrue);
      expect(restored.code, 'TEFF-1');
    });

    test('fromMap tolerates double numerics and missing updated_at', () {
      final p = Product.fromMap({
        'id': 'p',
        'name': 'Sugar',
        'code': null,
        'unit': null,
        'selling_price_minor_units': 11000.0,
        'is_active': 0.0,
        'created_at': '2026-01-01T00:00:00.000',
      });
      expect(p.sellingPriceMinorUnits, 11000);
      expect(p.isActive, isFalse);
      expect(p.code, '');
      expect(p.unit, '');
      expect(p.updatedAt, DateTime(2026, 1, 1));
    });
  });

  group('User', () {
    test('can() grants owner everything, staff only ticked features', () {
      final owner = User(
        id: 'o',
        username: 'owner',
        passwordHash: 'h',
        salt: 's',
        role: 'OWNER',
      );
      final cashier = User(
        id: 'c',
        username: 'cashier',
        passwordHash: 'h',
        salt: 's',
        role: 'CASHIER',
        permissions: const ['pos', 'register'],
      );
      expect(owner.can('finance'), isTrue);
      expect(owner.can('anything'), isTrue);
      expect(cashier.can('pos'), isTrue);
      expect(cashier.can('finance'), isFalse);
    });

    test('decodePermissions tolerates list, JSON string, and null', () {
      expect(User.decodePermissions(null), isEmpty);
      expect(User.decodePermissions(['pos', 'register']), ['pos', 'register']);
      expect(User.decodePermissions('["pos","warehouse"]'), [
        'pos',
        'warehouse',
      ]);
      expect(User.decodePermissions('not json'), isEmpty);
      expect(User.decodePermissions(''), isEmpty);
    });

    test('fromMap round-trips permissions and demo flag', () {
      final user = User(
        id: 'u1',
        username: '0912345678',
        passwordHash: 'hash',
        salt: 'salt',
        role: 'CASHIER',
        isActive: true,
        permissions: const ['pos'],
        isDemo: true,
      );
      final restored = User.fromMap(user.toMap());
      expect(restored.username, '0912345678');
      expect(restored.permissions, ['pos']);
      expect(restored.isDemo, isTrue);
    });
  });

  group('FinanceCategory', () {
    test('isDeleted reflects deletedAt', () {
      final active = FinanceCategory(
        id: 'c',
        name: 'Abebe',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      final deleted = FinanceCategory(
        id: 'c2',
        name: 'Kebede',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        deletedAt: DateTime(2026, 11),
      );
      expect(active.isDeleted, isFalse);
      expect(deleted.isDeleted, isTrue);
    });
  });

  group('FinanceEntry', () {
    test('status helpers and cash detection', () {
      FinanceEntry entry(String status, String? method) => FinanceEntry(
        id: 'e',
        categoryId: 'c',
        source: 'Bank',
        amountMinorUnits: 50000,
        status: status,
        entryDate: DateTime(2026),
        createdAt: DateTime(2026),
        createdBy: 'u',
        updatedAt: DateTime(2026),
        paymentMethod: method,
      );
      expect(entry(FinanceEntry.statusCompleted, 'CASH').isCompleted, isTrue);
      expect(entry(FinanceEntry.statusDeleted, null).isDeleted, isTrue);
      expect(entry(FinanceEntry.statusPending, 'CASH').isCash, isTrue);
      expect(entry(FinanceEntry.statusPending, 'BANK').isCash, isFalse);
    });
  });

  group('Picklist', () {
    test('status constants and isCompleted', () {
      Picklist list(String status) => Picklist(
        id: 'pl',
        customerName: 'Abebe',
        status: status,
        createdBy: 'u',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(list(Picklist.statusPending).isCompleted, isFalse);
      expect(list(Picklist.statusPartial).isCompleted, isFalse);
      expect(list(Picklist.statusCompleted).isCompleted, isTrue);
    });
  });

  group('PicklistItem', () {
    test('copyWith preserves identity and updates progress', () {
      final item = PicklistItem(
        id: 'i',
        picklistId: 'pl',
        productName: 'Sugar 1kg',
        requestedQty: 10,
        takenQty: 4,
        updatedAt: DateTime(2026),
        unit: 'kg',
        unitPriceMinorUnits: 11000,
        lineTotalMinorUnits: 110000,
      );
      expect(item.isFulfilled, isFalse);
      final updated = item.copyWith(takenQty: 10);
      expect(updated.id, item.id);
      expect(updated.takenQty, 10);
      expect(updated.isFulfilled, isTrue);
      expect(updated.lineTotalMinorUnits, 110000);
    });
  });

  group('PicklistCustomer', () {
    test('fromMap falls back to now on a missing stamp', () {
      final c = PicklistCustomer.fromMap({
        'id': 'c',
        'name': 'Abebe',
        'phone': '0912345678',
      });
      expect(c.name, 'Abebe');
      expect(c.phone, '0912345678');
      expect(c.createdAt, isNotNull);
    });
  });
}
