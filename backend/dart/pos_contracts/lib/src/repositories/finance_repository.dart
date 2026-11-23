// Extracted verbatim from the pre-Stage-6 application implementation.
// Signatures and documentation are unchanged; only the SQLite factory
// line (which belongs to the implementation package) was removed.
import 'package:pos_core/finance.dart';
import 'package:pos_contracts/src/utils/date_range.dart';

abstract class FinanceRepository {

  Future<List<FinanceCategory>> getCategories(String ownerId);

  /// People in the recycle bin (soft-deleted), newest trashed first.
  Future<List<FinanceCategory>> getDeletedCategories(String ownerId);

  /// Categories with pending entry counts and pending totals, for the
  /// overview list. Active (non-binned) people only.
  Future<List<Map<String, dynamic>>> getCategorySummaries(String ownerId);

  Future<FinanceCategory> createCategory({
    required String ownerId,
    required String name,
  });

  /// Renames a person. Entries stay attached to the same row, so history is
  /// preserved and remains searchable under the new name.
  Future<void> renameCategory({
    required String ownerId,
    required String categoryId,
    required String newName,
  });

  /// Moves a person to the recycle bin. History is kept; the person and their
  /// entries leave the active area until restored or permanently deleted.
  Future<void> deleteCategory({
    required String ownerId,
    required String categoryId,
  });

  /// Restores a binned person back to the active area.
  Future<void> restoreCategory({
    required String ownerId,
    required String categoryId,
  });

  /// Removes a binned person and all of their entries for good. Only allowed
  /// for people already in the recycle bin.
  Future<void> permanentlyDeleteCategory({
    required String ownerId,
    required String categoryId,
  });

  Future<FinanceEntry> addEntry({
    required String ownerId,
    required String categoryId,
    required String source,
    required int amountMinorUnits,
    String? description,
    DateTime? entryDate,
    String? paymentMethod,
  });

  Future<void> updateEntry({
    required String ownerId,
    required String entryId,
    required String source,
    required int amountMinorUnits,
    String? description,
    DateTime? entryDate,
    String? paymentMethod,
  });

  /// Marks an entry taken. When it is a CASH collection the amount is also
  /// deposited into the open cash register.
  Future<void> markCompleted({
    required String ownerId,
    required String entryId,
  });

  /// Deletes a pending or completed entry. A completed CASH collection is
  /// reversed out of the open register with a matching WITHDRAWAL movement, so
  /// deleting a mistaken collection does not leave its money in the drawer.
  Future<void> deleteEntry({required String ownerId, required String entryId});

  Future<List<FinanceEntry>> searchEntries({
    required String ownerId,
    String? categoryId,
    String? searchQuery,
    String? status,
    DateRange? dateRange,
  });

  Future<Map<String, int>> getPersonTotals(String ownerId, String categoryId);
}
