import 'package:sqflite/sqflite.dart';

import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_core/register.dart';
import 'feature_gate.dart';
import 'sqflite_shift_repository.dart';

class SqfliteReportingRepository implements ReportingRepository {
  final Database _db;

  SqfliteReportingRepository(this._db);

  @override
  Future<List<Map<String, dynamic>>> getRevenueTrend(
    DateRange period, {
    String? userId,
  }) async {
    await requireFeature(_db, userId, feature: 'dashboard');
    return _db.rawQuery(
      '''
      SELECT substr(created_at, 1, 10) AS day,
        COUNT(*) AS count,
        COALESCE(SUM(total_minor_units), 0) AS total
      FROM sales
      WHERE status = 'COMPLETED'
        AND payment_method IN ('CASH', 'BANK')
        AND ${notDemoOperator('cashier_id')}
        AND created_at >= ? AND created_at < ?
      GROUP BY day
      ORDER BY day ASC
    ''',
      [period.start.toIso8601String(), period.end.toIso8601String()],
    );
  }

  @override
  Future<Map<String, int>> getDashboardStats({
    String? userId,
    DateRange? period,
  }) async {
    await requireFeature(_db, userId, feature: 'dashboard');
    final range = period ?? DateRange.today();
    final rangeArgs = [
      range.start.toIso8601String(),
      range.end.toIso8601String(),
    ];
    // Every figure below shares one filter, so the dashboard, its void count and
    // its pending approvals all speak about the real shop only.
    final completed =
        "created_at >= ? AND created_at < ? AND status = 'COMPLETED' "
        'AND ${notDemoOperator('cashier_id')}';

    // Count every completed sale (loans included); sum money only from the
    // methods that actually collected it (CASH, BANK).
    final revenueRow = await _db.rawQuery('''
      SELECT COUNT(*) AS count,
             COALESCE(SUM(CASE WHEN payment_method IN ('CASH', 'BANK')
                               THEN total_minor_units ELSE 0 END), 0) AS total
      FROM sales
      WHERE $completed
    ''', rangeArgs);

    final cashRow = await _db.rawQuery('''
      SELECT COALESCE(SUM(total_minor_units), 0) AS total
      FROM sales WHERE $completed AND payment_method = 'CASH'
    ''', rangeArgs);

    final bankRow = await _db.rawQuery('''
      SELECT COALESCE(SUM(total_minor_units), 0) AS total
      FROM sales WHERE $completed AND payment_method = 'BANK'
    ''', rangeArgs);

    // Sales rung up in the period that were later voided.
    final voidRow = await _db.rawQuery('''
      SELECT COUNT(*) AS count FROM sales
      WHERE status = 'VOIDED' AND ${notDemoOperator('cashier_id')}
        AND created_at >= ? AND created_at < ?
    ''', rangeArgs);

    // Cashier void requests still awaiting an owner's decision.
    final pendingRow = await _db.rawQuery('''
      SELECT COUNT(*) AS count
      FROM void_requests vr
      JOIN sales s ON vr.sale_id = s.id
      WHERE vr.status = 'PENDING'
        AND ${notDemoOperator('s.cashier_id')}
        AND s.created_at >= ? AND s.created_at < ?
    ''', rangeArgs);

    final shiftResult = await _db.query(
      'shifts',
      where: 'status = ?',
      whereArgs: ['OPEN'],
      limit: 1,
    );
    int expectedCash = 0;
    if (shiftResult.isNotEmpty) {
      final shift = Shift.fromMap(shiftResult.first);
      try {
        final summary = await SqfliteShiftRepository(_db)
            .getShiftSummary(shift, userId: userId);
        expectedCash = summary['expected_cash']!;
      } catch (_) {
        // Shift summary requires the register tick. A staff account with only
        // dashboard access still gets revenue stats; expected cash stays 0.
      }
    }

    final salesCount = revenueRow.first['count'] as int;
    final revenue = revenueRow.first['total'] as int;

    return {
      'revenue': revenue,
      'sales_count': salesCount,
      'cash_revenue': cashRow.first['total'] as int,
      'bank_revenue': bankRow.first['total'] as int,
      'average_sale': salesCount == 0 ? 0 : revenue ~/ salesCount,
      'expected_cash': expectedCash,
      'is_shift_open': shiftResult.isEmpty ? 0 : 1,
      'void_count': voidRow.first['count'] as int,
      'pending_void_requests': pendingRow.first['count'] as int,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getAuditLogs({
    String? userId,
    int limit = 500,
  }) async {
    await requireFeature(_db, userId, feature: 'audit');
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

  @override
  Future<int> getTodayRevenue({String? userId}) async {
    final stats = await getDashboardStats(userId: userId);
    return stats['revenue']!;
  }

  @override
  Future<List<Map<String, dynamic>>> getProductSalesSummary({
    String? userId,
    DateRange? period,
  }) async {
    await requireFeature(_db, userId, feature: 'reports');
    final rangeArgs = period == null
        ? <dynamic>[]
        : [period.start.toIso8601String(), period.end.toIso8601String()];
    final rangeClause = period == null
        ? ''
        : ' AND sales.created_at >= ? AND sales.created_at < ?';
    return _db.rawQuery('''
      SELECT si.product_name_snapshot,
        COALESCE(SUM(si.billing_quantity_milliunits), 0) AS total_qty_milliunits,
        COUNT(*) AS line_count,
        SUM(si.line_total_minor_units) AS total_revenue
      FROM sale_items si
      JOIN sales ON si.sale_id = sales.id
      WHERE sales.status = 'COMPLETED'
        AND ${notDemoOperator('sales.cashier_id')}
        AND sales.payment_method IN ('CASH', 'BANK')$rangeClause
      GROUP BY si.product_name_snapshot
      ORDER BY total_revenue DESC
    ''', rangeArgs);
  }

  @override
  Future<List<Map<String, dynamic>>> getCashierPerformance({
    String? userId,
    DateRange? period,
  }) async {
    await requireFeature(_db, userId, feature: 'reports');
    final rangeArgs = period == null
        ? <dynamic>[]
        : [period.start.toIso8601String(), period.end.toIso8601String()];
    final rangeClause = period == null
        ? ''
        : ' AND sales.created_at >= ? AND sales.created_at < ?';
    return _db.rawQuery('''
      SELECT users.username, COUNT(sales.id) AS total_sales, COALESCE(SUM(sales.total_minor_units), 0) AS total_revenue
      FROM sales
      JOIN users ON sales.cashier_id = users.id
      WHERE sales.status = 'COMPLETED'
        AND ${notDemoOperator('sales.cashier_id')}
        AND sales.payment_method IN ('CASH', 'BANK')$rangeClause
      GROUP BY users.id, users.username
      ORDER BY total_revenue DESC
    ''', rangeArgs);
  }
}
