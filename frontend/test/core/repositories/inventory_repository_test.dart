import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_core/catalog.dart';
import 'package:pos_core/inventory.dart';

// Inventory foundation: store management rules, atomic product+opening-stock
// creation, per-store stock records, and the All-stores aggregation the
// Inventory screen relies on.
void main() {
  late Database db;
  late SqfliteInventoryRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = SqfliteInventoryRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<String> makeStore(String name) async {
    await repository.createStore(name);
    final stores = await repository.getStores();
    return stores.firstWhere((s) => s.name == name).id;
  }

  Product draft({String name = 'Berbere'}) {
    final now = DateTime(2026, 11, 27);
    return Product(
      id: '',
      name: name,
      code: '',
      unit: 'Kg',
      sellingPriceMinorUnits: 12000,
      boughtPriceMinorUnits: 8000,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Helper: create a product stocked in store [a], return its product id.
  Future<String> makeStoreProduct(String a, String b) async {
    await repository.createProductWithStock(
      product: draft(name: 'Eq'),
      storeId: a,
      onHandMilliunits: 8000,
      reorderMilliunits: 2000,
    );
    return (await db.query('products', where: "name = 'Eq'"))
        .single['id'] as String;
  }

  group('stores', () {
    test('creates and lists stores', () async {
      await repository.createStore('  Main Branch  ');
      final stores = await repository.getStores();
      expect(stores, hasLength(1));
      expect(stores.single.name, 'Main Branch'); // trimmed
    });

    test('rejects an empty name', () async {
      expect(() => repository.createStore('   '), throwsA(anything));
      expect(await repository.getStores(), isEmpty);
    });

    test('rejects case/whitespace duplicate names', () async {
      await repository.createStore('Main Branch');
      expect(
        () => repository.createStore('  main branch '),
        throwsA(predicate((e) => '$e'.contains('already exists'))),
      );
      expect(await repository.getStores(), hasLength(1));
    });

    test('deletes a genuinely empty store', () async {
      final id = await makeStore('Empty');
      await repository.deleteStore(id);
      expect(await repository.getStores(), isEmpty);
      // Tombstone, not a physical delete: the row stays for sync.
      final rows = await db.query('stores');
      expect(rows, hasLength(1));
      expect(rows.single['deleted_at'], isNotNull);
    });

    test('refuses to delete a store holding stock', () async {
      final storeId = await makeStore('Stocked');
      await repository.createProductWithStock(
        product: draft(),
        storeId: storeId,
        onHandMilliunits: 0, // zero quantity still counts as stocked
        reorderMilliunits: 500,
      );
      expect(
        () => repository.deleteStore(storeId),
        throwsA(predicate((e) => '$e'.contains('in stock'))),
      );
      expect(await repository.getStores(), hasLength(1));
    });

    test('allows re-creating a deleted store name', () async {
      final id = await makeStore('Reuse');
      await repository.deleteStore(id);
      await repository.createStore('reuse');
      expect(await repository.getStores(), hasLength(1));
    });
  });

  group('product + opening stock (atomic)', () {
    test('creates product and stock record together', () async {
      final storeId = await makeStore('Main');
      await repository.createProductWithStock(
        product: draft(),
        storeId: storeId,
        onHandMilliunits: 12500,
        reorderMilliunits: 5000,
      );
      final products = await db.query('products');
      final stock = await db.query('store_inventory');
      expect(products, hasLength(1));
      expect(stock, hasLength(1));
      expect(stock.single['on_hand_milliunits'], 12500);
      expect(stock.single['reorder_milliunits'], 5000);
      expect(stock.single['store_id'], storeId);
      expect(stock.single['product_id'], products.single['id']);
      expect(products.single['bought_price_minor_units'], 8000);
    });

    test('enqueues product and stock rows in the outbox', () async {
      final storeId = await makeStore('Main');
      await repository.createProductWithStock(
        product: draft(),
        storeId: storeId,
        onHandMilliunits: 1000,
        reorderMilliunits: 0,
      );
      final outbox = await db.query('sync_outbox');
      final types = outbox.map((r) => r['entity_type']).toSet();
      expect(types, containsAll(['product', 'store_inventory']));
    });

    test('rolls back the product when validation fails', () async {
      // A stock record naming a store that does not exist must abort the
      // whole transaction — no orphan product, no orphan stock row.
      expect(
        () => repository.createProductWithStock(
          product: draft(name: 'Orphan'),
          storeId: 'no-such-store',
          onHandMilliunits: 1000,
          reorderMilliunits: 0,
        ),
        throwsA(anything),
      );
      expect(
        await db.query('products', where: "name = 'Orphan'"),
        isEmpty,
      );
      expect(
        await db.query('store_inventory', where: 'store_id = ?', whereArgs: ['no-such-store']),
        isEmpty,
      );
    });

    test('rejects duplicate product names', () async {
      final storeId = await makeStore('Main');
      await repository.createProductWithStock(
        product: draft(),
        storeId: storeId,
        onHandMilliunits: 1000,
        reorderMilliunits: 0,
      );
      expect(
        () => repository.createProductWithStock(
          product: draft(name: ' berbere '),
          storeId: storeId,
          onHandMilliunits: 1000,
          reorderMilliunits: 0,
        ),
        throwsA(predicate((e) => '$e'.contains('already exists'))),
      );
    });

    test('rejects negative quantities', () async {
      final storeId = await makeStore('Main');
      expect(
        () => repository.createProductWithStock(
          product: draft(),
          storeId: storeId,
          onHandMilliunits: -1,
          reorderMilliunits: 0,
        ),
        throwsA(anything),
      );
    });
  });

  group('inventory reads', () {
    test('all-stores view lists each product once with combined qty', () async {
      final a = await makeStore('A');
      final b = await makeStore('B');
      final c = await makeStore('C');
      await repository.createProductWithStock(
        product: draft(name: 'Flour'),
        storeId: a,
        onHandMilliunits: 10000,
        reorderMilliunits: 2000,
      );
      // Stock the same product in store B via a direct row (wizard only
      // creates the first record; future stock ops will add the rest).
      final productId =
          (await db.query('products', where: "name = 'Flour'"))
              .single['id'] as String;
      final now = DateTime.now().toIso8601String();
      await db.insert('store_inventory', {
        'id': 'si-b',
        'store_id': b,
        'product_id': productId,
        'on_hand_milliunits': 5000,
        'reorder_milliunits': 9000, // below reorder -> RED wins aggregate
        'created_at': now,
        'updated_at': now,
      });
      await repository.createProductWithStock(
        product: draft(name: 'Sugar'),
        storeId: c,
        onHandMilliunits: 3000,
        reorderMilliunits: 1000,
      );

      final all = await repository.getInventory();
      expect(all, hasLength(2)); // each product exactly once
      final flour = all.firstWhere((i) => i.product.name == 'Flour');
      expect(flour.stocks, hasLength(2));
      expect(flour.totalOnHandMilliunits, 15000);
      expect(flour.aggregateStatus, StockStatus.low); // risk-first: B is low
      final sugar = all.firstWhere((i) => i.product.name == 'Sugar');
      expect(sugar.aggregateStatus, StockStatus.healthy);
    });

    test('amber when a store sits exactly at reorder', () async {
      final a = await makeStore('A');
      final b = await makeStore('B');
      final productId = await makeStoreProduct(a, b);
      final now = DateTime.now().toIso8601String();
      await db.insert('store_inventory', {
        'id': 'si-eq',
        'store_id': b,
        'product_id': productId,
        'on_hand_milliunits': 4000,
        'reorder_milliunits': 4000, // exactly at threshold -> amber
        'created_at': now,
        'updated_at': now,
      });
      final items = await repository.getInventory();
      expect(items.single.aggregateStatus, StockStatus.reorder);
    });

    test('single-store view shows only that store\'s stock', () async {
      final a = await makeStore('A');
      final b = await makeStore('B');
      await repository.createProductWithStock(
        product: draft(name: 'Flour'),
        storeId: a,
        onHandMilliunits: 10000,
        reorderMilliunits: 2000,
      );
      final productId =
          (await db.query('products', where: "name = 'Flour'"))
              .single['id'] as String;
      final now = DateTime.now().toIso8601String();
      await db.insert('store_inventory', {
        'id': 'si-b2',
        'store_id': b,
        'product_id': productId,
        'on_hand_milliunits': 500,
        'reorder_milliunits': 100,
        'created_at': now,
        'updated_at': now,
      });

      final inA = await repository.getInventory(storeId: a);
      expect(inA, hasLength(1));
      expect(inA.single.stocks, hasLength(1));
      expect(inA.single.stocks.single.storeId, a);
      expect(inA.single.totalOnHandMilliunits, 10000);

      // A product stocked only in B must not appear under A — covered by
      // the single-stock assertion above; B's view returns its own row.
      final inB = await repository.getInventory(storeId: b);
      expect(inB.single.totalOnHandMilliunits, 500);
    });

    test('inactive products are excluded from the list', () async {
      final a = await makeStore('A');
      await repository.createProductWithStock(
        product: draft(),
        storeId: a,
        onHandMilliunits: 1000,
        reorderMilliunits: 0,
      );
      await db.update('products', {'is_active': 0});
      expect(await repository.getInventory(), isEmpty);
    });
  });
}
