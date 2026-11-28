import 'package:sqflite/sqflite.dart';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../sync/sync_outbox.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_core/inventory.dart';
import 'package:pos_core/catalog.dart';

/// SQLite [InventoryRepository]: stores and per-store product stock.
///
/// Every write runs in one transaction that also enqueues the sync outbox,
/// so a store or stock record can never be saved locally without queueing
/// its cloud copy — and a failure rolls the whole write back.
class SqfliteInventoryRepository implements InventoryRepository {
  final Database _db;

  SqfliteInventoryRepository(this._db);

  static const _uuid = Uuid();

  // ------------------------------------------------------------------
  // Stores
  // ------------------------------------------------------------------

  @override
  Future<List<Store>> getStores() async {
    final maps = await _db.query(
      'stores',
      where: 'deleted_at IS NULL',
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return maps.map(Store.fromMap).toList();
  }

  @override
  Future<void> createStore(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw Exception('A store name is required.');
    }
    final now = DateTime.now();
    final store = Store(
      id: _uuid.v4(),
      name: trimmed,
      createdAt: now,
      updatedAt: now,
    );
    await _db.transaction((txn) async {
      await _ensureStoreNameUnique(txn, trimmed);
      await txn.insert('stores', store.toMap());
      await _enqueueStore(txn, store.id);
    });
  }

  /// Case-insensitive, whitespace-insensitive duplicate check against live
  /// stores. The `stores_name_unique` index is the hard backstop for races;
  /// this check exists to return a friendly message first.
  static Future<void> _ensureStoreNameUnique(
    DatabaseExecutor txn,
    String name,
  ) async {
    final rows = await txn.query(
      'stores',
      columns: ['id'],
      where: 'LOWER(TRIM(name)) = LOWER(TRIM(?)) AND deleted_at IS NULL',
      whereArgs: [name],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      throw Exception('A store named "$name" already exists.');
    }
  }

  @override
  Future<void> deleteStore(String id) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'stores',
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw Exception('Store not found.');

      // "Empty" means no product-to-store association at all — a zero
      // quantity still counts as stocked. Nothing else references stores in
      // this release; the tombstone (not a physical delete) is what lets the
      // deletion reach the other devices.
      final stocked = await txn.query(
        'store_inventory',
        columns: ['id'],
        where: 'store_id = ? AND deleted_at IS NULL',
        whereArgs: [id],
      );
      if (stocked.isNotEmpty) {
        throw Exception(
          'This store still has ${stocked.length} product(s) in stock. '
          'Remove its inventory before deleting it.',
        );
      }

