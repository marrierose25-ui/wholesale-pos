import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/sync/native_read_convergence.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox_entry.dart';

SyncOutboxEntry _entry({
  required String entityId,
  required String operation,
  required Map<String, dynamic> payload,
  required DateTime createdAt,
  String entityType = SyncEntities.sale,
}) => SyncOutboxEntry(
  id: 'outbox-$entityId-${createdAt.microsecondsSinceEpoch}',
  entityType: entityType,
  entityId: entityId,
  operation: operation,
  payloadJson: jsonEncode(payload),
  createdAt: createdAt,
);

String _idOf(Map<String, dynamic> row) => row['id'] as String;

/// Thrown by a fake cloud fetch to stand in for an unreachable `pos-api`.
class _NetworkError implements Exception {}

/// A policy wired to canned sources. [cloudThrows] simulates the offline case;
/// the call counters let each test prove which sources actually ran.
({
  NativeReadConvergence policy,
  int Function() cloudCalls,
  int Function() localCalls,
  Object? Function() fellBack,
})
_policy({
  List<Map<String, dynamic>> cloudRows = const [],
  bool cloudThrows = false,
  List<SyncOutboxEntry> outbox = const [],
  required List<Map<String, dynamic>> localCache,
  bool Function(Object error)? shouldFallbackOnError,
}) {
  var cloudCalls = 0;
  var localCalls = 0;
  Object? fellBack;
  final policy = NativeReadConvergence(
    entityType: SyncEntities.sale,
    idOf: _idOf,
    fetchCloudRows: () async {
      cloudCalls++;
      await Future<void>.delayed(Duration.zero);
      if (cloudThrows) throw _NetworkError();
      return cloudRows;
    },
    fetchPendingOutbox: () async {
      await Future<void>.delayed(Duration.zero);
      return outbox;
    },
    fetchLocalCache: () async {
      localCalls++;
      return localCache;
    },
    shouldFallbackOnError: shouldFallbackOnError,
    onFallback: (e) => fellBack = e,
  );
  return (
    policy: policy,
    cloudCalls: () => cloudCalls,
    localCalls: () => localCalls,
    fellBack: () => fellBack,
  );
}

void main() {
  group('NativeReadConvergence.read', () {
    final t0 = DateTime(2026, 1, 1, 9);

    test('online: delegates to the cloud+outbox merge', () async {
      final cloud = [
        {'id': 'a', 'total': 100},
        {'id': 'b', 'total': 200},
      ];
      final outbox = [
        _entry(
          entityId: 'a',
          operation: SyncOperations.upsert,
          payload: {'id': 'a', 'total': 150},
          createdAt: t0,
        ),
      ];
      final p = _policy(
        cloudRows: cloud,
        outbox: outbox,
        localCache: const [
          {'id': 'IGNORED', 'total': 0},
        ],
      );
      final out = await p.policy.read();
      // Pending local upsert shadows the cloud copy; committed cloud row stands.
      expect(out.map(_idOf).toList(), ['a', 'b']);
      expect(out.firstWhere((r) => _idOf(r) == 'a')['total'], 150);
      // The local cache must NOT be consulted on a healthy online read.
      expect(p.localCalls(), 0);
    });

    test(
      'offline (cloud unreachable): serves the local cache and flags it',
      () async {
        final local = [
          {'id': 'a', 'total': 100},
          {'id': 'z', 'total': 7},
        ];
        final p = _policy(cloudThrows: true, localCache: local);
        final out = await p.policy.read();
        expect(out, local);
        expect(p.cloudCalls(), 1);
        expect(p.localCalls(), 1);
        expect(p.fellBack(), isA<_NetworkError>());
      },
    );

    test('a real refusal is surfaced, not masked as offline', () async {
      // Caller says: only fall back on connectivity; here every error is a
      // refusal, so the read must rethrow instead of showing stale rows.
      final p = _policy(
        cloudThrows: true,
        localCache: const [
          {'id': 'STALE', 'total': 1},
        ],
        shouldFallbackOnError: (_) => false,
      );
      await expectLater(p.policy.read(), throwsA(isA<_NetworkError>()));
      expect(p.localCalls(), 0); // never silently degrades
      expect(p.fellBack(), isNull); // fallback hook not fired
    });

    test('default policy degrades on any error (offline-first till)', () async {
      // No predicate supplied → every cloud error falls back so the till keeps
      // rendering. This is the product's core offline guarantee.
      final p = _policy(
        cloudThrows: true,
        localCache: const <Map<String, dynamic>>[],
      );
      final out = await p.policy.read();
      expect(out, isEmpty);
      expect(p.localCalls(), 1);
    });

    test('empty local cache still returns cleanly when offline', () async {
      // A brand-new device with nothing cached and no signal reads empty rather
      // than erroring.
      final p = _policy(cloudThrows: true, localCache: const []);
      expect(await p.policy.read(), isEmpty);
    });
  });
}
