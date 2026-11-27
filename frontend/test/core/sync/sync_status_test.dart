import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_cloud_engine/pos_cloud_engine.dart';
import 'package:wholesale_pos_app/core/sync/sync_service.dart';

/// Backend double whose every call fails the way the named error says.
class _FailingBackend implements SyncBackend {
  final Object error;
  int calls = 0;

  _FailingBackend(this.error);

  @override
  bool get isConfigured => true;

  @override
  Future<SyncPushOutcome> push(List<SyncOutboxEntry> entries) async {
    calls++;
    throw error;
  }

  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async {
    calls++;
    throw error;
  }
}

/// Backend double that serves one account on the first pull and nothing after,
/// so a cycle reports exactly one applied row.
class _OneUserBackend implements SyncBackend {
  bool served = false;

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
    if (served) return const SyncPullResult.empty();
    served = true;
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
            'created_at': '2026-10-28T08:00:00+00:00',
          },
        ],
      },
    );
  }
}

Map<String, dynamic> _gatewayBody(String error) => {
  'ok': false,
  'error': error,
};

void main() {
  late Database db;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
  });

  tearDown(() async {
    await db.close();
  });

  group('SyncGatewayBackend', () {
    SyncGatewayBackend gateway(http.Client client) => SyncGatewayBackend(
      fnUrl: 'https://example.test/sync',
      licenseProvider: () async => 'signed.licence',
      client: client,
    );

    test(
      'reports a refused licence as an auth failure, not a network error',
      () async {
        const serverSays = 'License format not supported by sync.';
        final backend = gateway(
          MockClient(
            (_) async => http.Response(
              jsonEncode(_gatewayBody(serverSays)),
              401,
              headers: const {'content-type': 'application/json'},
            ),
          ),
        );

        await expectLater(
          backend.pull(tables: const ['sales']),
          throwsA(
            isA<SyncAuthException>().having(
              (e) => e.message,
              'message',
              serverSays,
            ),
          ),
        );
        await expectLater(
          backend.push(const []),
          throwsA(isA<SyncAuthException>()),
        );
      },
    );

    test('a server error stays a plain failure', () async {
      final backend = gateway(
        MockClient((_) async => http.Response('upstream unavailable', 503)),
      );

      await expectLater(
        backend.pull(tables: const ['sales']),
        throwsA(
          isA<Exception>().having(
            (e) => e is SyncAuthException,
            'isAuthFailure',
            isFalse,
          ),
        ),
      );
    });

    test(
      'an un-activated device says so instead of pretending to sync',
      () async {
        final backend = SyncGatewayBackend(
          fnUrl: 'https://example.test/sync',
          licenseProvider: () async => null,
        );

        await expectLater(
          backend.pull(tables: const ['sales']),
          throwsA(
            isA<SyncAuthException>().having(
              (e) => e.message,
              'message',
              contains('no activation code'),
            ),
          ),
        );
      },
    );
  });

  group('SyncService status', () {
    test('a refused licence is visible and marked unretryable', () async {
      final backend = _FailingBackend(
        const SyncAuthException('License format not supported by sync.'),
      );
      final service = SyncService(
        SqfliteSyncOutboxRepository(db),
        backend,
        puller: CloudSyncPuller(backend: backend, db: db),
      );

      final result = await service.syncNow();

      expect(result.ok, isFalse);
      expect(backend.calls, greaterThan(0));
      final status = service.status.value;
      expect(status.error, 'License format not supported by sync.');
      expect(status.authenticationFailed, isTrue);
      expect(status.lastSuccess, isNull);
      expect(status.summary, contains('activation code'));
    });

    test('being offline is not an activation problem', () async {
      final backend = _FailingBackend(Exception('Connection refused'));
      final service = SyncService(
        SqfliteSyncOutboxRepository(db),
        backend,
        puller: CloudSyncPuller(backend: backend, db: db),
      );

      await service.syncNow();

      final status = service.status.value;
      expect(status.authenticationFailed, isFalse);
      expect(status.error, 'Connection refused');
      expect(status.summary, contains('Last sync failed'));
    });

    test(
      'a good cycle clears the error and counts what it downloaded',
      () async {
        final backend = _OneUserBackend();
        final service = SyncService(
          SqfliteSyncOutboxRepository(db),
          backend,
          puller: CloudSyncPuller(backend: backend, db: db),
        );

        final result = await service.syncNow();

        expect(result.ok, isTrue);
        expect(result.applied, 1);
        final status = service.status.value;
        expect(status.isConnected, isTrue);
        expect(status.error, isNull);
        expect(status.applied, 1);
        expect(status.lastSuccess, isNotNull);
      },
    );

    test('an offline build reports itself as disabled', () async {
      final service = SyncService(
        SqfliteSyncOutboxRepository(db),
        const NoopSyncBackend(),
      );

      final result = await service.syncNow();

      expect(result.skipped, isTrue);
      expect(service.status.value.configured, isFalse);
      expect(service.status.value.summary, contains('off on this build'));
    });
  });
}
