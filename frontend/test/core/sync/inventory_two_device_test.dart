import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Two-device synchronization identity for the inventory foundation.
///
/// Two independent SQLite databases stand in for two tills. Both receive the
/// SAME replicated store and product rows through the real pull path
/// ([SyncPullApplier]), then each records stock for the same pair. The stock
/// record's identity is deterministic — `si_{storeId}_{productId}` — so the
/// two devices converge on one canonical row instead of inventing competing
/// ids, exactly like the server-side `store_inventory_pair` index expects.
void main() {
  const storeId = 'store-replicated-1';
  const productId = 'product-replicated-1';

  late Database deviceA;
  late Database deviceB;
  late Directory tempDir;

  /// Both devices pull the same store + product + (optionally) stock rows,
  /// exactly as CloudSyncPuller would deliver them.
  Future<void> replicateCatalog(Database db, {List<Map<String, dynamic>>? stock}) async {
    final now = DateTime.now().toIso8601String();
    await SyncPullApplier(db).apply(
      SyncPullResult(
        changes: {
          'stores': [
            {
              'id': storeId,
              'name': 'Main Branch',
              'created_at': now,
              'updated_at': now,
              'deleted_at': null,
              'received_at': now,
            },
          ],
          'products': [
            {
              'id': productId,
              'name': 'Berbere',
              'code': productId,
              'category': null,
              'unit': 'Kg',
              'selling_price_minor_units': 12000,
              'bought_price_minor_units': 8000,
              'is_active': 1,
              'created_at': now,
              'updated_at': now,
              'received_at': now,
            },
          ],
          'store_inventory': ?stock,
        },
      ),
    );
  }

  /// Records stock for (store, product) the same way the repository's stock
  /// half of createProductWithStock does: deterministic id + outbox entry in
  /// one transaction.
  Future<void> recordStock(
    Database db, {
    required int onHand,
    String? updatedAt,
  }) async {
    final now = DateTime.now();
    final stamp = updatedAt ?? now.toIso8601String();
    final id = 'si_${storeId}_$productId';
    await db.transaction((txn) async {
      await txn.insert('store_inventory', {
        'id': id,
        'store_id': storeId,
        'product_id': productId,
        'on_hand_milliunits': onHand,
        'reorder_milliunits': 0,
        'created_at': now.toIso8601String(),
        'updated_at': stamp,
        'deleted_at': null,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await SyncOutbox.upsertRow(
        txn,
        entityType: SyncEntities.storeInventory,
        entityId: id,
        row: {
          'id': id,
          'store_id': storeId,
          'product_id': productId,
          'on_hand_milliunits': onHand,
          'reorder_milliunits': 0,
          'created_at': now.toIso8601String(),
          'updated_at': stamp,
          'deleted_at': null,
        },
      );
    });
  }

  /// Reads a device's pending outbox payloads as the cloud would store them:
  /// the entity's payload map keyed by its payload key.
  Future<List<Map<String, dynamic>>> pendingPayloads(
    Database db,
    String entityType,
  ) async {
    final rows = await db.query(
      'sync_outbox',
      where: 'entity_type = ?',
      whereArgs: [entityType],
    );
    return [
      for (final r in rows)
        (jsonDecode(r['payload'] as String) as Map<String, dynamic>),
    ];
  }

  /// Simulates a successful push: the server acked every queued entry, so
  /// the pending-guard no longer shields this device's own writes.
  Future<void> markSynced(Database db) => db.update(
        'sync_outbox',
        {'synced_at': DateTime.now().toIso8601String()},
        where: 'synced_at IS NULL',
      );

  /// Feeds cloud-shaped rows through the real pull path.
  Future<void> pull(Database db, Map<String, List<Map<String, dynamic>>> changes) =>
      SyncPullApplier(db).apply(SyncPullResult(changes: changes));


  /// _localIso stores local-time ISO strings; compare instants, not text.
  DateTime instant(Object? v) =>
      DateTime.parse('$v').toUtc();

  Future<List<Map<String, dynamic>>> stockRows(Database db) =>
      db.query('store_inventory', where: 'store_id = ?', whereArgs: [storeId]);


  setUp(() async {
    // Two REAL files: sqflite's ':memory:' path is shared per factory, so two
    // openInMemory() handles would alias the same database and the
    // two-device scenario would be meaningless.
    tempDir = await Directory.systemTemp.createTemp('inv_two_device_');
    deviceA = await LocalDatabase.openAt(
      p.join(tempDir.path, 'device_a.db'),
    );
    deviceB = await LocalDatabase.openAt(
      p.join(tempDir.path, 'device_b.db'),
    );
    await replicateCatalog(deviceA);
    await replicateCatalog(deviceB);
  });

  tearDown(() async {
    await deviceA.close();
    await deviceB.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('both devices derive the same deterministic store-inventory id', () async {
    await recordStock(deviceA, onHand: 5000);
    await recordStock(deviceB, onHand: 7000);

    final a = await stockRows(deviceA);
    final b = await stockRows(deviceB);
    expect(a.single['id'], 'si_${storeId}_$productId');
    expect(b.single['id'], a.single['id']);

    // Each device queued exactly one outbox entry under that same entity id.
    final aOut = await pendingPayloads(deviceA, SyncEntities.storeInventory);
    final bOut = await pendingPayloads(deviceB, SyncEntities.storeInventory);
    expect(aOut.single[SyncEntities.payloadKeys[SyncEntities.storeInventory]!]['id'],
        a.single['id']);
    expect(bOut.single[SyncEntities.payloadKeys[SyncEntities.storeInventory]!]['id'],
        b.single['id']);
  });

  test('duplicate upserts converge: pull does not duplicate the relationship',
      () async {
    await recordStock(deviceA, onHand: 5000);
    await markSynced(deviceA); // A's write reached the cloud
    // Device B receives A's stock row through the cloud feed.
    final aPayload = (await pendingPayloads(deviceA, SyncEntities.storeInventory))
        .single[SyncEntities.payloadKeys[SyncEntities.storeInventory]!] as Map;
    await pull(deviceB, {
      'store_inventory': [Map<String, dynamic>.from(aPayload)],
    });
    // And B's own earlier write for the same pair is the same row id, so
    // re-applying its payload is an update, never a second relationship.
    await recordStock(deviceB, onHand: 7000);
    final bPayload = (await pendingPayloads(deviceB, SyncEntities.storeInventory))
        .single[SyncEntities.payloadKeys[SyncEntities.storeInventory]!] as Map;
    await pull(deviceA, {
      'store_inventory': [Map<String, dynamic>.from(bPayload)],
    });

    expect(await stockRows(deviceA), hasLength(1));
    expect(await stockRows(deviceB), hasLength(1));
    // The pair uniqueness the server enforces (customer, store, product)
    // holds locally through the deterministic id.
    final pair = await deviceA.query(
      'store_inventory',
      where: 'store_id = ? AND product_id = ?',
      whereArgs: [storeId, productId],
    );
    expect(pair, hasLength(1));
  });

  test('out-of-order parent arrival is deferred, then lands', () async {
    // Stock row arrives before its store and product exist locally.
    const lateStore = 'store-late-1';
    const lateProduct = 'product-late-1';
    final orphan = {
      'id': 'si_${lateStore}_$lateProduct',
      'store_id': lateStore,
      'product_id': lateProduct,
      'on_hand_milliunits': 1000,
      'reorder_milliunits': 0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'deleted_at': null,
    };
    await pull(deviceA, {'store_inventory': [orphan]});
    expect(await stockRows(deviceA), isEmpty);

    // Parents land on a later pull; the stock row was never lost — the next
    // delivery of the same page now applies.
    final now = DateTime.now().toIso8601String();
    await pull(deviceA, {
      'stores': [
        {'id': lateStore, 'name': 'Late Store', 'created_at': now,
         'updated_at': now, 'deleted_at': null, 'received_at': now},
      ],
      'products': [
        {'id': lateProduct, 'name': 'Late Product', 'code': lateProduct,
         'category': null, 'unit': 'Pc', 'selling_price_minor_units': 100,
         'bought_price_minor_units': 50, 'is_active': 1,
         'created_at': now, 'updated_at': now, 'received_at': now},
      ],
      'store_inventory': [orphan],
    });
    final landed = await deviceA.query(
      'store_inventory',
      where: 'id = ?',
      whereArgs: ['si_${lateStore}_$lateProduct'],
    );
    expect(landed, hasLength(1));
  });

  test('retries do not create duplicate records', () async {
    await recordStock(deviceA, onHand: 5000);
    final payload = (await pendingPayloads(deviceA, SyncEntities.storeInventory))
        .single[SyncEntities.payloadKeys[SyncEntities.storeInventory]!] as Map;
    // Same page delivered twice (a retried pull after a crash).
    for (var i = 0; i < 2; i++) {
      await pull(deviceB, {
        'store_inventory': [Map<String, dynamic>.from(payload)],
      });
    }
    expect(await stockRows(deviceB), hasLength(1));
    // Re-applying the identical row is a no-op update, not an insert.
    final report = await SyncPullApplier(deviceB).apply(
      SyncPullResult(
        changes: {
          'store_inventory': [Map<String, dynamic>.from(payload)],
        },
      ),
    );
    expect(await stockRows(deviceB), hasLength(1));
    expect(report.storeInventory, lessThanOrEqualTo(1));
  });

  test('a tombstone cannot be undone by an old pending update', () async {
    final t1 = DateTime(2026, 1, 1, 10).toIso8601String();
    final t2 = DateTime(2026, 1, 1, 11).toIso8601String();
    final t3 = DateTime(2026, 1, 1, 12).toIso8601String();
    final id = 'si_${storeId}_$productId';

    // Cloud state: stock written at t1, then tombstoned at t3.
    await pull(deviceB, {
      'store_inventory': [
        {
          'id': id,
          'store_id': storeId,
          'product_id': productId,
          'on_hand_milliunits': 5000,
          'reorder_milliunits': 0,
          'created_at': t1,
          'updated_at': t1,
          'deleted_at': null,
        },
        {
          'id': id,
          'store_id': storeId,
          'product_id': productId,
          'on_hand_milliunits': 5000,
          'reorder_milliunits': 0,
          'created_at': t1,
          'updated_at': t3,
          'deleted_at': t3,
        },
      ],
    });
    final afterDelete = await deviceB.query(
      'store_inventory',
      where: 'id = ?',
      whereArgs: [id],
    );
    expect(afterDelete.single['deleted_at'], isNotNull);

    // An OLDER pending update (t2 < t3) must not resurrect the row.
    await pull(deviceB, {
      'store_inventory': [
        {
          'id': id,
          'store_id': storeId,
          'product_id': productId,
          'on_hand_milliunits': 9000,
          'reorder_milliunits': 0,
          'created_at': t1,
          'updated_at': t2,
          'deleted_at': null,
        },
      ],
    });
    final finalRow = await deviceB.query(
      'store_inventory',
      where: 'id = ?',
      whereArgs: [id],
    );
    expect(finalRow.single['deleted_at'], isNotNull);
    expect(finalRow.single['on_hand_milliunits'], 5000);
  });

  test('a pending local outbox entry is never overwritten by the cloud',
      () async {
    // Device A records stock locally but has not pushed yet.
    await recordStock(deviceA, onHand: 5000);
    // Cloud delivers an older copy of the same relationship.
    final stale = DateTime(2020, 1, 1).toIso8601String();
    await pull(deviceA, {
      'store_inventory': [
        {
          'id': 'si_${storeId}_$productId',
          'store_id': storeId,
          'product_id': productId,
          'on_hand_milliunits': 1,
          'reorder_milliunits': 0,
          'created_at': stale,
          'updated_at': stale,
          'deleted_at': null,
        },
      ],
    });
    final row = (await stockRows(deviceA)).single;
    expect(row['on_hand_milliunits'], 5000);
  });

  test('both databases eventually agree on the shared relationship', () async {
    // A writes stock, pushes; B writes stock for the same pair, pushes.
    // Each pulls the other's payload once; both end with one identical row.
    await recordStock(deviceA, onHand: 5000);
    await recordStock(deviceB, onHand: 7000);
    await markSynced(deviceA);
    await markSynced(deviceB);
    final aPayload = (await pendingPayloads(deviceA, SyncEntities.storeInventory))
        .single[SyncEntities.payloadKeys[SyncEntities.storeInventory]!] as Map;
    final bPayload = (await pendingPayloads(deviceB, SyncEntities.storeInventory))
        .single[SyncEntities.payloadKeys[SyncEntities.storeInventory]!] as Map;

    // Exchange through the cloud feed. B's write is newer, so it wins on A.
    await pull(deviceA, {
      'store_inventory': [Map<String, dynamic>.from(bPayload)],
    });
    await pull(deviceB, {
      'store_inventory': [Map<String, dynamic>.from(aPayload)],
    });

    final aRows = await stockRows(deviceA);
    final bRows = await stockRows(deviceB);
    expect(aRows, hasLength(1));
    expect(bRows, hasLength(1));
    expect(aRows.single['id'], bRows.single['id']);
    // Both converged on the newest write (B's 7000).
    expect(aRows.single['on_hand_milliunits'], 7000);
    expect(bRows.single['on_hand_milliunits'], 7000);
  });

  test('pulled products keep the purchase price on both devices', () async {
    for (final db in [deviceA, deviceB]) {
      final rows = await db.query(
        'products',
        where: 'id = ?',
        whereArgs: [productId],
      );
      expect(rows, hasLength(1));
      expect(rows.single['bought_price_minor_units'], 8000);
    }
  });

  test('product image pull hydrates bytes and tombstone removes them',
      () async {
    final jpeg = base64Encode(List<int>.filled(64, 0xFF));
    final now = DateTime.now().toIso8601String();
    await pull(deviceA, {
      'product_images': [
        {
          'customer_id': 'cust-1',
          'product_id': productId,
          'image_data': jpeg,
          'created_at': now,
          'updated_at': now,
          'deleted_at': null,
          'received_at': now,
        },
      ],
    });
    var images = await deviceA.query('product_images');
    expect(images, hasLength(1));
    expect(images.single['jpeg_bytes'], isA<List<int>>());

    // A cloud tombstone empties the local bytes but KEEPS the row as a
    // version marker, so a replayed older upload cannot resurrect it.
    final later = DateTime.now().add(const Duration(minutes: 1)).toIso8601String();
    await pull(deviceA, {
      'product_images': [
        {
          'customer_id': 'cust-1',
          'product_id': productId,
          'image_data': null,
          'created_at': now,
          'updated_at': later,
          'deleted_at': later,
          'received_at': later,
        },
      ],
    });
    images = await deviceA.query('product_images');
    expect(images, hasLength(1));
    expect((images.single['jpeg_bytes'] as List<int>), isEmpty);
    expect(images.single['updated_at'], later);
  });

  test('image tombstone version survives replay: T1 -> T3 delete -> T2 stale '
      '-> T4 restore', () async {
    Map<String, dynamic> imgRow(String updatedAt, String? data,
            {String? deletedAt}) =>
        {
          'customer_id': 'cust-1',
          'product_id': productId,
          'image_data': data,
          'created_at': updatedAt,
          'updated_at': updatedAt,
          'deleted_at': deletedAt,
          'received_at': updatedAt,
        };

    final t1 = '2026-01-01T00:00:00.000Z';
    final t2 = '2026-01-02T00:00:00.000Z';
    final t3 = '2026-01-03T00:00:00.000Z';
    final t4 = '2026-01-04T00:00:00.000Z';
    final jpeg1 = base64Encode(List<int>.filled(32, 0x11));
    final jpeg2 = base64Encode(List<int>.filled(32, 0x22));

    Future<List<Map<String, dynamic>>> images() =>
        deviceA.query('product_images');

    // T1: image lands.
    await pull(deviceA, {
      'product_images': [imgRow(t1, jpeg1)],
    });
    expect((await images()).single['jpeg_bytes'], isNotEmpty);

    // T3: newer tombstone empties bytes, keeps the T3 version marker.
    await pull(deviceA, {
      'product_images': [imgRow(t3, null, deletedAt: t3)],
    });
    var row = (await images()).single;
    expect((row['jpeg_bytes'] as List<int>), isEmpty);
    expect(instant(row['updated_at']), instant(t3));

    // T2: replayed older upload cannot resurrect the deleted image.
    await pull(deviceA, {
      'product_images': [imgRow(t2, jpeg1)],
    });
    row = (await images()).single;
    expect((row['jpeg_bytes'] as List<int>), isEmpty);
    expect(instant(row['updated_at']), instant(t3));

    // T4: a genuinely newer upload restores the image.
    await pull(deviceA, {
      'product_images': [imgRow(t4, jpeg2)],
    });
    row = (await images()).single;
    expect((row['jpeg_bytes'] as List<int>), isNotEmpty);
    expect(instant(row['updated_at']), instant(t4));
  });

  test('tombstone with no local row still records the version marker',
      () async {
    Map<String, dynamic> imgRow(String updatedAt, String? data,
            {String? deletedAt}) =>
        {
          'customer_id': 'cust-1',
          'product_id': productId,
          'image_data': data,
          'created_at': updatedAt,
          'updated_at': updatedAt,
          'deleted_at': deletedAt,
          'received_at': updatedAt,
        };

    final t2 = '2026-02-02T00:00:00.000Z';
    final t3 = '2026-02-03T00:00:00.000Z';
    final t4 = '2026-02-04T00:00:00.000Z';
    final jpeg = base64Encode(List<int>.filled(32, 0x33));

    // Local table is EMPTY: a tombstone arrives first (device missed T1).
    await pull(deviceA, {
      'product_images': [imgRow(t3, null, deletedAt: t3)],
    });
    var images = await deviceA.query('product_images');
    expect(images, hasLength(1));
    expect((images.single['jpeg_bytes'] as List<int>), isEmpty);
    expect(instant(images.single['updated_at']), instant(t3));

    // A replayed older upload must NOT create the image — the marker wins.
    await pull(deviceA, {
      'product_images': [imgRow(t2, jpeg)],
    });
    images = await deviceA.query('product_images');
    expect(images, hasLength(1));
    expect((images.single['jpeg_bytes'] as List<int>), isEmpty);
    expect(instant(images.single['updated_at']), instant(t3));

    // A newer upload restores it.
    await pull(deviceA, {
      'product_images': [imgRow(t4, jpeg)],
    });
    images = await deviceA.query('product_images');
    expect(images, hasLength(1));
    expect((images.single['jpeg_bytes'] as List<int>), isNotEmpty);
    expect(instant(images.single['updated_at']), instant(t4));
  });
}
