import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_core/catalog.dart';
import 'package:pos_core/inventory.dart';

import '../../api/cloud_api_client.dart';

/// Cloud [InventoryRepository] over the `pos-api` Edge Function. Mirrors the
/// native contract: stores, per-store stock, and the atomic
/// product+opening-stock create (one server RPC, since the browser has no
/// local transaction).
class CloudInventoryRepository implements InventoryRepository {
  final CloudApiClient _api;

  CloudInventoryRepository(this._api);

  @override
  Future<List<Store>> getStores() async {
    final res = await _api.call('list_stores', const {});
    return [
      for (final row in (res['stores'] as List? ?? const []))
        Store.fromMap(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<void> createStore(String name) async {
    await _api.call('create_store', {'name': name});
  }

  @override
  Future<void> deleteStore(String id) async {
    await _api.call('delete_store', {'id': id});
  }

  @override
  Future<List<InventoryItem>> getInventory({String? storeId}) async {
    final res = await _api.call('list_inventory', {
      'store_id': ?storeId,
    });
    return [
      for (final item in (res['items'] as List? ?? const []))
        InventoryItem(
          product: Product.fromMap(
            Map<String, dynamic>.from((item as Map)['product'] as Map),
          ),
          stocks: [
            for (final s in ((item)['stocks'] as List? ?? const []))
              StoreStock(
                storeId: (s as Map)['store_id'] as String,
                storeName: (s)['store_name'] as String? ?? '',
                onHandMilliunits:
                    ((s)['on_hand_milliunits'] as num?)?.toInt() ?? 0,
                reorderMilliunits:
                    ((s)['reorder_milliunits'] as num?)?.toInt() ?? 0,
              ),
          ],
        ),
    ];
  }

  @override
  Future<void> createProductWithStock({
    required Product product,
    required String storeId,
    required int onHandMilliunits,
    required int reorderMilliunits,
  }) async {
    final productMap = product.toMap();
    if (product.imageData != null) {
      productMap['image_data'] = product.imageData;
    }
    await _api.call('create_inventory_product', {
      'product': productMap,
      'store_id': storeId,
      'on_hand_milliunits': onHandMilliunits,
      'reorder_milliunits': reorderMilliunits,
    });
  }
}
