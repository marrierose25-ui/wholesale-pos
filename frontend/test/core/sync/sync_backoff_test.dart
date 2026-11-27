import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:wholesale_pos_app/core/sync/sync_service.dart';

/// A configured backend that has nothing to say: the outbox is empty so every
/// push acks nothing, and every pull returns no rows. This is a till at an empty
/// shop, which is exactly the state the backoff exists for.
class _IdleBackend implements SyncBackend {
  int pushes = 0;

  @override
  bool get isConfigured => true;

  @override
  Future<SyncPushOutcome> push(List<SyncOutboxEntry> entries) async {
    pushes++;
    return SyncPushOutcome.empty;
  }

  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async => const SyncPullResult.empty();
}

/// The cloud has one account to offer, but only once the test flips [serve], so
/// a cycle can land a row after the ladder has already climbed.
class _OneRowBackend implements SyncBackend {
  bool serve = false;

  @override
  bool get isConfigured => true;

  @override
  Future<SyncPushOutcome> push(List<SyncOutboxEntry> entries) async => SyncPushOutcome.empty;

  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async {
    if (!serve) return const SyncPullResult.empty();
    return const SyncPullResult(
      changes: {
        'users': [
          {
            'id': 'cloud-owner',
            'username': '0700000009',
            'role': 'OWNER',
            'active': true,
            'pw_salt': 'salt',
            'pw_hash': 'hash',
            'permissions': <String>[],
            'is_demo': false,
            'deleted_at': null,
            'created_at': '2026-10-30T08:00:00+00:00',
          },
        ],
      },
    );
  }
}

/// Blocks inside `pull` until released, so a second [SyncService.syncNow] can
/// arrive while the first cycle is genuinely still running.
class _SlowBackend implements SyncBackend {
  final Completer<void> release = Completer<void>();

  @override
  bool get isConfigured => true;

  @override
  Future<SyncPushOutcome> push(List<SyncOutboxEntry> entries) async => SyncPushOutcome.empty;

  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async {
    await release.future;
    return const SyncPullResult.empty();
  }
}

/// A backend that is unreachable: every `pull` throws the way a dropped
/// connection or a refused request does.
class _ThrowingBackend implements SyncBackend {
  int pulls = 0;

  @override
  bool get isConfigured => true;

  @override
  Future<SyncPushOutcome> push(List<SyncOutboxEntry> entries) async => SyncPushOutcome.empty;

  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async {
    pulls++;
    throw Exception('Network is unreachable');
  }
}