      final nowText = DateTime.now().toIso8601String();
      await txn.update(
        'stores',
        {'deleted_at': nowText, 'updated_at': nowText},
        where: 'id = ?',
        whereArgs: [id],
      );
      await _enqueueStore(txn, id);
    });
  }

  // ------------------------------------------------------------------
  // Inventory reads
  // ------------------------------------------------------------------

  @override
  Future<List<InventoryItem>> getInventory({String? storeId}) async {
    // Live stock records, joined to their store for the display name. For a
    // single-store view the stock row is filtered to that store; for "All
    // stores" every record rides along and the item aggregates them.
    final stockMaps = await _db.query(
      'store_inventory si JOIN stores s ON s.id = si.store_id',
      columns: [
        'si.id',
        'si.store_id',
        'si.product_id',
        'si.on_hand_milliunits',
        'si.reorder_milliunits',
        's.name AS store_name',
      ],
      where:
          'si.deleted_at IS NULL AND s.deleted_at IS NULL'
          '${storeId != null ? ' AND si.store_id = ?' : ''}',
      whereArgs: storeId != null ? [storeId] : null,
      orderBy: 's.name COLLATE NOCASE ASC',
    );
    if (stockMaps.isEmpty) return const [];

    final productIds = stockMaps
        .map((m) => m['product_id'] as String)
        .toSet()
        .toList();
    // Chunk the IN list so a large catalogue never hits SQLite's variable
    // limit; product catalogues here are small, but the bound is cheap.
    final productMaps = <Map<String, dynamic>>[];
    for (var i = 0; i < productIds.length; i += 500) {
      final chunk = productIds.sublist(
        i,
        i + 500 > productIds.length ? productIds.length : i + 500,
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      productMaps.addAll(
        await _db.query(
          'products',
          where: 'is_active = 1 AND id IN ($placeholders)',
          whereArgs: chunk,
        ),
      );
    }
    // Photos are BLOBs in product_images — hydrate them only for the
    // inventory list (the one screen that renders avatars), so catalogue and
    // sync reads never pay for image bytes.
    final imageRows = await _db.query(
      'product_images',
      columns: ['product_id', 'jpeg_bytes'],
      where: 'product_id IN (${List.filled(productIds.length, '?').join(',')})',
      whereArgs: productIds,
    );
    final imagesByProduct = {
      for (final r in imageRows)
        if ((r['jpeg_bytes'] as List<int>).isNotEmpty)
          r['product_id'] as String:
              base64Encode(r['jpeg_bytes'] as List<int>),
    };
    final productsById = {
      for (final m in productMaps)
        m['id'] as String: _withImage(
          Product.fromMap(m),
          imagesByProduct[m['id'] as String],
        ),
    };

    final stocksByProduct = <String, List<StoreStock>>{};
    for (final m in stockMaps) {
      final productId = m['product_id'] as String;
      if (!productsById.containsKey(productId)) continue;
      (stocksByProduct[productId] ??= []).add(
        StoreStock(
          storeId: m['store_id'] as String,
          storeName: m['store_name'] as String,
          onHandMilliunits:
              (m['on_hand_milliunits'] as num?)?.toInt() ?? 0,
          reorderMilliunits: (m['reorder_milliunits'] as num?)?.toInt() ?? 0,
        ),
      );
    }

    final items = [
      for (final entry in stocksByProduct.entries)
        InventoryItem(
          product: productsById[entry.key]!,
          stocks: entry.value,
        ),
    ]..sort(
      (a, b) => a.product.name.toLowerCase().compareTo(
        b.product.name.toLowerCase(),
      ),
    );
    return items;
  }

  Product _withImage(Product p, String? imageData) => Product(
    id: p.id,
    name: p.name,
    code: p.code,
    category: p.category,
    unit: p.unit,
    sellingPriceMinorUnits: p.sellingPriceMinorUnits,
    boughtPriceMinorUnits: p.boughtPriceMinorUnits,
    imageData: imageData,
    isActive: p.isActive,
    createdAt: p.createdAt,
    updatedAt: p.updatedAt,
  );

  // ------------------------------------------------------------------
  // Product creation (atomic)
  // ------------------------------------------------------------------

  @override
  Future<void> createProductWithStock({
    required Product product,
    required String storeId,
    required int onHandMilliunits,
    required int reorderMilliunits,
  }) async {
    final name = product.name.trim();
    if (name.isEmpty) throw Exception('A product name is required.');
    if (product.unit.trim().isEmpty) {
      throw Exception('A unit is required.');
    }
    if (product.sellingPriceMinorUnits < 0 ||
        product.boughtPriceMinorUnits < 0) {
      throw Exception('Prices cannot be negative.');
    }
    if (onHandMilliunits < 0 || reorderMilliunits < 0) {
      throw Exception('Quantities cannot be negative.');
    }

    final now = DateTime.now();
    // `code` is the catalogue's UNIQUE NOT NULL column; the wizard has no
    // barcode field, so the id is the stable stand-in (same convention the
    // sync applier uses for cloud rows without a code).
    final id = product.id.isEmpty ? _uuid.v4() : product.id;
    final resolved = Product(
      id: id,
      name: name,
      code: product.code.isEmpty ? id : product.code,
      category: product.category,
      unit: product.unit.trim(),
      sellingPriceMinorUnits: product.sellingPriceMinorUnits,
      boughtPriceMinorUnits: product.boughtPriceMinorUnits,
      imageData: product.imageData,
      isActive: true,
      createdAt: now,
      updatedAt: now,
    );

    // Deterministic relationship identity: the pair IS the identity, so two
    // devices recording stock for the same product+store converge on one
    // canonical row instead of inventing competing UUIDs.
    final stock = StoreInventory(
      id: 'si_${storeId}_${resolved.id}',
      storeId: storeId,
      productId: resolved.id,
      onHandMilliunits: onHandMilliunits,
      reorderMilliunits: reorderMilliunits,
      createdAt: now,
      updatedAt: now,
    );

    await _db.transaction((txn) async {
      // Same case-insensitive uniqueness rule SqfliteProductRepository
      // enforces, checked inside the transaction so a concurrent create
      // cannot slip a duplicate past it (the DB has no name UNIQUE index by
      // design — `code` is the unique key).
      final dup = await txn.query(
        'products',
        columns: ['id'],
        where: 'LOWER(TRIM(name)) = LOWER(TRIM(?))',
        whereArgs: [name],
        limit: 1,
      );
      if (dup.isNotEmpty) {
        throw Exception('A product named "$name" already exists.');
      }
      // The store must exist and be live — inventory without a store is
      // exactly what the wizard forbids.
      final storeRows = await txn.query(
        'stores',
        columns: ['id'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [storeId],
        limit: 1,
      );
      if (storeRows.isEmpty) {
        throw Exception('The selected store no longer exists.');
      }

      await txn.insert('products', resolved.toMap());
      // Photo bytes live in product_images (BLOB), never on the product row —
      // same split as cash_movement_photos. imageData arrives as base64 and
      // is bounded by the same budget the proof-photo pipeline guarantees;
      // the server enforces the identical cap, so reject early and atomically.
      if (resolved.imageData != null && resolved.imageData!.isNotEmpty) {
        if (resolved.imageData!.length > 400000) {
          throw Exception('Product image is too large.');
        }
        await txn.insert('product_images', {
          'product_id': resolved.id,
          'jpeg_bytes': base64Decode(resolved.imageData!),
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        });
        // The image rides its own sync entity so product payloads never
        // carry bytes; entityId is the product id (one image per product).
        await SyncOutbox.upsert(
          txn,
          entityType: SyncEntities.productImage,
          entityId: resolved.id,
          payload: {
            SyncEntities.payloadKeys[SyncEntities.productImage]!: {
              'product_id': resolved.id,
              'image_data': resolved.imageData,
              'created_at': now.toIso8601String(),
              'updated_at': now.toIso8601String(),
              'deleted_at': null,
            },
          },
        );
      }
      await txn.insert('store_inventory', stock.toMap());

      // Queue the product first, then its stock record: the server applies
      // master data before dependents anyway, but keeping the order honest
      // costs nothing. The image entry above lands between them.
      await _enqueueProduct(txn, resolved.id);
      await _enqueueInventory(txn, stock.id);
    });
  }

  // ------------------------------------------------------------------
  // Outbox
  // ------------------------------------------------------------------

  static Future<void> _enqueueStore(
    DatabaseExecutor txn,
    String storeId,
  ) async {
    final rows = await txn.query(
      'stores',
      where: 'id = ?',
      whereArgs: [storeId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await SyncOutbox.upsertRow(
      txn,
      entityType: SyncEntities.store,
      entityId: storeId,
      row: rows.first,
    );
  }

  static Future<void> _enqueueProduct(
    DatabaseExecutor txn,
    String productId,
  ) async {
    final rows = await txn.query(
      'products',
      where: 'id = ?',
      whereArgs: [productId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await SyncOutbox.upsertRow(
      txn,
      entityType: SyncEntities.product,
      entityId: productId,
      row: rows.first,
    );
  }

  static Future<void> _enqueueInventory(
    DatabaseExecutor txn,
    String inventoryId,
  ) async {
    final rows = await txn.query(
      'store_inventory',
      where: 'id = ?',
      whereArgs: [inventoryId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await SyncOutbox.upsertRow(
      txn,
      entityType: SyncEntities.storeInventory,
      entityId: inventoryId,
      row: rows.first,
    );
  }
}
