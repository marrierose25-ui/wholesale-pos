import '../models/picklist.dart';
import '../models/picklist_customer.dart';
import '../models/picklist_item.dart';
import '../repositories/picklist_repository.dart';
import 'cloud_api_client.dart';

/// Web/PWA [PicklistRepository] over the `pos-api` Edge Function.
///
/// Mirrors [CloudFinanceRepository]: the browser holds no SQLite, so every read
/// and write is an authenticated `pos-api` action. The tenant (`customer_id`)
/// and the acting account (`created_by`) are carved from the verified bearer
/// token on the server, never trusted from the body — and each action is gated
/// on the `warehouse` tick server-side, so hiding the tab is never the only
/// permission. A picklist is independent of Sales/Finance by construction; this
/// repository only speaks the four picklist actions.
///
/// The client-generated UUIDs from the create form are sent as-is so the header
/// and its items keep the same identity on the cloud and on every Warehouse
/// tablet that later pulls them down.
class CloudPicklistRepository implements PicklistRepository {
  final CloudApiClient _api;

  CloudPicklistRepository(this._api);

  @override
  Future<List<Picklist>> getPicklists({String? status}) async {
    final json = await _api.call('list_picklists', {
      if (status != null && status.isNotEmpty) 'status': status,
    });
    final rows = json['picklists'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(Picklist.fromMap)
        .toList();
  }

  @override
  Future<List<PicklistItem>> getItems(String picklistId) async {
    final json = await _api.call('get_picklist_items', {
      'picklist_id': picklistId,
    });
    final rows = json['items'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(PicklistItem.fromMap)
        .toList();
  }

  @override
  Future<void> createPicklist(
    Picklist picklist,
    List<PicklistItem> items,
  ) async {
    await _api.call('create_picklist', {
      'picklist': picklist.toMap(),
      'items': [for (final item in items) item.toMap()],
    });
  }

  @override
  Future<void> updateItemQuantities(
    String picklistId,
    List<PicklistItem> updatedItems,
  ) async {
    await _api.call('update_picklist_items', {
      'picklist_id': picklistId,
      'items': [
        for (final item in updatedItems)
          {'id': item.id, 'taken_qty': item.takenQty},
      ],
    });
  }

  @override
  Future<List<PicklistCustomer>> getCustomers() async {
    final json = await _api.call('get_customers', const {});
    final rows = json['customers'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(PicklistCustomer.fromMap)
        .toList();
  }

  @override
  Future<void> addCustomer(PicklistCustomer customer) async {
    await _api.call('add_customer', {'customer': customer.toMap()});
  }

  @override
  Future<void> toggleItemTaken(
    String picklistId,
    String itemId,
    bool isTaken,
  ) async {
    await _api.call('toggle_picklist_item', {
      'picklist_id': picklistId,
      'item_id': itemId,
      'is_taken': isTaken,
    });
  }

  @override
  Future<void> updatePicklistItem(PicklistItem item) async {
    await _api.call('update_picklist_item', {
      'picklist_id': item.picklistId,
      'item_id': item.id,
      'product_name': item.productName,
      'requested_qty': item.requestedQty,
      'unit': item.unit,
      'unit_price_minor_units': item.unitPriceMinorUnits,
    });
  }

  @override
  Future<void> deletePicklistItem(String picklistId, String itemId) async {
    await _api.call('delete_picklist_item', {
      'picklist_id': picklistId,
      'item_id': itemId,
    });
  }

  @override
  Future<void> deletePicklist(String picklistId) async {
    await _api.call('delete_picklist', {'picklist_id': picklistId});
  }
}