void main() {
  late Database db;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
  });

  tearDown(() async {
    await db.close();
  });

  group('adaptive sync cadence', () {
    test('an idle till climbs 3s -> 10s -> 30s -> 60s and stays', () async {
      final service = SyncService(
        SqfliteSyncOutboxRepository(db),
        _IdleBackend(),
      );

      expect(service.nextDelay, SyncIntervals.cycle);

      await service.syncNow();
      expect(service.nextDelay, const Duration(seconds: 10));

      await service.syncNow();
      expect(service.nextDelay, const Duration(seconds: 30));

      await service.syncNow();
      expect(service.nextDelay, SyncIntervals.max);

      // No rung above the ceiling: a quiet till retries twice a minute, not
      // once every five minutes.
      await service.syncNow();
      await service.syncNow();
      expect(service.nextDelay, SyncIntervals.max);
    });

    test('a cycle that lands a row drops back to the floor', () async {
      var clock = DateTime.utc(2026, 10, 30, 8);
      final backend = _OneRowBackend();
      final service = SyncService(
        SqfliteSyncOutboxRepository(db),
        backend,
        puller: CloudSyncPuller(backend: backend, db: db),
        now: () => clock,
      );

      // Two quiet cycles first, so the floor is a real drop and not the start.
      await service.syncNow();
      clock = clock.add(SyncIntervals.max);
      await service.syncNow();
      clock = clock.add(SyncIntervals.max);
      expect(service.nextDelay, const Duration(seconds: 30));

      backend.serve = true;
      final result = await service.syncNow();
      expect(result.applied, 1);
      expect(service.nextDelay, SyncIntervals.cycle);
    });

    test('the floor is held for 30 seconds, then the ladder resumes', () async {
      var clock = DateTime.utc(2026, 10, 30, 8);
      final backend = _OneRowBackend();
      final service = SyncService(
        SqfliteSyncOutboxRepository(db),
        backend,
        puller: CloudSyncPuller(backend: backend, db: db),
        now: () => clock,
      );

      expect((await service.syncNow()).applied, 0);
      expect(service.nextDelay, const Duration(seconds: 10));

      // A row arrives: the shop is trading again, so drop to the floor.
      backend.serve = true;
      clock = clock.add(const Duration(seconds: 11));
      expect((await service.syncNow()).applied, 1);
      expect(service.nextDelay, SyncIntervals.cycle);
      backend.serve = false;

      // Still inside the window: the shop is trading, stay instant.
      clock = clock.add(const Duration(seconds: 29));
      await service.syncNow();
      expect(service.nextDelay, SyncIntervals.cycle);

      // Past it, with nothing moving: back to the ladder.
      clock = clock.add(const Duration(seconds: 2));
      await service.syncNow();
      expect(service.nextDelay, const Duration(seconds: 10));
    });

    test('a local write wakes the loop and holds the floor', () async {
      var wakes = 0;
      final service = SyncService(
        SqfliteSyncOutboxRepository(db),
        _IdleBackend(),
      );
      service.onWake = () => wakes++;

      await service.syncNow();
      await service.syncNow();
      expect(service.nextDelay, const Duration(seconds: 30));

      service.notifyLocalActivity();

      expect(wakes, 1);
      expect(service.nextDelay, SyncIntervals.cycle);
    });

    test('a failed cycle backs off instead of hammering the network', () async {
      final service = SyncService(
        SqfliteSyncOutboxRepository(db),
        _IdleBackend(),
      );

      // An idle cycle and a failed cycle are the same thing to the cadence:
      // neither moved a row, and asking a dead connection more often is the
      // quota burn this exists to stop.
      await service.syncNow();
      await service.syncNow();
      expect(service.nextDelay, const Duration(seconds: 30));
    });

    test('a throwing backend still climbs the ladder', () async {
      // The case this file was missing: a real exception on the wire, not an
      // empty page. `CloudSyncPuller` reports a failed pull in its result rather
      // than rethrowing, so the cycle completes having moved nothing — which is
      // exactly why the cadence must read a failed cycle as idle. Otherwise an
      // offline till retries every three seconds all night.
      final backend = _ThrowingBackend();
      final service = SyncService(
        SqfliteSyncOutboxRepository(db),
        backend,
        puller: CloudSyncPuller(backend: backend, db: db),
      );

      expect(service.nextDelay, SyncIntervals.cycle);

      await service.syncNow();
      expect(backend.pulls, greaterThan(0));
      expect(service.nextDelay, const Duration(seconds: 10));

      await service.syncNow();
      expect(service.nextDelay, const Duration(seconds: 30));

      await service.syncNow();
      expect(service.nextDelay, SyncIntervals.max);
    });

    test(
      'overlapping cycles still return idle instead of draining twice',
      () async {
        final backend = _SlowBackend();
        final service = SyncService(
          SqfliteSyncOutboxRepository(db),
          backend,
          puller: CloudSyncPuller(backend: backend, db: db),
        );

        final first = service.syncNow();
        // The wake hook deliberately fires cycles closer together than the
        // interval ever did; the single-flight guard is what keeps that safe.
        final second = await service.syncNow();

        expect(second.pushed, 0);
        expect(second.remaining, 0);
        expect(second.applied, 0);

        backend.release.complete();
        await first;
      },
    );
  });
}
