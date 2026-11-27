import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wholesale_pos_app/core/sync/owner_bootstrap_service.dart';

void main() {
  late Database db;

  const ownerId = 'owner-local-1';

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    await db.insert('users', {
      'id': ownerId,
      'username': '0912345678',
      'password_hash': 'local-hash',
      'salt': 'local-salt',
      'cloud_pw_hash': '210000\$AAAA',
      'cloud_pw_salt': 'c2FsdA==',
      'role': 'OWNER',
      'is_active': 1,
      'permissions': '[]',
      'is_demo': 0,
      'created_at': '2026-01-01T00:00:00Z',
    });
    await db.insert('sync_outbox', {
      'id': 'out-1',
      'entity_type': 'user',
      'entity_id': ownerId,
      'operation': 'UPSERT',
      'payload': '{}',
      'created_at': '2026-01-01T00:00:00Z',
    });
  });
  tearDown(() => db.close());

  OwnerBootstrapService service(http.Client client) => OwnerBootstrapService(
        db: db,
        apiUrl: 'https://example.test/pos-api',
        activationCodeProvider: () async => 'CODE-1234',
        client: client,
      );

  http.Client jsonClient(Map<String, dynamic> body, {int status = 200}) =>
      MockClient((_) async => http.Response(
            jsonEncode(body),
            status,
            headers: {'content-type': 'application/json'},
          ));

  test('session-less ok reconciles and marks bootstrap done', () async {
    // The pass-the-hash fix: a pre-hashed retry now returns ok WITHOUT a
    // token. Reconciliation must not depend on receiving a JWT.
    final res = await service(jsonClient({
      'ok': true,
      'reconciled': true,
      'user_id': ownerId,
      'username': '0912345678',
      'role': 'OWNER',
      'customer_id': 'cust-1',
    })).reconcile();

    expect(res.status, OwnerBootstrapStatus.bootstrapped);
    expect(
      await LocalDatabase.getSetting(
          db, OwnerBootstrapService.stateKey(ownerId)),
      'done',
    );
    final outbox = await db.query('sync_outbox', where: 'id = ?', whereArgs: ['out-1']);
    expect(outbox.single['synced_at'], isNotNull);
  });

  test('session-less created response also completes bootstrap', () async {
    final res = await service(jsonClient({
      'ok': true,
      'created': true,
      'user_id': ownerId,
      'username': '0912345678',
      'role': 'OWNER',
      'customer_id': 'cust-1',
    })).reconcile();
    expect(res.status, OwnerBootstrapStatus.bootstrapped);
  });

  test('409 with a different owner id is a conflict, not done', () async {
    final res = await service(jsonClient({
      'ok': false,
      'error': 'Owner already exists.',
      'owner_id': 'other-owner',
      'owner_username': '0999',
    }, status: 409)).reconcile();
    expect(res.status, OwnerBootstrapStatus.conflict);
    expect(
      await LocalDatabase.getSetting(
          db, OwnerBootstrapService.stateKey(ownerId)),
      'conflict',
    );
    final outbox = await db.query('sync_outbox', where: 'id = ?', whereArgs: ['out-1']);
    expect(outbox.single['synced_at'], isNull);
  });

  test('409 naming this owner id still completes (lost-response retry)', () async {
    final res = await service(jsonClient({
      'ok': false,
      'error': 'Owner already exists.',
      'owner_id': ownerId,
      'owner_username': '0912345678',
    }, status: 409)).reconcile();
    expect(res.status, OwnerBootstrapStatus.bootstrapped);
  });

  test('unreachable cloud stays pending and retries later', () async {
    final res = await service(MockClient((_) async => throw http.ClientException('down')))
        .reconcile();
    expect(res.status, OwnerBootstrapStatus.pending);
    expect(
      await LocalDatabase.getSetting(
          db, OwnerBootstrapService.stateKey(ownerId)),
      isNull,
    );
  });

  test('a completed pass is not repeated', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response(jsonEncode({'ok': true, 'user_id': ownerId}), 200);
    });
    final svc = service(client);
    await svc.reconcile();
    final second = await svc.reconcile();
    expect(second.status, OwnerBootstrapStatus.bootstrapped);
    expect(calls, 1, reason: 'second pass must be served from the done marker');
  });
}
