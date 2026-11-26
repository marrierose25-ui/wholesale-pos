import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:wholesale_pos_app/core/sync/actor_grant_store.dart';

/// Request 3 P0 regression: a queued row must never borrow another user's
/// grant. A creates a sale offline; B signs in later; only B holds a grant.
/// The sale's primary actor must resolve to NOTHING (deferred server-side),
/// never to B.
void main() {
  late Database db;
  late ActorGrantStore store;

  SyncOutboxEntry entry(
    String type,
    String id,
    Map<String, dynamic> payload,
  ) => SyncOutboxEntry(
    id: 'out-$id',
    entityType: type,
    entityId: id,
    operation: 'UPSERT',
    payloadJson: jsonEncode(payload),
    createdAt: DateTime(2026),
  );

  setUp(() async {
    sqfliteFfiInit();
    db = await LocalDatabase.openInMemory();
    store = ActorGrantStore(db);
  });

  tearDown(() async => db.close());

  test('sale by A defers when only B has a grant', () async {
    await store.save('user-a', grant: 'grant-a');
    await store.clear('user-a'); // A never signed in on this device
    await store.save('user-b', grant: 'grant-b');
    store.currentUserId = 'user-b';

    final sale = entry(SyncEntities.sale, 'sale-1', {
      'sale': {'id': 'sale-1', 'cashier_id': 'user-a'},
      'items': [],
    });
    final grants = await store.grantsForEntry(sale);
    expect(grants, isNotNull);
    expect(
      grants!.primary,
      isNull,
      reason: 'B\'s grant must never stand in as A\'s primary actor',
    );
    expect(grants.byActor.containsKey('user-a'), isFalse);
  });

  test('cash movement by A defers when only B has a grant', () async {
    await store.save('user-b', grant: 'grant-b');
    store.currentUserId = 'user-b';

    final movement = entry(SyncEntities.cashMovement, 'cm-1', {
      'cash_movement': {'id': 'cm-1', 'user_id': 'user-a', 'type': 'DEPOSIT'},
    });
    final grants = await store.grantsForEntry(movement);
    expect(grants, isNotNull);
    expect(grants!.primary, isNull);
  });

  test('sale resolves its own actor grant when present', () async {
    await store.save('user-a', grant: 'grant-a');
    await store.save('user-b', grant: 'grant-b');
    store.currentUserId = 'user-b';

    final sale = entry(SyncEntities.sale, 'sale-2', {
      'sale': {'id': 'sale-2', 'cashier_id': 'user-a'},
      'items': [],
    });
    final grants = await store.grantsForEntry(sale);
    expect(grants!.primary, 'grant-a');
  });

  test('finance entry resolves creator, completer and deleter independently',
      () async {
    await store.save('user-a', grant: 'grant-a');
    await store.save('user-b', grant: 'grant-b');
    // user-c has NO grant: the deleter slot must stay unresolved.
    store.currentUserId = 'user-b';

    final fe = entry(SyncEntities.financeEntry, 'fe-1', {
      'finance_entry': {
        'id': 'fe-1',
        'created_by': 'user-a',
        'completed_by': 'user-b',
        'deleted_by': 'user-c',
        'status': 'DELETED',
      },
    });
    final grants = await store.grantsForEntry(fe);
    expect(grants!.byActor['user-a'], 'grant-a');
    expect(grants.byActor['user-b'], 'grant-b');
    expect(grants.byActor.containsKey('user-c'), isFalse);
    // Primary is the most recent resolvable actor (completed_by -> user-b).
    expect(grants.primary, 'grant-b');
  });
}
