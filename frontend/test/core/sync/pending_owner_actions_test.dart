import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_cloud_engine/pos_cloud_engine.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wholesale_pos_app/core/sync/owner_action_reconciler.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
  });
  tearDown(() => db.close());

  group('PendingOwnerActions', () {
    test('record/load round-trips inside a transaction', () async {
      await db.transaction((txn) async {
        await PendingOwnerActions.record(
          txn,
          kind: PendingOwnerActions.voidSale,
          targetId: 'sale-1',
          localUserId: 'owner-1',
          reason: 'mistake',
        );
      });
      final pending = await PendingOwnerActions.load(db);
      expect(pending, hasLength(1));
      expect(pending.single.kind, 'void_sale');
      expect(pending.single.targetId, 'sale-1');
      expect(pending.single.reason, 'mistake');
    });

    test('re-recording the same target dedupes', () async {
      for (var i = 0; i < 2; i++) {
        await db.transaction((txn) => PendingOwnerActions.record(
              txn,
              kind: PendingOwnerActions.approveVoid,
              targetId: 'vr-1',
              localUserId: 'owner-1',
            ));
      }
      expect(await PendingOwnerActions.load(db), hasLength(1));
    });

    test('removeConfirmed keeps unconfirmed entries', () async {
      await db.transaction((txn) async {
        await PendingOwnerActions.record(
            txn,
            kind: PendingOwnerActions.voidSale,
            targetId: 's1',
            localUserId: 'u');
        await PendingOwnerActions.record(
            txn,
            kind: PendingOwnerActions.rejectVoid,
            targetId: 'r1',
            localUserId: 'u');
      });
      await PendingOwnerActions.removeConfirmed(db, {'void_sale:s1'});
      final rest = await PendingOwnerActions.load(db);
      expect(rest.single.kind, 'reject_void');
    });
  });

  group('OwnerActionReconciler', () {
    OwnerActionReconciler reconcilerWith(MockClient client) =>
        OwnerActionReconciler(
          db: db,
          api: CloudApiClient(
            url: 'http://test.local/pos-api',
            client: client,
            activationCode: 'ACT-1',
          ),
          activationCode: 'ACT-1',
        );

    Future<void> seedPending() => db.transaction((txn) async {
          await PendingOwnerActions.record(
            txn,
            kind: PendingOwnerActions.voidSale,
            targetId: 'sale-1',
            localUserId: 'owner-1',
            reason: 'oops',
          );
        });

    test('confirmed actions are removed after server ok', () async {
      await seedPending();
      final client = MockClient((req) async {
        final body = req.body;
        if (body.contains('"login"')) {
          return http.Response(
              '{"ok":true,"token":"jwt-1"}', 200);
        }
        if (body.contains('"void_sale"')) {
          return http.Response('{"ok":true}', 200);
        }
        if (body.contains('"search_sales"')) {
          return http.Response(
              '{"ok":true,"sales":[{"id":"sale-1","status":"COMPLETED"}]}',
              200);
        }
        return http.Response('{"ok":false,"error":"unexpected"}', 400);
      });
      final result = await reconcilerWith(client).reconcile(
        username: '0912345678',
        password: 'secret-password',
      );
      expect(result.confirmed, 1);
      expect(result.stillPending, 0);
      expect(await PendingOwnerActions.load(db), isEmpty);
    });

    test('failed login keeps everything pending', () async {
      await seedPending();
      final client = MockClient((req) async =>
          http.Response('{"ok":false,"error":"Invalid credentials."}', 401));
      final result = await reconcilerWith(client).reconcile(
        username: '0912345678',
        password: 'wrong',
      );
      expect(result.authFailed, isTrue);
      expect(result.confirmed, 0);
      expect(await PendingOwnerActions.load(db), hasLength(1));
    });

    test('non-owner refusal keeps entries pending', () async {
      await seedPending();
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (calls == 1) return http.Response('{"ok":true,"token":"jwt"}', 200);
        return http.Response('{"ok":false,"error":"Owner access required."}', 403);
      });
      final result = await reconcilerWith(client).reconcile(
        username: 'cashier',
        password: 'pw',
      );
      expect(result.confirmed, 0);
      expect(await PendingOwnerActions.load(db), hasLength(1));
    });

    test('no api url configured reports pending without network', () async {
      await seedPending();
      final reconciler = OwnerActionReconciler(
        db: db,
        api: CloudApiClient(url: ''),
        activationCode: '',
      );
      final result = await reconciler.reconcile(
        username: 'u',
        password: 'p',
      );
      expect(result.confirmed, 0);
      expect(result.stillPending, 1);
      expect(await PendingOwnerActions.load(db), hasLength(1));
    });
  });
}
