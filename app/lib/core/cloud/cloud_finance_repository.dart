import '../models/finance_category.dart';
import '../models/finance_entry.dart';
import '../repositories/finance_repository.dart';
import '../utils/date_range.dart';
import 'cloud_api_client.dart';

/// Web/PWA [FinanceRepository] over the `pos-api` Edge Function.
///
/// The owner's private money area is the most role-sensitive surface in the
/// app: every finance action is `OWNER_ONLY` server-side, so a cashier's token
/// is refused regardless of what the client sends. The `ownerId` arguments
/// therefore exist only to keep the native/cloud signatures interchangeable —
/// the actor is taken from the verified bearer token, never from the body.
class CloudFinanceRepository implements FinanceRepository {
  final CloudApiClient _api;

  CloudFinanceRepository(this._api);

  @override
  Future<List<FinanceCategory>> getCategories(String ownerId) async {
    final json = await _api.call('finance_categories');
    final rows = json['categories'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(FinanceCategory.fromMap)
        .toList();
  }

  @override
  Future<List<FinanceCategory>> getDeletedCategories(String ownerId) async {
    final json = await _api.call('finance_deleted_categories');
    final rows = json['categories'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(FinanceCategory.fromMap)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getCategorySummaries(
    String ownerId,
  ) async {
    final json = await _api.call('finance_summaries');
    final rows = json['summaries'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().toList();
  }

  @override
  Future<FinanceCategory> createCategory({
    required String ownerId,
    required String name,
  }) async {
    final json = await _api.call('finance_create_category', {'name': name});
    return FinanceCategory.fromMap(json['category'] as Map<String, dynamic>);
  }

  @override
  Future<void> renameCategory({
    required String ownerId,
    required String categoryId,
    required String newName,
  }) async {
    await _api.call('finance_rename_category', {
      'category_id': categoryId,
      'new_name': newName,
    });
  }

  @override
  Future<void> deleteCategory({
    required String ownerId,
    required String categoryId,
  }) async {
    await _api.call('finance_delete_category', {'category_id': categoryId});
  }

  @override
  Future<void> restoreCategory({
    required String ownerId,
    required String categoryId,
  }) async {
    await _api.call('finance_restore_category', {'category_id': categoryId});
  }

  @override
  Future<void> permanentlyDeleteCategory({
    required String ownerId,
    required String categoryId,
  }) async {
    await _api.call('finance_permanently_delete_category', {
      'category_id': categoryId,
    });
  }

  @override
  Future<FinanceEntry> addEntry({
    required String ownerId,
    required String categoryId,
    required String source,
    required int amountMinorUnits,
    String? description,
    DateTime? entryDate,
    String? paymentMethod,
  }) async {
    final json = await _api.call('finance_add_entry', {
      'category_id': categoryId,
      'source': source,
      'amount_minor_units': amountMinorUnits,
      'description': ?description,
      'payment_method': ?paymentMethod,
      if (entryDate != null) 'entry_date': isoInstant(entryDate),
    });
    return FinanceEntry.fromMap(json['entry'] as Map<String, dynamic>);
  }

  @override
  Future<void> updateEntry({
    required String ownerId,
    required String entryId,
    required String source,
    required int amountMinorUnits,
    String? description,
    DateTime? entryDate,
    String? paymentMethod,
  }) async {
    await _api.call('finance_update_entry', {
      'entry_id': entryId,
      'source': source,
      'amount_minor_units': amountMinorUnits,
      'description': ?description,
      'payment_method': ?paymentMethod,
      if (entryDate != null) 'entry_date': isoInstant(entryDate),
    });
  }

  @override
  Future<void> markCompleted({
    required String ownerId,
    required String entryId,
  }) async {
    await _api.call('finance_mark_completed', {'entry_id': entryId});
  }

  @override
  Future<List<FinanceEntry>> searchEntries({
    required String ownerId,
    String? categoryId,
    String? searchQuery,
    String? status,
    DateRange? dateRange,
  }) async {
    final json = await _api.call('finance_search_entries', {
      if (categoryId != null && categoryId.isNotEmpty)
        'category_id': categoryId,
      if (searchQuery != null && searchQuery.trim().isNotEmpty)
        'search_query': searchQuery.trim(),
      if (status != null && status.isNotEmpty && status != 'ALL')
        'status': status,
      if (dateRange != null) 'date_range_start': isoInstant(dateRange.start),
      if (dateRange != null) 'date_range_end': isoInstant(dateRange.end),
    });
    final rows = json['entries'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(FinanceEntry.fromMap)
        .toList();
  }

  @override
  Future<Map<String, int>> getPersonTotals(
    String ownerId,
    String categoryId,
  ) async {
    final json = await _api.call('finance_person_totals', {
      'category_id': categoryId,
    });
    final totals = json['totals'];
    if (totals is! Map<String, dynamic>) return const {};
    return {
      'pending_total': (totals['pending_total'] as num?)?.toInt() ?? 0,
      'completed_total': (totals['completed_total'] as num?)?.toInt() ?? 0,
    };
  }
}
