// Extracted verbatim from the pre-Stage-6 application implementation.
// Signatures and documentation are unchanged; only the SQLite factory
// line (which belongs to the implementation package) was removed.
import 'package:pos_core/sales.dart';
import 'package:pos_contracts/src/utils/date_range.dart';

abstract class SaleRepository {

  /// Escapes LIKE wildcards so user search text matches literally.
  static String escapeLike(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
  }

  /// Persists a completed sale.
  ///
  /// **Caller must verify the `pos` feature first.** Typically by calling
  /// [nextReceiptNumber] with the same user id, which requires the `pos`
  /// tick. This method does NOT re-check the permission — one write, one gate.
  Future<void> saveSale(Sale sale);

  Future<String> nextReceiptNumber({String? userId});

  Future<void> voidSale(String saleId, String userId, String reason);

  Future<List<Sale>> getSales({
    String? userId,
    String? searchQuery,
    DateRange? period,
    String? status,
    int? limit,
  });

  Future<List<Sale>> getRecentSales({String? userId, int limit = 5});

  Future<List<Sale>> getVoidedSalesForShift(String shiftId, {String? userId});

  Future<void> requestVoid(String saleId, String userId, String reason);

  Future<List<VoidRequest>> getPendingVoidRequests({String? userId});

  Future<void> approveVoidRequest(String requestId, String ownerId);

  Future<void> rejectVoidRequest(String requestId, String ownerId);

  Future<List<Map<String, dynamic>>> getRevenueTrend(
    DateRange period, {
    String? userId,
  });

  Future<Map<String, int>> getDashboardStats({
    String? userId,
    DateRange? period,
  });

  Future<List<Map<String, dynamic>>> getAuditLogs({
    String? userId,
    int limit = 500,
  });

  Future<int> getTodayRevenue({String? userId});

  Future<List<Map<String, dynamic>>> getProductSalesSummary({
    String? userId,
    DateRange? period,
  });

  Future<List<Map<String, dynamic>>> getCashierPerformance({
    String? userId,
    DateRange? period,
  });
}
