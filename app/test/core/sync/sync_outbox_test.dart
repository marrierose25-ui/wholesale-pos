import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/core/repositories/shift_repository.dart';
import 'package:wholesale_pos_app/core/sync/sync_backend.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox_entry.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox_repository.dart';
import 'package:wholesale_pos_app/core/sync/sync_service.dart';
import 'package:wholesale_pos_app/features/sales/sale.dart';
import 'package:wholesale_pos_app/features/sales/sale_item.dart';

/// A test double that records what it was asked to push. Can be told to throw
/// to simulate the network dropping mid-sync.
class RecordingBackend implements SyncBackend {
  final List<SyncOutboxEntry> received = [];
  final bool shouldThrow;
  RecordingBackend({this.shouldThrow = false});

  @override
  bool get isConfigured => true;

  @override
  Future<Set<String>> push(List<SyncOutboxEntry> entries) async {
    if (shouldThrow) throw Exception('network down');
    received.addAll(entries);
    // Confirm every entry so the service marks the whole batch synced.
    return entries.map((e) => e.id).toSet();
  }

  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async => const SyncPullResult.empty();
}

void main() {
  late Database db;
  late SaleRepository saleRepository;
  late ShiftRepository shiftRepository;
  late SyncOutboxRepository outbox;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    saleRepository = SaleRepository(db);
    shiftRepository = ShiftRepository(db);
    outbox = SyncOutboxRepository(db);

    await db.insert('users', {
      'id': 'user-1',
      'username': 'abebe',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'OWNER',
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('devices', {
      'id': 'device-1',
      'name': 'PC',
      'platform': 'Windows',
    });
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'user-1',
      'opening_cash_minor_units': 0,
      'status': 'OPEN',
      'opened_at': DateTime.now().toIso8601String(),
    });
  });

  tearDown(() async {
    await db.close();
  });

  Sale buildSale(String id) {
    return Sale(
      id: id,
      receiptNumber: 'REC-$id',
      cashierId: 'user-1',
      deviceId: 'device-1',
      shiftId: 'shift-1',
      subtotalMinorUnits: 5000,
      discountMinorUnits: 0,
      totalMinorUnits: 5000,
      amountPaidMinorUnits: 5000,
      changeMinorUnits: 0,
      createdAt: DateTime.now(),
      items: [
        SaleItem(
          id: 'item-$id',
          saleId: id,
          productId: 'prod-1',
          productNameSnapshot: 'Sugar',
          unitPriceSnapshotMinorUnits: 5000,
          quantityText: '1',
          billingQuantityMilliunits: 1000,
          lineTotalMinorUnits: 5000,
        ),
      ],
    );
  }

  test('Saving a sale enqueues a pending sale entry with its items', () async {
    await saleRepository.saveSale(buildSale('sale-1'));

    final pending = await outbox.pending();
    expect(pending, hasLength(1));
    expect(pending.single.entityType, SyncEntities.sale);
    expect(pending.single.entityId, 'sale-1');
    expect(pending.single.operation, SyncOperations.upsert);
    final payload = pending.single.payload;
    expect((payload['sale'] as Map)['id'], 'sale-1');
    expect(payload['items'], hasLength(1));
  });

  test(
    'Voiding a sale enqueues a second sale entry (newer state wins)',
    () async {
      await saleRepository.saveSale(buildSale('sale-1'));
      await saleRepository.voidSale('sale-1', 'user-1', 'mistake');

      final pending = await outbox.pending();
      final saleEntries = pending
          .where(
            (e) => e.entityType == SyncEntities.sale && e.entityId == 'sale-1',
          )
          .toList();
      expect(saleEntries, hasLength(2));
      // The later entry reflects the voided status.
      final latest = (saleEntries.last.payload['sale'] as Map)['status'];
      expect(latest, 'VOIDED');
    },
  );

  test('Requesting a void enqueues a void_request entry', () async {
    await saleRepository.saveSale(buildSale('sale-1'));
    await saleRepository.requestVoid('sale-1', 'user-1', 'wrong price');

    final pending = await outbox.pending();
    expect(
      pending.any((e) => e.entityType == SyncEntities.voidRequest),
      isTrue,
    );
  });

  test('Shift open, cash movement and close each enqueue entries', () async {
    await db.delete('shifts'); // start clean so openShift has no open shift
    await shiftRepository.openShift('user-1', 1000);
    final shift = (await shiftRepository.getActiveShift())!;
    await shiftRepository.addCashMovement(
      shift.id,
      'DEPOSIT',
      500,
      'float top-up',
      userId: 'user-1',
    );
    await shiftRepository.closeShift(shift, 1200, userId: 'user-1');

    final pending = await outbox.pending();
    expect(
      pending.where((e) => e.entityType == SyncEntities.shift).length,
      greaterThanOrEqualTo(2),
    );
    expect(
      pending.any((e) => e.entityType == SyncEntities.cashMovement),
      isTrue,
    );
  });

  test(
    'a cash movement push payload carries its proof photo to the cloud',
    () async {
      await db.delete('shifts');
      await shiftRepository.openShift('user-1', 1000);
      final shift = (await shiftRepository.getActiveShift())!;
      final photo = base64Encode(utf8.encode('jpeg-bytes-here'));
      await shiftRepository.addCashMovement(
        shift.id,
        'WITHDRAWAL',
        500,
        'bank drop',
        userId: 'user-1',
        photo: photo,
      );

      final entry = (await outbox.pending()).lastWhere(
        (e) => e.entityType == SyncEntities.cashMovement,
      );
      final movement = entry.payload['cash_movement'] as Map;
      // The proof lives as a BLOB in cash_movement_photos, not the row's empty
      // TEXT column, so the push has to re-attach it — otherwise the PWA (and
      // every other till) never sees an app-captured photo.
      expect(movement['photo'], photo);
    },
  );

  test(
    'a cash movement push payload omits photo when none was attached',
    () async {
      await db.delete('shifts');
      await shiftRepository.openShift('user-1', 1000);
      final shift = (await shiftRepository.getActiveShift())!;
      await shiftRepository.addCashMovement(
        shift.id,
        'DEPOSIT',
        500,
        'float top-up',
        userId: 'user-1',
      );

      final entry = (await outbox.pending()).lastWhere(
        (e) => e.entityType == SyncEntities.cashMovement,
      );
      final movement = entry.payload['cash_movement'] as Map;
      expect(movement.containsKey('photo'), isFalse);
    },
  );

  test('SyncService with no backend leaves everything queued', () async {
    await saleRepository.saveSale(buildSale('sale-1'));
    final service = SyncService(outbox, const NoopSyncBackend());

    final result = await service.syncNow();

    expect(result.skipped, isTrue);
    expect(await outbox.pendingCount(), 1);
  });

  test('SyncService pushes and marks entries synced', () async {
    await saleRepository.saveSale(buildSale('sale-1'));
    await saleRepository.saveSale(buildSale('sale-2'));
    final backend = RecordingBackend();
    final service = SyncService(outbox, backend);

    final result = await service.syncNow();

    expect(result.pushed, 2);
    expect(result.remaining, 0);
    expect(backend.received, hasLength(2));
    expect(await outbox.pendingCount(), 0);
  });

  test('SyncService keeps entries queued when the backend throws', () async {
    await saleRepository.saveSale(buildSale('sale-1'));
    final backend = RecordingBackend(shouldThrow: true);
    final service = SyncService(outbox, backend);

    final result = await service.syncNow();

    expect(result.pushed, 0);
    expect(result.remaining, 1);
    expect(await outbox.pendingCount(), 1);
  });

  test(
    'overlapping syncNow is single-flight; the second tick is idle (#11)',
    () async {
      await saleRepository.saveSale(buildSale('sale-1'));
      final backend = RecordingBackend();
      final service = SyncService(outbox, backend);

      // Kick off the first drain but do NOT await it yet: it sets the in-flight
      // guard synchronously before its first await, so the concurrent second
      // call must short-circuit to idle rather than race a duplicate batch.
      final first = service.syncNow();
      final second = await service.syncNow();

      expect(second.pushed, 0);
      expect(second.remaining, 0); // idle, not a real drain

      final firstResult = await first;
      expect(firstResult.pushed, 1);
      expect(backend.received, hasLength(1)); // only the first drain reached it
      expect(await outbox.pendingCount(), 0);
    },
  );

  test('pruneSynced removes only synced rows', () async {
    final backend = RecordingBackend();
    await saleRepository.saveSale(buildSale('sale-1'));
    await saleRepository.saveSale(buildSale('sale-2'));
    await SyncService(outbox, backend).syncNow(); // both synced
    await saleRepository.saveSale(buildSale('sale-3')); // still pending

    final removed = await outbox.pruneSynced();

    expect(removed, 2);
    final pending = await outbox.pending();
    expect(pending, hasLength(1));
    expect(pending.single.entityId, 'sale-3');
  });

  test('a deposit behind a training collection never leaves the till', () async {
    // The movement names whoever carried the cash; the collection behind it
    // names the training account. Reading only the movement's own operator let
    // demo money leave as a deposit that looked entirely real.
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'demo-1',
      'username': 'demo',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'CASHIER',
      'is_active': 1,
      'is_demo': 1,
      'created_at': now,
    });
    await db.insert('finance_categories', {
      'id': 'cat-1',
      'name': 'Alem',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('finance_entries', {
      'id': 'entry-1',
      'category_id': 'cat-1',
      'source': 'Counter',
      'amount_minor_units': 10000,
      'status': 'COMPLETED',
      'entry_date': now,
      'created_at': now,
      'created_by': 'demo-1',
      'completed_at': now,
      'completed_by': 'demo-1',
      'updated_at': now,
      'payment_method': 'CASH',
    });
    await db.insert('cash_movements', {
      'id': 'movement-1',
      'shift_id': 'shift-1',
      'user_id': 'user-1',
      'type': 'DEPOSIT',
      'amount_minor_units': 10000,
      'reason': 'Collected from Alem',
      'created_at': now,
      'source_finance_entry_id': 'entry-1',
    });

    await db.transaction((txn) async {
      await SyncOutbox.upsert(
        txn,
        entityType: SyncEntities.cashMovement,
        entityId: 'movement-1',
        payload: {
          'cash_movement': {'id': 'movement-1'},
        },
      );
    });

    expect(await outbox.pending(), isEmpty);
  });
}
