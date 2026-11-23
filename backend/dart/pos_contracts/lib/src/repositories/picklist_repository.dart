// Extracted verbatim from the pre-Stage-6 application implementation.
// Signatures and documentation are unchanged; only the SQLite factory
// line (which belongs to the implementation package) was removed.
import 'package:pos_core/warehouse.dart';

abstract class PicklistRepository {
  /// Native default: a SQLite-backed repository over [db].

  /// All picklists, newest first. When [status] is provided (PENDING /
  /// PARTIAL / COMPLETED) the list is narrowed to that state.
  Future<List<Picklist>> getPicklists({String? status});

  /// The line items of one picklist.
  Future<List<PicklistItem>> getItems(String picklistId);

  /// Creates a picklist header together with its items, atomically.
  Future<void> createPicklist(Picklist picklist, List<PicklistItem> items);

  /// Saves a fulfillment progress pass and re-derives the header status.
  Future<void> updateItemQuantities(
    String picklistId,
    List<PicklistItem> updatedItems,
  );

  /// The saved customer directory (schema 21), newest-typed names first.
  Future<List<PicklistCustomer>> getCustomers();

  /// Persists a new directory entry. Throws when the name is blank.
  Future<void> addCustomer(PicklistCustomer customer);

  /// Toggles one line fully-taken / untouched and re-derives the header status.
  /// [isTaken] sets `taken_qty` to the line's `requested_qty` (or back to 0),
  /// so a single tap fulfills a whole line — the auto-save checkbox path.
  Future<void> toggleItemTaken(String picklistId, String itemId, bool isTaken);

  /// Corrects one line (name, requested quantity, unit, unit price). Re-derives
  /// the header status from the remaining active lines.
  Future<void> updatePicklistItem(PicklistItem item);

  /// Soft-deletes one line. When it was the last active line the header is
  /// soft-deleted too, so the list leaves the queue instead of becoming empty.
  Future<void> deletePicklistItem(String picklistId, String itemId);

  /// Soft-deletes a whole list (header + lines) so every device hides it.
  Future<void> deletePicklist(String picklistId);
}
