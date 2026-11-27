import '../../../catalog/domain/entities/product.dart';
import 'store_inventory.dart';

/// Stock health of a product, per the inventory rules:
///   * above the reorder quantity  -> [healthy]  (green)
///   * below the reorder quantity  -> [low]      (red)
///   * exactly at the reorder mark -> [reorder]  (amber — the threshold is
///     visible rather than presented as healthy stock)
enum StockStatus { healthy, low, reorder }

/// One store's slice of a product's stock, joined for display.
class StoreStock {
  final String storeId;
  final String storeName;
  final int onHandMilliunits;
  final int reorderMilliunits;

  const StoreStock({
    required this.storeId,
    required this.storeName,
    required this.onHandMilliunits,
    required this.reorderMilliunits,
  });

  StockStatus get status {
    if (onHandMilliunits < reorderMilliunits) return StockStatus.low;
    if (onHandMilliunits == reorderMilliunits) return StockStatus.reorder;
    return StockStatus.healthy;
  }
}

/// A catalogue product plus every store it is stocked in — the row the
/// Inventory screen renders. A product appears once even when it has stock
/// records in several stores.
class InventoryItem {
  final Product product;
  final List<StoreStock> stocks;

  const InventoryItem({required this.product, required this.stocks});

  /// Combined on-hand across every stocked store (milliunits).
  int get totalOnHandMilliunits =>
      stocks.fold(0, (sum, s) => sum + s.onHandMilliunits);

  /// Risk-first status for the "All stores" view: red wins over amber wins
  /// over green, so a low store can never hide behind a healthy one.
  StockStatus get aggregateStatus {
    if (stocks.isEmpty) return StockStatus.healthy;
    var sawReorder = false;
    for (final stock in stocks) {
      switch (stock.status) {
        case StockStatus.low:
          return StockStatus.low;
        case StockStatus.reorder:
          sawReorder = true;
        case StockStatus.healthy:
          break;
      }
    }
    return sawReorder ? StockStatus.reorder : StockStatus.healthy;
  }

  /// The stock row for one store, or null when the product is not stocked
  /// there.
  StoreStock? stockFor(String storeId) {
    for (final stock in stocks) {
      if (stock.storeId == storeId) return stock;
    }
    return null;
  }
}
