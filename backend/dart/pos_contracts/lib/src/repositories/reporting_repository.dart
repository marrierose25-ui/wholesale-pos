// Extracted verbatim from the pre-Stage-6 application implementation.
// Signatures and documentation are unchanged; only the SQLite factory
// line (which belongs to the implementation package) was removed.
import 'package:pos_contracts/src/utils/date_range.dart';

abstract class ReportingRepository {

  /// Completed revenue and sale count per calendar day across [period],
  /// ordered oldest to newest, for the dashboard trend chart. Loan sales are
  /// money owed rather than collected, so they are left out of the trend.
  Future<List<Map<String, dynamic>>> getRevenueTrend(
    DateRange period, {
    String? userId,
  });

  /// Revenue figures for the dashboard. Voided sales are always excluded.
  /// Loan sales collect no money, so they stay out of every revenue figure,
  /// but they are real completed sales and DO count toward the sales count.
  /// Defaults to today so the dashboard resets at local midnight purely by
  /// date filtering — records are never deleted.
  Future<Map<String, int>> getDashboardStats({
    String? userId,
    DateRange? period,
  });

  Future<List<Map<String, dynamic>>> getAuditLogs({
    String? userId,
    int limit = 500,
  });

  Future<int> getTodayRevenue({String? userId});

  /// Revenue by entered product name for the reports screen. Quantities are
  /// summed in milliunits; lines with manual totals contribute revenue but no
  /// numeric quantity. Loan sales are excluded — their money was never
  /// collected.
  Future<List<Map<String, dynamic>>> getProductSalesSummary({
    String? userId,
    DateRange? period,
  });

  Future<List<Map<String, dynamic>>> getCashierPerformance({
    String? userId,
    DateRange? period,
  });
}
