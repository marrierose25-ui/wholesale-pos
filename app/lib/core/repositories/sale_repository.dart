import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../features/sales/sale.dart';
import '../../features/sales/sale_item.dart';
import '../../features/sales/shift.dart';
import 'shift_repository.dart';

class SaleRepository {
  final Database _db;

  SaleRepository(this._db);

  Future<void> saveSale(Sale sale) async {
    await _db.transaction((txn) async {
      final shifts = await txn.query(
        'shifts',
        columns: ['id'],
        where: "id = ? AND status = 'OPEN'",
        whereArgs: [sale.shiftId],
        limit: 1,
      );
      if (shifts.isEmpty) {
        throw Exception('Sale requires an open register shift.');
      }
      if (sale.receiptNumber.trim().isEmpty ||
          sale.items.isEmpty ||
          sale.totalMinorUnits < 0 ||
          sale.subtotalMinorUnits < 0 ||
          sale.discountMinorUnits < 0 ||
          sale.totalMinorUnits !=
              sale.subtotalMinorUnits - sale.discountMinorUnits ||
          !{'CASH', 'BANK'}.contains(sale.paymentMethod)) {
        throw Exception('Sale contains invalid totals or payment method.');
      }
      var itemSubtotal = 0;
      for (final item in sale.items) {
        if (item.productNameSnapshot.trim().isEmpty ||
            item.quantity <= 0 ||
            item.unitPriceSnapshotMinorUnits < 0 ||
            item.lineDiscountMinorUnits < 0 ||
            item.lineDiscountMinorUnits >
                item.unitPriceSnapshotMinorUnits * item.quantity ||
            item.lineTotalMinorUnits !=
                item.unitPriceSnapshotMinorUnits * item.quantity -
                    item.lineDiscountMinorUnits) {
          throw Exception('Sale contains an invalid line item.');
        }
        itemSubtotal += item.lineTotalMinorUnits;
      }
      if (itemSubtotal != sale.subtotalMinorUnits ||
          (sale.paymentMethod == 'CASH' &&
              (sale.amountPaidMinorUnits < sale.totalMinorUnits ||
                  sale.changeMinorUnits !=
                      sale.amountPaidMinorUnits - sale.totalMinorUnits)) ||
          (sale.paymentMethod == 'BANK' &&
              (sale.amountPaidMinorUnits != sale.totalMinorUnits ||
                  sale.changeMinorUnits != 0))) {
        throw Exception('Sale totals do not match the line items or payment.');
      }
      await txn.insert('sales', sale.toMap());

      for (final item in sale.items) {
        await txn.insert('sale_items', item.toMap());
      }

      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': sale.cashierId,
        'action': 'SALE_COMPLETED',
        'details':
            'Receipt: ${sale.receiptNumber}, Total: ${sale.totalMinorUnits}',
        'created_at': DateTime.now().toIso8601String(),
      });
    });
  }

  /// Reserves the next sequential receipt number for today, e.g.
  /// `REC-20261021-0007`. Numbers are allocated in a transaction so a retail
  /// audit can follow them in order.
  Future<String> nextReceiptNumber() async {
    final now = DateTime.now();
    final day =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final key = 'receipt-$day';

    final next = await _db.transaction((txn) async {
      final rows = await txn.query(
        'counters',
        columns: ['value'],
        where: 'name = ?',
        whereArgs: [key],
        limit: 1,
      );
      final value = rows.isEmpty ? 1 : (rows.first['value'] as int) + 1;
      await txn.insert('counters', {
        'name': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return value;
    });

    return 'REC-$day-${next.toString().padLeft(4, '0')}';
  }

  Future<void> voidSale(
    String saleId,
    String receiptNumber,
    String userId,
    String reason,
  ) async {
    if (reason.trim().isEmpty || reason.trim().length > 240) {
      throw Exception('A void reason of 1 to 240 characters is required.');
    }
    await _db.transaction((txn) async {
      final saleMaps = await txn.query(
        'sales',
        where: 'id = ?',
        whereArgs: [saleId],
      );
      if (saleMaps.isEmpty) {
        throw Exception('Sale not found');
      }
      if (saleMaps.first['status'] == 'VOIDED') {
        throw Exception('Sale is already voided');
      }

      final users = await txn.query(
        'users',
        columns: ['role', 'is_active'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (users.isEmpty ||
          users.first['role'] != 'OWNER' ||
          users.first['is_active'] != 1) {
        throw Exception('Only an active owner can void a sale.');
      }
      final activeShifts = await txn.query(
        'shifts',
        columns: ['id'],
        where: "status = 'OPEN'",
        limit: 1,
      );

      final updated = await txn.update(
        'sales',
        {
          'status': 'VOIDED',
          'void_reason': reason.trim(),
          'voided_at': DateTime.now().toIso8601String(),
          'voided_by': userId,
          'voided_shift_id': activeShifts.isEmpty
              ? null
              : activeShifts.first['id'],
        },
        where: "id = ? AND status != 'VOIDED'",
        whereArgs: [saleId],
      );
      if (updated != 1) {
        throw Exception('Sale is no longer voidable');
      }

      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': userId,
        'action': 'SALE_VOIDED',
        'details': 'Receipt: $receiptNumber, Reason: $reason',
        'created_at': DateTime.now().toIso8601String(),
      });
    });
  }

  Future<List<Sale>> getAllSales({
    String? searchQuery,
    DateTime? startDate,
    DateTime? endDate,
    int? limit,
  }) async {
    String whereClause = '';
    final List<dynamic> whereArgs = [];

    if (searchQuery != null && searchQuery.isNotEmpty) {
      whereClause = 'receipt_number LIKE ?';
      whereArgs.add('%$searchQuery%');
    }

    if (startDate != null && endDate != null) {
      if (whereClause.isNotEmpty) whereClause += ' AND ';
      // Add one day to endDate to make it inclusive.
      final end = endDate.add(const Duration(days: 1));
      whereClause += 'created_at >= ? AND created_at < ?';
      whereArgs.add(startDate.toIso8601String());
      whereArgs.add(end.toIso8601String());
    } else if (startDate != null) {
      if (whereClause.isNotEmpty) whereClause += ' AND ';
      whereClause += 'created_at >= ?';
      whereArgs.add(startDate.toIso8601String());
    }

    final saleMaps = await _db.query(
      'sales',
      where: whereClause.isNotEmpty ? whereClause : null,
      whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
      orderBy: 'created_at DESC',
      limit: limit,
    );

    return _hydrate(saleMaps);
  }

  Future<List<Sale>> getRecentSales({int limit = 5}) {
    return getAllSales(limit: limit);
  }

  /// Voids that must be reviewed at shift close. Mirrors the cash calculation
  /// in [ShiftRepository.getShiftSummary] exactly.
  Future<List<Sale>> getVoidedSalesForShift(String shiftId) async {
    final saleMaps = await _db.query(
      'sales',
      where:
          "status = 'VOIDED' AND "
          '(voided_shift_id = ? OR (voided_shift_id IS NULL AND shift_id = ?))',
      whereArgs: [shiftId, shiftId],
      orderBy: 'created_at DESC',
    );
    return _hydrate(saleMaps);
  }

  Future<List<Sale>> _hydrate(List<Map<String, Object?>> saleMaps) async {
    if (saleMaps.isEmpty) return [];

    final ids = saleMaps.map((map) => map['id'] as String).toList();
    final itemsBySale = <String, List<SaleItem>>{};
    const chunkSize = 400;
    for (var start = 0; start < ids.length; start += chunkSize) {
      final end = start + chunkSize > ids.length
          ? ids.length
          : start + chunkSize;
      final chunk = ids.sublist(start, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final itemMaps = await _db.query(
        'sale_items',
        where: 'sale_id IN ($placeholders)',
        whereArgs: chunk,
        orderBy: 'rowid ASC',
      );
      for (final row in itemMaps) {
        final item = SaleItem.fromMap(row);
        itemsBySale.putIfAbsent(item.saleId, () => []).add(item);
      }
    }

    return saleMaps.map((map) {
      final saleId = map['id'] as String;
      return Sale(
        id: saleId,
        receiptNumber: map['receipt_number'] as String,
        cashierId: map['cashier_id'] as String,
        deviceId: map['device_id'] as String,
        shiftId: map['shift_id'] as String? ?? '',
        customerName: map['customer_name'] as String?,
        paymentMethod: map['payment_method'] as String,
        subtotalMinorUnits: map['subtotal_minor_units'] as int,
        discountMinorUnits: map['discount_minor_units'] as int,
        totalMinorUnits: map['total_minor_units'] as int,
        amountPaidMinorUnits: map['amount_paid_minor_units'] as int,
        changeMinorUnits: map['change_minor_units'] as int,
        status: map['status'] as String,
        voidReason: map['void_reason'] as String?,
        voidedAt: map['voided_at'] == null
            ? null
            : DateTime.parse(map['voided_at'] as String),
        voidedBy: map['voided_by'] as String?,
        voidedShiftId: map['voided_shift_id'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
        syncedAt: map['synced_at'] != null
            ? DateTime.parse(map['synced_at'] as String)
            : null,
        items: itemsBySale[saleId] ?? const [],
      );
    }).toList();
  }

  Future<Map<String, int>> getDashboardStats() async {
    final today = DateTime.now().toIso8601String().split('T')[0];

    final revenueResult = await _db.rawQuery(
      "SELECT SUM(total_minor_units) as total FROM sales WHERE date(created_at) = ? AND status = 'COMPLETED'",
      [today],
    );

    final cashResult = await _db.rawQuery(
      "SELECT SUM(total_minor_units) as total FROM sales WHERE date(created_at) = ? AND status = 'COMPLETED' AND payment_method = 'CASH'",
      [today],
    );

    final bankResult = await _db.rawQuery(
      "SELECT SUM(total_minor_units) as total FROM sales WHERE date(created_at) = ? AND status = 'COMPLETED' AND payment_method = 'BANK'",
      [today],
    );

    final shiftResult = await _db.query(
      'shifts',
      where: 'status = ?',
      whereArgs: ['OPEN'],
      limit: 1,
    );
    int expectedCash = 0;
    if (shiftResult.isNotEmpty) {
      final shift = Shift.fromMap(shiftResult.first);
      final summary = await ShiftRepository(_db).getShiftSummary(shift);
      expectedCash = summary['expected_cash']!;
    }

    return {
      'today_revenue': (revenueResult.first['total'] as int?) ?? 0,
      'today_cash': (cashResult.first['total'] as int?) ?? 0,
      'today_bank': (bankResult.first['total'] as int?) ?? 0,
      'expected_cash': expectedCash,
      'is_shift_open': shiftResult.isEmpty ? 0 : 1,
    };
  }

  Future<List<Map<String, dynamic>>> getAuditLogs({int limit = 500}) async {
    return _db.rawQuery(
      '''
      SELECT audit_logs.action, audit_logs.details, audit_logs.created_at, users.username
      FROM audit_logs
      LEFT JOIN users ON audit_logs.user_id = users.id
      ORDER BY audit_logs.created_at DESC
      LIMIT ?
      ''',
      [limit],
    );
  }

  Future<int> getTodayRevenue() async {
    final stats = await getDashboardStats();
    return stats['today_revenue']!;
  }

  Future<List<Map<String, dynamic>>> getProductSalesSummary() async {
    return _db.rawQuery('''
      SELECT product_name_snapshot, SUM(quantity) as total_qty, SUM(line_total_minor_units) as total_revenue
      FROM sale_items
      JOIN sales ON sale_items.sale_id = sales.id
      WHERE sales.status = 'COMPLETED'
      GROUP BY product_id, product_name_snapshot
      ORDER BY total_revenue DESC
    ''');
  }

  Future<List<Map<String, dynamic>>> getCashierPerformance() async {
    return _db.rawQuery('''
      SELECT users.username, COUNT(sales.id) as total_sales, SUM(sales.total_minor_units) as total_revenue
      FROM sales
      JOIN users ON sales.cashier_id = users.id
      WHERE sales.status = 'COMPLETED'
      GROUP BY users.id, users.username
      ORDER BY total_revenue DESC
    ''');
  }
}
