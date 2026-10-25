import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/sync/cloud_read_convergence.dart';
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

/// A convergence wired to canned sources; records how many times each was
/// invoked so the tests can assert both fetchers actually ran.
({
  CloudReadConvergence conv,
  int Function() cloudCalls,
  int Function() outboxCalls,
})
_convergence({
  required List<Map<String, dynamic>> cloudRows,
  List<SyncOutboxEntry> outbox = const [],
  String entityType = SyncEntities.sale,
}) {
  var cloudCalls = 0;
  var outboxCalls = 0;
  final conv = CloudReadConvergence(
    entityType: entityType,
    idOf: _idOf,
    fetchCloudRows: () async {
      cloudCalls++;
      // Yield once to prove the two sources run concurrently, not serially.
      await Future<void>.delayed(Duration.zero);
      return cloudRows;
    },
    fetchPendingOutbox: () async {
      outboxCalls++;
      await Future<void>.delayed(Duration.zero);
      return outbox;
    },
  );
  return (
    conv: conv,
    cloudCalls: () => cloudCalls,
    outboxCalls: () => outboxCalls,
  );
}

void main() {
  group('CloudReadConvergence.read', () {
    final t0 = DateTime(2026, 1, 1, 9);
    final t1 = DateTime(2026, 1, 1, 10);

    test(
      'returns cloud rows untouched when there is nothing pending',
      () async {
        final cloud = [
          {'id': 'a', 'total': 100},
          {'id': 'b', 'total': 200},
        ];
        final c = _convergence(cloudRows: cloud);
        final out = await c.conv.read();
        expect(out, cloud);
        expect(c.cloudCalls(), 1);
        expect(c.outboxCalls(), 1);
      },
    );

    test('a pending local upsert shadows the cloud copy', () async {
      final cloud = [
        {'id': 'a', 'total': 100},
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
      final out = await _convergence(
        cloudRows: cloud,
        outbox: outbox,
      ).conv.read();
      expect(out.single['total'], 150);
    });

    test(
      'an acked outbox entry is ignored so committed cloud data wins',
      () async {
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
        final out = await _convergence(
          cloudRows: cloud,
          outbox: outbox,
        ).conv.read();
        expect(out.single['total'], 100);
      },
    );

    test('a pending local delete removes the cloud row', () async {
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
      final out = await _convergence(
        cloudRows: cloud,
        outbox: outbox,
      ).conv.read();
      expect(out.map(_idOf).toList(), ['b']);
    });

    test('a brand-new local write (cloud-absent) is appended', () async {
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
      final out = await _convergence(
        cloudRows: cloud,
        outbox: outbox,
      ).conv.read();
      expect(out.map(_idOf).toList(), ['a', 'z']);
      expect(out.last['total'], 7);
    });

    test('both sources are fetched, exactly once per read', () async {
      final c = _convergence(
        cloudRows: const [
          {'id': 'a', 'total': 1},
        ],
      );
      await c.conv.read();
      await c.conv.read();
      expect(c.cloudCalls(), 2);
      expect(c.outboxCalls(), 2);
    });

    test('entries for a different entity type are not applied', () async {
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
      final out = await _convergence(
        cloudRows: cloud,
        outbox: outbox,
        entityType: SyncEntities.sale,
      ).conv.read();
      expect(out.single['total'], 100); // shift outbox did not touch sales
    });
  });
}
