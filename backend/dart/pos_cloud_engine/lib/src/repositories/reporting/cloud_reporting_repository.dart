import 'package:pos_contracts/pos_contracts.dart';
import '../../api/cloud_api_client.dart';

/// Web/PWA [ReportingRepository] over the `pos-api` Edge Function.
///
/// Method bodies are the exact calls that previously lived in
/// [CloudSaleRepository] — same actions, same parameters, same response
/// mapping — so the reports, dashboard and audit screens behave identically
/// on web. Role and tenancy remain enforced server-side from the bearer
/// token; the `userId` arguments exist only to keep the native/cloud call
/// sites interchangeable.
class CloudReportingRepository implements ReportingRepository {
  final CloudApiClient _api;

  CloudReportingRepository(this._api);

  @override
  Future<List<Map<String, dynamic>>> getRevenueTrend(
    DateRange period, {
    String? userId,
  }) async {
    final json = await _api.call('revenue_trend', {
      'period_start': isoInstant(period.start),
      'period_end': isoInstant(period.end),
    });
    final rows = json['trend'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().toList();
  }

  @override
  Future<Map<String, int>> getDashboardStats({
    String? userId,
    DateRange? period,
  }) async {
    final range = period ?? DateRange.today();
    final json = await _api.call('dashboard_summary', {
      'period_start': isoInstant(range.start),
      'period_end': isoInstant(range.end),
    });
    final stats = json['stats'];
    if (stats is! Map<String, dynamic>) return const {};
    return {
      for (final e in stats.entries) e.key: (e.value as num?)?.toInt() ?? 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getAuditLogs({
    String? userId,
    int limit = 500,
  }) async {
    final json = await _api.call('list_audit', {'limit': limit});
    final rows = json['audit_logs'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().toList();
  }

  @override
  Future<int> getTodayRevenue({String? userId}) async {
    final stats = await getDashboardStats(userId: userId);
    return stats['revenue'] ?? 0;
  }

  /// Server field names (`qty`/`lines`/`revenue`) are mapped back to the exact
  /// keys the reports screen already reads from the local aggregate, so no
  /// screen changes are needed for the cloud path.
  @override
  Future<List<Map<String, dynamic>>> getProductSalesSummary({
    String? userId,
    DateRange? period,
  }) async {
    final json = await _api.call('report_summary', {
      if (period != null) 'period_start': isoInstant(period.start),
      if (period != null) 'period_end': isoInstant(period.end),
    });
    final rows = json['product_summary'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().map((row) {
      return {
        'product_name_snapshot': row['product_name_snapshot'],
        'total_qty_milliunits': (row['qty'] as num?)?.toInt() ?? 0,
        'line_count': (row['lines'] as num?)?.toInt() ?? 0,
        'total_revenue': (row['revenue'] as num?)?.toInt() ?? 0,
      };
    }).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getCashierPerformance({
    String? userId,
    DateRange? period,
  }) async {
    final json = await _api.call('report_summary', {
      if (period != null) 'period_start': isoInstant(period.start),
      if (period != null) 'period_end': isoInstant(period.end),
    });
    final rows = json['cashier_performance'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().toList();
  }
}
