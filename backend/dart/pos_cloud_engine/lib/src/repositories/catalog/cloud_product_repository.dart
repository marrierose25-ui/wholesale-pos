import 'package:pos_contracts/pos_contracts.dart';
import '../../api/cloud_api_client.dart';
import 'package:pos_core/catalog.dart';

/// Web/PWA [ProductRepository] over the `pos-api` Edge Function.
///
/// Implements the exact M1 interface the Saved Names screens depend on, so a
/// screen is agnostic to whether it is talking to local SQLite or the cloud.
/// Server rows reuse [Product.fromMap] because `pos_products` stores the same
/// column names the local `products` table does.
class CloudProductRepository implements ProductRepository {
  final CloudApiClient _api;

  CloudProductRepository(this._api);

  @override
  Future<void> save(Product product) async {
    await _api.call('save_product', {'product': product.toMap()});
  }

  @override
  Future<void> update(Product product) async {
    await _api.call('update_product', {'product': product.toMap()});
  }

  @override
  Future<void> deactivate(String id) async {
    await _api.call('deactivate_product', {'id': id});
  }

  @override
  Future<void> reactivate(String id) async {
    await _api.call('reactivate_product', {'id': id});
  }

  @override
  Future<Product?> getById(String id) async {
    // No dedicated fetch action; a single saved name is rare, so scan both
    // buckets. Active names vastly outnumber deactivated ones.
    for (final product in [
      ...await getAllActive(),
      ...await getAllInactive(),
    ]) {
      if (product.id == id) return product;
    }
    return null;
  }

  @override
  Future<List<Product>> getAllActive() async {
    return _list({});
  }

  @override
  Future<List<Product>> getAllInactive() async {
    return _list({'inactive': true});
  }

  Future<List<Product>> _list(Map<String, dynamic> body) async {
    final json = await _api.call('list_products', body);
    final rows = json['products'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().map(Product.fromMap).toList();
  }
}
