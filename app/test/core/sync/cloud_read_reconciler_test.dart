import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/sync/cloud_read_reconciler.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox_entry.dart';

SyncOutboxEntry _entry({
  required String entityType,
  required String entityId,
  required String operation,
  required Map<String, dynamic> payload,
  required DateTime createdAt,
  DateTime? syncedAt,
}) => SyncOutboxEntry(
  id: 'outbox-$entityId-${createdAt.microsecondsSinceEpoch}',
  entityType: entityType,
  entityId: entityId,
  operation: operation,
  payloadJson: jsonEncode(payload),
  createdAt: createdAt,
  syncedAt: syncedAt,
);

String _idOf(Map<String, dynamic> row) => row['id'] as String;

void main() {
  group('CloudReadReconciler.reconcile', () {
    final t0 = DateTime(2026, 1, 1, 9);
    final t1 = DateTime(2026, 1, 1, 10);

    test('cloud rows pass through untouched when the outbox is empty', () {
      final cloud = [
        {'id': 'a', 'v': 1},
        {'id': 'b', 'v': 2},
      ];
      final out = CloudReadReconciler.reconcile(
        entityType: SyncEntities.sale,
        cloudRows: cloud,
        outbox: const [],
        idOf: _idOf,
      );
      expect(out, same(cloud));
    });

    test('acked entries are ignored so the committed cloud value wins', () {
      final cloud = [
        {'id': 'a', 'total': 100},
      ];
      final outbox = [
        _entry(
          entityType: SyncEntities.sale,
          entityId: 'a',
          operation: SyncOperations.upsert,
          payload: {'id': 'a', 'total': 999},
          createdAt: t0,
          syncedAt: t1, // acked
        ),
      ];
      final out = CloudReadReconciler.reconcile(
        entityType: SyncEntities.sale,
        cloudRows: cloud,
        outbox: outbox,
        idOf: _idOf,
      );
      expect(out.single['total'], 100);
    });

    test('pending upsert shadows the cloud row in place', () {
      final cloud = [
        {'id': 'a', 'total': 100},
        {'id': 'b', 'total': 200},
      ];
      final outbox = [
        _entry(
          entityType: SyncEntities.sale,
          entityId: 'a',
          operation: SyncOperations.upsert,
          payload: {'id': 'a', 'total': 150},
          createdAt: t0,
        ),
      ];
      final out = CloudReadReconciler.reconcile(
        entityType: SyncEntities.sale,
        cloudRows: cloud,
        outbox: outbox,
        idOf: _idOf,
      );
      expect(out.map(_idOf).toList(), ['a', 'b']); // order preserved
      expect(out.first['total'], 150); // local pending wins for 'a'
      expect(out.last['total'], 200); // 'b' still cloud truth
    });

    test('pending delete drops the row entirely', () {
      final cloud = [
        {'id': 'a', 'total': 100},
        {'id': 'b', 'total': 200},
      ];
      final outbox = [
        _entry(
          entityType: SyncEntities.sale,
          entityId: 'a',
          operation: SyncOperations.delete,
          payload: {'id': 'a'},
          createdAt: t0,
        ),
      ];
      final out = CloudReadReconciler.reconcile(
        entityType: SyncEntities.sale,
        cloudRows: cloud,
        outbox: outbox,
        idOf: _idOf,
      );
      expect(out.map(_idOf).toList(), ['b']);
    });

    test('newest pending entry per entity wins', () {
      final cloud = [
        {'id': 'a', 'total': 100},
      ];
      final outbox = [
        _entry(
          entityType: SyncEntities.sale,
          entityId: 'a',
          operation: SyncOperations.upsert,
          payload: {'id': 'a', 'total': 111},
          createdAt: t0,
        ),
        _entry(
          entityType: SyncEntities.sale,
          entityId: 'a',
          operation: SyncOperations.upsert,
          payload: {'id': 'a', 'total': 222},
          createdAt: t1, // later
        ),
      ];
      final out = CloudReadReconciler.reconcile(
        entityType: SyncEntities.sale,
        cloudRows: cloud,
        outbox: outbox,
        idOf: _idOf,
      );
      expect(out.single['total'], 222);
    });

    test('pending upsert for a cloud-absent entity is appended', () {
      final cloud = [
        {'id': 'a', 'total': 100},
      ];
      final outbox = [
        _entry(
          entityType: SyncEntities.sale,
          entityId: 'z',
          operation: SyncOperations.upsert,
          payload: {'id': 'z', 'total': 7},
          createdAt: t0,
        ),
      ];
      final out = CloudReadReconciler.reconcile(
        entityType: SyncEntities.sale,
        cloudRows: cloud,
        outbox: outbox,
        idOf: _idOf,
      );
      expect(out.map(_idOf).toList(), ['a', 'z']);
      expect(out.last['total'], 7);
    });

    test('entries for a different entity type are ignored', () {
      final cloud = [
        {'id': 'a', 'total': 100},
      ];
      final outbox = [
        _entry(
          entityType: SyncEntities.shift,
          entityId: 'a',
          operation: SyncOperations.delete,
          payload: {'id': 'a'},
          createdAt: t0,
        ),
      ];
      final out = CloudReadReconciler.reconcile(
        entityType: SyncEntities.sale,
        cloudRows: cloud,
        outbox: outbox,
        idOf: _idOf,
      );
      expect(out.single['total'], 100); // shift outbox did not touch sales
    });
  });
}
