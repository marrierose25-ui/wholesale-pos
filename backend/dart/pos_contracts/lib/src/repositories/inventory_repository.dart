import 'package:pos_core/inventory.dart';
import 'package:pos_core/catalog.dart';

/// Inventory foundation: stores plus the product-to-store stock records.
///
/// A store is a location holding stock; [StoreInventory] is the per-store
/// on-hand/reorder pair for one catalogue [Product]. Quantities are
/// milliunits. Every write is offline-first: the concrete repository commits
/// locally and enqueues the sync outbox in the same transaction.
abstract class InventoryRepository {
  /// Live (non-deleted) stores, name order.
  Future<List<Store>> getStores();

  /// Creates a store. The name is trimmed; empty and duplicate names
  /// (case-insensitive) are rejected. Backed by a database-level uniqueness
  /// constraint as well as this check.
  Future<void> createStore(String name);

  /// Deletes a store, but only when no product is stocked in it — including
  /// records whose quantity is zero. Throws with a human-readable reason
  /// when the store still holds inventory; never cascades products away.
  Future<void> deleteStore(String id);

  /// Inventory rows for the product list. With [storeId] null ("All stores")
  /// every stocked product appears once with all of its store stocks; with a
  /// store id only products stocked in that store appear, each carrying just
  /// that store's stock row.
  Future<List<InventoryItem>> getInventory({String? storeId});

  /// The wizard's single logical operation: create the catalogue product AND
  /// its first store stock record atomically. [product] carries the catalogue
  /// fields (name, unit, prices, optional image); [onHandMilliunits] and
  /// [reorderMilliunits] are the initial stock at [storeId]. Any failure
  /// rolls the whole thing back — a product can never exist without the
  /// stock record the user believes they created.
  Future<void> createProductWithStock({
    required Product product,
    required String storeId,
    required int onHandMilliunits,
    required int reorderMilliunits,
  });
}
