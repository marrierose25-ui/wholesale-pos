import '../../features/sales/sale.dart';
import '../../features/sales/sale_item.dart';
import '../../features/sales/void_request.dart';
import '../repositories/sale_repository.dart';
import '../utils/date_range.dart';
import 'cloud_api_client.dart';

/// Web/PWA [SaleRepository] over the `pos-api` Edge Function.
///
/// [Sale] has no `fromMap` (the local row and its items are stitched by the
/// SQLite repository), so this class hand-builds the aggregate from the
/// server's hydrated row — mirroring [_hydrate] in [SqfliteSaleRepository] but
/// sourced from `search_sales`/`list_void_requests`, which already return the
/// `cashier_name`, `has_pending_void_request` and nested `items` the screens
/// expect. Role and tenancy are enforced server-side from the bearer token, so
/// the `userId`/`ownerId` arguments exist only to keep the native/cloud call
/// sites interchangeable; the server ignores a client's claim of who it is.
class CloudSaleRepository implements SaleRepository {
  final CloudApiClient _api;

  CloudSaleRepository(this._api);

  /// Posts the cart and refuses to report success unless the server booked the
  /// sale we sent. `pos_create_sale` answers with the row it matched on either
  /// the sale id or the receipt number, so a receipt collision used to come
  /// back as `ok: true` carrying someone else's sale and the screen still said
  /// "Sale recorded" (audit 2 #7). The RPC now raises on a foreign receipt, and
  /// this check catches any remaining mismatch at the client boundary.
  @override
  Future<void> saveSale(Sale sale) async {
    final json = await _api.call('insert_sale', {
      'sale': sale.toMap(),
      'items': sale.items.map((item) => item.toMap()).toList(),
    });
    final booked = json['id'];
    if (booked is! String || booked != sale.id) {
      throw CloudApiException(
        'Receipt ${sale.receiptNumber} is already used by another sale. '
        'Nothing was recorded — check the receipt number and try again.',
      );
    }
  }

  @override
  Future<String> nextReceiptNumber() async {
    final json = await _api.call('next_receipt_number');
    return json['receipt_number'] as String;
  }

  @override
  Future<void> voidSale(String saleId, String userId, String reason) async {
    await _api.call('void_sale', {'sale_id': saleId, 'reason': reason});
  }

