import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:wholesale_pos_app/core/sync/sync_service.dart';

/// Request 3 P1: an operator retry on a quarantined record must go through
/// the server-side recovery path — never a bare local requeue that the
/// still-REJECTED staged row would refuse identically forever.
class _RecoveryBackend implements SyncBackend, SyncRecoveryBackend {
  SyncRecoveryOutcome outcome = const SyncRecoveryOutcome();
  List<SyncOutboxEntry> recovered = const [];

  @override
  bool get isConfigured => true;

  @override
  Future<SyncPushOutcome> push(List<SyncOutboxEntry> entries) async =>
      SyncPushOutcome.empty;

  @override
  Future<SyncRecoveryOutcome> recover(List<SyncOutboxEntry> entries) async {
    recovered = entries;
    return outcome;
  }

  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async => const SyncPullResult.empty();
}

class _PlainBackend implements SyncBackend {
  @override
  bool get isConfigured => true;

  @override
  Future<SyncPushOutcome> push(List<SyncOutboxEntry> entries) async =>
      SyncPushOutcome.empty;

  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async => const SyncPullResult.empty();
}

void main() {
  late Database db;
  late SqfliteSyncOutboxRepository outbox;

  setUp(() async {
    sqfliteFfiInit();
    db = await LocalDatabase.openInMemory();
    outbox = SqfliteSyncOutboxRepository(db);
    await db.insert('sync_outbox', {
      'id': 'e1',
      'entity_type': SyncEntities.sale,
      'entity_id': 'sale-e1',
      'operation': 'UPSERT',
      'payload': '{}',
      'created_at': DateTime(2026).toIso8601String(),
    });
    await outbox.markQuarantined({'e1': 'server refused'});
  });

  tearDown(() async => db.close());

  test('retry asks the backend to recover and applies the verdicts', () async {
    final backend = _RecoveryBackend()
      ..outcome = const SyncRecoveryOutcome(
        applied: {'e1'},
        retryable: {'e2'},
      );
    final service = SyncService(outbox, backend);
    final report = await service.retryQuarantined(['e1']);
    expect(report.supported, isTrue);
    expect(report.applied, 1);
    expect(backend.recovered.single.id, 'e1');
    // Applied verdict marks the outbox row synced — it leaves quarantine.
    expect(await outbox.quarantined(), isEmpty);
    expect(await outbox.pendingCount(), 0);
  });

  test('a still-refused record stays quarantined with the new reason',
      () async {
    final backend = _RecoveryBackend()
      ..outcome = const SyncRecoveryOutcome(
        rejected: [
          SyncPushRejection(
            entryId: 'e1',
            entityId: 'sale-e1',
            error: 'still invalid',
          ),
        ],
      );
    final service = SyncService(outbox, backend);
    final report = await service.retryQuarantined(['e1']);
    expect(report.reRejected, 1);
    final held = await outbox.quarantined();
    expect(held.single.lastError, 'still invalid');
  });

  test('deferred/stored verdicts return the row to the pending queue',
      () async {
    final backend = _RecoveryBackend()
      ..outcome = const SyncRecoveryOutcome(retryable: {'e1'});
    final service = SyncService(outbox, backend);
    final report = await service.retryQuarantined(['e1']);
    expect(report.requeued, 1);
    expect(await outbox.quarantined(), isEmpty);
    expect(await outbox.pendingCount(), 1);
  });

  test('a backend without recovery reports unsupported and requeues nothing',
      () async {
    final service = SyncService(outbox, _PlainBackend());
    final report = await service.retryQuarantined(['e1']);
    expect(report.supported, isFalse);
    expect(await outbox.quarantined().then((q) => q.single.id), 'e1');
    expect(await outbox.pendingCount(), 0);
  });
}
