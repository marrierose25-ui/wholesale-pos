import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../features/sales/sale.dart';
import '../../features/sales/sale_item.dart';

class SaleRepository {
  final Database _db;

  SaleRepository(this._db);

  Future<void> saveSale(Sale sale) async {
    await _db.transaction((txn) async {
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

  Future<void> voidSale(
    String saleId,
    String receiptNumber,
    String userId,
    String reason,
  ) async {
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

      await txn.update(
        'sales',
        {'status': 'VOIDED', 'void_reason': reason},
        where: 'id = ?',
        whereArgs: [saleId],
      );

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
  }) async {
    String whereClause = '';
    List<dynamic> whereArgs = [];

    if (searchQuery != null && searchQuery.isNotEmpty) {
      whereClause = 'receipt_number LIKE ?';
      whereArgs.add('%$searchQuery%');
    }

    if (startDate != null && endDate != null) {
      if (whereClause.isNotEmpty) whereClause += ' AND ';
      // Add one day to endDate to make it inclusive
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
    );

    final List<Sale> sales = [];

    for (final map in saleMaps) {
      final saleId = map['id'] as String;
      final itemMaps = await _db.query(
        'sale_items',
        where: 'sale_id = ?',
        whereArgs: [saleId],
      );
      final items = itemMaps.map((i) => SaleItem.fromMap(i)).toList();

      sales.add(
        Sale(
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
          createdAt: DateTime.parse(map['created_at'] as String),
          syncedAt: map['synced_at'] != null
              ? DateTime.parse(map['synced_at'] as String)
              : null,
          items: items,
        ),
      );
    }

    return sales;
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

    // Get active shift expected cash
    final shiftResult = await _db.query(
      'shifts',
      where: 'status = ?',
      whereArgs: ['OPEN'],
      limit: 1,
    );
    int expectedCash = 0;
    if (shiftResult.isNotEmpty) {
      final shift = shiftResult.first;
      final openingCash = shift['opening_cash_minor_units'] as int;
      final shiftId = shift['id'];

      final shiftCashSales = await _db.rawQuery(
        "SELECT SUM(total_minor_units) as total FROM sales WHERE status = 'COMPLETED' AND payment_method = 'CASH' AND shift_id = ?",
        [shiftId],
      );
      final salesTotal = (shiftCashSales.first['total'] as int?) ?? 0;
      expectedCash = openingCash + salesTotal;
    }

    return {
      'today_revenue': (revenueResult.first['total'] as int?) ?? 0,
      'today_cash': (cashResult.first['total'] as int?) ?? 0,
      'today_bank': (bankResult.first['total'] as int?) ?? 0,
      'expected_cash': expectedCash,
    };
  }

  Future<List<Map<String, dynamic>>> getAuditLogs() async {
    return await _db.rawQuery('''
      SELECT audit_logs.action, audit_logs.details, audit_logs.created_at, users.username
      FROM audit_logs
      LEFT JOIN users ON audit_logs.user_id = users.id
      ORDER BY audit_logs.created_at DESC
    ''');
  }

  Future<int> getTodayRevenue() async {
    final stats = await getDashboardStats();
    return stats['today_revenue']!;
  }

  Future<List<Map<String, dynamic>>> getProductSalesSummary() async {
    return await _db.rawQuery('''
      SELECT product_name_snapshot, SUM(quantity) as total_qty, SUM(line_total_minor_units) as total_revenue
      FROM sale_items
      JOIN sales ON sale_items.sale_id = sales.id
      WHERE sales.status = 'COMPLETED'
      GROUP BY product_id, product_name_snapshot
      ORDER BY total_revenue DESC
    ''');
  }

  Future<List<Map<String, dynamic>>> getCashierPerformance() async {
    return await _db.rawQuery('''
      SELECT users.username, COUNT(sales.id) as total_sales, SUM(sales.total_minor_units) as total_revenue
      FROM sales
      JOIN users ON sales.cashier_id = users.id
      WHERE sales.status = 'COMPLETED'
      GROUP BY users.id, users.username
      ORDER BY total_revenue DESC
    ''');
  }
}