  @override
  Future<List<Sale>> getSales({
    String? searchQuery,
    DateRange? period,
    String? status,
    int? limit,
  }) async {
    final json = await _api.call('search_sales', {
      if (searchQuery != null && searchQuery.trim().isNotEmpty)
        'search_query': searchQuery.trim(),
      if (period != null) 'period_start': isoInstant(period.start),
      if (period != null) 'period_end': isoInstant(period.end),
      if (status != null && status.isNotEmpty && status != 'ALL')
        'status': status,
      'limit': ?limit,
    });
    final rows = json['sales'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().map(_saleFromRow).toList();
  }

  @override
  Future<List<Sale>> getRecentSales({int limit = 5}) {
    return getSales(limit: limit);
  }

  /// Voids reviewed at shift close. The server exposes no shift-scoped void
  /// query, so the voided set (small) is filtered here using exactly the local
  /// rule: voided in this shift, or voided while this shift was open but rung
  /// up earlier with no recorded voiding shift.
  @override
  Future<List<Sale>> getVoidedSalesForShift(String shiftId) async {
    final all = await getSales(status: 'VOIDED');
    return all
        .where(
          (s) =>
              s.voidedShiftId == shiftId ||
              (s.voidedShiftId == null && s.shiftId == shiftId),
        )
        .toList();
  }

  @override
  Future<void> requestVoid(String saleId, String userId, String reason) async {
    await _api.call('request_void', {'sale_id': saleId, 'reason': reason});
  }

  @override
  Future<List<VoidRequest>> getPendingVoidRequests() async {
    final json = await _api.call('list_void_requests');
    final rows = json['void_requests'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().map((row) {
      final sale = row['sale'];
      return VoidRequest(
        id: row['id'] as String,
        saleId: row['sale_id'] as String,
        requestedBy: row['requested_by'] as String,
        requesterName: row['requester_name'] as String?,
        reason: row['reason'] as String,
        status: row['status'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        decidedBy: row['decided_by'] as String?,
        decidedAt: row['decided_at'] == null
            ? null
            : DateTime.parse(row['decided_at'] as String),
        sale: sale is Map<String, dynamic> ? _saleFromRow(sale) : null,
      );
    }).toList();
  }

  @override
  Future<void> approveVoidRequest(String requestId, String ownerId) async {
    await _api.call('approve_void', {'request_id': requestId});
  }

  @override
  Future<void> rejectVoidRequest(String requestId, String ownerId) async {
    await _api.call('reject_void', {'request_id': requestId});
  }

  @override
  Future<List<Map<String, dynamic>>> getRevenueTrend(DateRange period) async {
    final json = await _api.call('revenue_trend', {
      'period_start': isoInstant(period.start),
      'period_end': isoInstant(period.end),
    });
    final rows = json['trend'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().toList();
  }

  @override
  Future<Map<String, int>> getDashboardStats({DateRange? period}) async {
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
  Future<List<Map<String, dynamic>>> getAuditLogs({int limit = 500}) async {
    final json = await _api.call('list_audit', {'limit': limit});
    final rows = json['audit_logs'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().toList();
  }

  @override
  Future<int> getTodayRevenue() async {
    final stats = await getDashboardStats();
    return stats['revenue'] ?? 0;
  }

  /// Server field names (`qty`/`lines`/`revenue`) are mapped back to the exact
  /// keys the reports screen already reads from the local aggregate, so no
  /// screen changes are needed for the cloud path.
  @override
  Future<List<Map<String, dynamic>>> getProductSalesSummary({
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

  // ---- mapping helpers --------------------------------------------------

  /// Builds a [Sale] from a hydrated server row. Money columns arrive as JSON
  /// numbers; on web they decode through `num`, so every one is normalised with
  /// [_asInt] rather than an `as int` cast that would break on a `double` value.
  Sale _saleFromRow(Map<String, dynamic> row) {
    final items = row['items'];
    return Sale(
      id: row['id'] as String,
      receiptNumber: row['receipt_number'] as String,
      cashierId: row['cashier_id'] as String,
      deviceId: (row['device_id'] as String?) ?? '',
      shiftId: (row['shift_id'] as String?) ?? '',
      customerName: row['customer_name'] as String?,
      paymentMethod: row['payment_method'] as String? ?? 'CASH',
      subtotalMinorUnits: _asInt(row['subtotal_minor_units']),
      discountMinorUnits: _asInt(row['discount_minor_units']),
      totalMinorUnits: _asInt(row['total_minor_units']),
      amountPaidMinorUnits: _asInt(row['amount_paid_minor_units']),
      changeMinorUnits: _asInt(row['change_minor_units']),
      status: row['status'] as String? ?? 'COMPLETED',
      voidReason: row['void_reason'] as String?,
      voidedAt: row['voided_at'] == null
          ? null
          : DateTime.parse(row['voided_at'] as String),
      voidedBy: row['voided_by'] as String?,
      voidedShiftId: row['voided_shift_id'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
      syncedAt: row['synced_at'] == null
          ? null
          : DateTime.parse(row['synced_at'] as String),
      cashierName: row['cashier_name'] as String?,
      hasPendingVoidRequest: row['has_pending_void_request'] == true,
      items: items is List
          ? items
                .whereType<Map<String, dynamic>>()
                .map(SaleItem.fromMap)
                .toList()
          : const [],
    );
  }

  static int _asInt(Object? value) => (value as num?)?.toInt() ?? 0;
}
