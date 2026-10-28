import 'dart:convert';

import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/user_repository.dart';
import 'package:wholesale_pos_app/core/sync/sync_backend.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox_entry.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox_repository.dart';
import 'package:wholesale_pos_app/core/sync/sync_pull_applier.dart';
import 'package:wholesale_pos_app/core/sync/sync_service.dart';

/// Derives a credential exactly the way `pos-api` does for a browser account:
/// PBKDF2-HMAC-SHA256 over the DECODED salt bytes, stored as
/// `<iterations>$<base64>`.
Future<String> cloudCredential(
  String password,
  List<int> saltBytes, {
  int iterations = 2000,
}) async {
  final algorithm = cryptography.Pbkdf2(
    macAlgorithm: cryptography.Hmac(cryptography.Sha256()),
    iterations: iterations,
    bits: 256,
  );
  final key = await algorithm.deriveKey(
    secretKey: cryptography.SecretKey(utf8.encode(password)),
    nonce: saltBytes,
  );
  final bytes = await key.extractBytes();
  return '$iterations\$${base64.encode(bytes)}';
}

/// Backend double that serves pre-loaded rows one table at a time.
///
/// It paginates exactly like the gateway: the cursor is `{received_at, id}`
/// where `id` is the index of the last row served, and `has_more` is true while
/// rows remain. That makes the client's paging and cursor bookkeeping testable
/// without a network.
class PagingBackend implements SyncBackend {
  final Map<String, List<Map<String, dynamic>>> rows;
  final List<List<String>?> requestedTables = [];
  int pullCalls = 0;

  PagingBackend(this.rows);

  @override
  bool get isConfigured => true;

  @override
  Future<Set<String>> push(List<SyncOutboxEntry> entries) async =>
      entries.map((e) => e.id).toSet();

  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async {
    pullCalls++;
    requestedTables.add(tables);
    final table = tables!.single;
    final all = rows[table] ?? const <Map<String, dynamic>>[];
    final start = cursor == null ? 0 : int.parse(cursor['id']!);
    final page = all.skip(start).take(limit).toList();
    if (page.isEmpty) return const SyncPullResult.empty();
    final served = start + page.length;
    return SyncPullResult(
      changes: {table: page},
      nextCursor: {'received_at': 'stamp-$served', 'id': '$served'},
      hasMore: served < all.length,
    );
  }
}

Map<String, dynamic> cloudUser({
  String id = 'user-1',
  String username = '0700000001',
  String role = 'CASHIER',
  bool active = true,
  bool isDemo = false,
  String? pwSalt,
  String? pwHash,
  List<String> permissions = const ['pos'],
}) => {
  'id': id,
  'username': username,
  'role': role,
  'active': active,
  'pw_salt': pwSalt ?? 'salt-$id',
  'pw_hash': pwHash ?? 'hash-$id',
  'permissions': permissions,
  'is_demo': isDemo,
  'deleted_at': null,
  'created_at': '2026-10-28T08:00:00+00:00',
};

Map<String, dynamic> cloudShift({
  String id = 'shift-1',
  String cashierId = 'user-1',
  String deviceId = 'device-1',
  String status = 'CLOSED',
}) => {
  'id': id,
  'cashier_id': cashierId,
  'device_id': deviceId,
  'opening_cash_minor_units': 100000,
  'closing_cash_minor_units': null,
  'expected_cash_minor_units': null,
  'status': status,
  'opened_at': '2026-10-28T08:00:00+00:00',
  'closed_at': null,
};

Map<String, dynamic> cloudSale({
  String id = 'sale-1',
  String receipt = 'REC-20261028-0001',
  String cashierId = 'user-1',
  String deviceId = 'device-1',
  String shiftId = 'shift-1',
  String status = 'COMPLETED',
  String? voidReason,
  String createdAt = '2026-10-28T10:15:00+00:00',
}) => {
  'id': id,
  'receipt_number': receipt,
  'cashier_id': cashierId,
  'device_id': deviceId,
  'shift_id': shiftId,
  'customer_name': null,
  'payment_method': 'CASH',
  'subtotal_minor_units': 500,
  'discount_minor_units': 0,
  'total_minor_units': 500,
  'amount_paid_minor_units': 500,
  'change_minor_units': 0,
  'status': status,
  'void_reason': voidReason,
  'voided_at': status == 'VOIDED' ? '2026-10-28T11:00:00+00:00' : null,
  'voided_by': null,
  'voided_shift_id': null,
  'created_at': createdAt,
};

Map<String, dynamic> cloudItem({
  String id = 'item-1',
  String saleId = 'sale-1',
}) => {
  'id': id,
  'sale_id': saleId,
  'product_id': 'product-1',
  'product_name_snapshot': 'Sugar 1kg',
  'unit_price_snapshot_minor_units': 250,
  'quantity_text': '2',
  'billing_quantity_milliunits': null,
  'line_discount_minor_units': 0,
  'line_total_minor_units': 500,
  'notes': null,
};

SyncPullResult pageOf(String table, List<Map<String, dynamic>> rows) =>
    SyncPullResult(changes: {table: rows});

/// Seeds the reference rows a pre-existing LOCAL sale needs, so tests can put
/// one in place before a pull arrives.
Future<void> seedLocalSale(
  Database db, {
  required String saleId,
  required String receipt,
  String shiftStatus = 'CLOSED',
}) async {
  await db.insert('users', {
    'id': 'local-user',
    'username': '0711111111',
    'password_hash': 'pbkdf2-sha256\$v=1\$i=1000\$abc',
    'salt': 'localsalt',
    'role': 'OWNER',
    'is_active': 1,
    'permissions': '[]',
    'is_demo': 0,
    'deleted_at': null,
    'created_at': DateTime.now().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
  await db.insert('devices', {
    'id': 'local-device',
    'name': 'Local',
    'platform': 'windows',
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
  await db.insert('shifts', {
    'id': 'local-shift',
    'cashier_id': 'local-user',
    'opening_cash_minor_units': 0,
    'closing_cash_minor_units': null,
    'expected_cash_minor_units': null,
    'status': shiftStatus,
    'opened_at': DateTime.now().toIso8601String(),
    'closed_at': null,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
  await db.insert('sales', {
    'id': saleId,
    'receipt_number': receipt,
    'cashier_id': 'local-user',
    'device_id': 'local-device',
    'shift_id': 'local-shift',
    'payment_method': 'CASH',
    'subtotal_minor_units': 100,
    'discount_minor_units': 0,
    'total_minor_units': 100,
    'amount_paid_minor_units': 100,
    'change_minor_units': 0,
    'status': 'COMPLETED',
    'created_at': DateTime.now().toIso8601String(),
  });
}

void main() {
  late Database db;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
  });

  tearDown(() async {
    await db.close();
  });

  group('SyncPullApplier', () {
    test('lands a sale from another device with its foreign keys', () async {
      final applier = SyncPullApplier(db);

      await applier.apply(pageOf('users', [cloudUser()]));
      await applier.apply(pageOf('shifts', [cloudShift(status: 'CLOSED')]));
      final report = await applier.apply(pageOf('sales', [cloudSale()]));
      await applier.apply(pageOf('sale_items', [cloudItem()]));

      expect(report.sales, 1);
      expect(report.skipped, 0);

      final sale = (await db.query('sales')).single;
      expect(sale['cashier_id'], 'user-1');
      expect(sale['device_id'], 'device-1');
      expect((await db.query('devices')).single['id'], 'device-1');
      expect((await db.query('sale_items')).single['sale_id'], 'sale-1');

      // Local writes use local time with no zone suffix; a raw UTC string would
      // shift an evening sale into the wrong day for the date filters.
      expect(
        sale['created_at'],
        DateTime.parse('2026-10-28T10:15:00+00:00').toLocal().toIso8601String(),
      );
      expect('${sale['created_at']}'.contains('+'), isFalse);
    });

    test('carries the account credential so the account can sign in', () async {
      await SyncPullApplier(db).apply(pageOf('users', [cloudUser()]));

      final user = (await db.query('users')).single;
      // The web POS hash lives in its own pair: it is a different format, and a
      // password set on this PC must not be silently overwritten by a pull.
      expect(user['password_hash'], SyncPullApplier.cloudAccountMarker);
      expect(user['cloud_pw_hash'], 'hash-user-1');
      expect(user['cloud_pw_salt'], 'salt-user-1');
      expect(user['permissions'], '["pos"]');
    });

    test('accepts the browser password for an account created on the web', () async {
      // An account added in the PWA: hashed by `pos-api` over the decoded salt
      // bytes. Before this it could never sign in on a till.
      const password = 'browser-password-1';
      final saltBytes = List<int>.generate(16, (i) => i * 7 % 256);
      await SyncPullApplier(db).apply(
        pageOf('users', [
          cloudUser(
            pwSalt: base64.encode(saltBytes),
            pwHash: await cloudCredential(password, saltBytes),
          ),
        ]),
      );

      final repository = SqfliteUserRepository(db);
      final signedIn = await repository.authenticate('0700000001', password);
      expect(signedIn, isNotNull);
      expect(signedIn!.role, 'CASHIER');
      expect(await repository.authenticate('0700000001', 'wrong-one'), isNull);
    });

    test('merges the web demo credential onto this till\'s demo login', () async {
      // Every install seeds its own `demo` row; the browser seeds one too. Two
      // rows would mean the owner's browser password cannot open the demo here.
      await db.insert('users', {
        'id': 'local-demo',
        'username': 'demo',
        'password_hash': 'pbkdf2-sha256\$v=1\$i=2000\$never-matches',
        'salt': 'localdemo',
        'role': 'CASHIER',
        'is_active': 1,
        'permissions': '["pos"]',
        'is_demo': 1,
        'deleted_at': null,
        'created_at': DateTime.now().toIso8601String(),
      });

      const password = 'browser-demo-pw';
      final saltBytes = List<int>.generate(16, (i) => 200 - i);
      await SyncPullApplier(db).apply(
        pageOf('users', [
          cloudUser(
            id: 'cloud-demo',
            username: 'demo',
            isDemo: true,
            pwSalt: base64.encode(saltBytes),
            pwHash: await cloudCredential(password, saltBytes),
          ),
        ]),
      );

      final rows = await db.query('users');
      expect(rows, hasLength(1), reason: 'one demo login, not a demo# copy');
      expect(rows.single['id'], 'local-demo');
      expect(rows.single['cloud_pw_hash'], isNotNull);

      final signedIn = await SqfliteUserRepository(db)
          .authenticate('demo', password);
      expect(signedIn, isNotNull);
    });

    test('is idempotent: replaying the same page writes nothing', () async {
      final applier = SyncPullApplier(db);
      await applier.apply(pageOf('users', [cloudUser()]));
      await applier.apply(pageOf('shifts', [cloudShift()]));
      await applier.apply(pageOf('sales', [cloudSale()]));

      final replay = await applier.apply(pageOf('sales', [cloudSale()]));

      expect(replay.sales, 0);
      expect(await db.query('sales'), hasLength(1));
    });

    test('keeps a sale whose receipt number this till already used', () async {
      await seedLocalSale(db, saleId: 'local-sale', receipt: 'REC-1');

      final applier = SyncPullApplier(db);
      await applier.apply(pageOf('users', [cloudUser()]));
      await applier.apply(pageOf('shifts', [cloudShift()]));
      final report = await applier.apply(
        pageOf('sales', [cloudSale(receipt: 'REC-1')]),
      );

      expect(report.sales, 1);
      final receipts = (await db.query(
        'sales',
        columns: ['receipt_number'],
        orderBy: 'id ASC',
      )).map((r) => r['receipt_number']).toList();
      expect(receipts, contains('REC-1'));
      expect(receipts, contains('REC-1#device-1'));
      expect(await db.query('sales'), hasLength(2));
    });

    test('keeps another register\'s OPEN shift as a closed parent', () async {
      await seedLocalSale(
        db,
        saleId: 'local-sale',
        receipt: 'REC-L',
        shiftStatus: 'OPEN',
      );

      final report = await SyncPullApplier(db).apply(
        pageOf('shifts', [cloudShift(id: 'cloud-shift', status: 'OPEN')]),
      );

      expect(report.shifts, 1);
      final shift = (await db.query(
        'shifts',
        where: 'id = ?',
        whereArgs: ['cloud-shift'],
      )).single;
      expect(shift['status'], 'CLOSED');
      // The till's own drawer is untouched.
      expect(
        (await db.query('shifts', where: 'status = ?', whereArgs: ['OPEN'])),
        hasLength(1),
      );
    });

    test('a void decided on another device reaches this one', () async {
      await seedLocalSale(db, saleId: 'local-sale', receipt: 'REC-L');
      final applier = SyncPullApplier(db);

      await applier.apply(
        pageOf('sales', [
          cloudSale(id: 'local-sale', status: 'VOIDED', voidReason: 'Damaged'),
        ]),
      );

      final sale = (await db.query(
        'sales',
        where: 'id = ?',
        whereArgs: ['local-sale'],
      )).single;
      expect(sale['status'], 'VOIDED');
      expect(sale['void_reason'], 'Damaged');
    });

    test('a void is ignored while this till still has it queued', () async {
      await seedLocalSale(db, saleId: 'local-sale', receipt: 'REC-L');
      await db.insert('sync_outbox', {
        'id': 'outbox-1',
        'entity_type': 'sale',
        'entity_id': 'local-sale',
        'operation': 'UPSERT',
        'payload': '{}',
        'created_at': DateTime.now().toIso8601String(),
        'synced_at': null,
      });

      await SyncPullApplier(db).apply(
        pageOf('sales', [
          cloudSale(id: 'local-sale', status: 'VOIDED', voidReason: 'Remote'),
        ]),
      );

      final sale = (await db.query(
        'sales',
        where: 'id = ?',
        whereArgs: ['local-sale'],
      )).single;
      expect(sale['status'], 'COMPLETED');
    });
  });

  group('CloudSyncPuller', () {
    test(
      'pages one table at a time and remembers a cursor per table',
      () async {
        final backend = PagingBackend({
          'users': [
            cloudUser(id: 'user-1', username: '0700000001'),
            cloudUser(id: 'user-2', username: '0700000002'),
            cloudUser(id: 'user-3', username: '0700000003'),
          ],
          'sales': [cloudSale()],
        });
        final puller = CloudSyncPuller(backend: backend, db: db);

        final first = await puller.pullNow(pageSize: 2);

        expect(first.users, 3);
        // Every call asked for exactly one table.
        expect(backend.requestedTables.every((t) => t!.length == 1), isTrue);
        expect(
          await db.query('users'),
          hasLength(3),
          reason: 'a short page must still be drained to the end',
        );

        final stored = await db.query(
          'settings',
          where: 'key = ?',
          whereArgs: [CloudSyncPuller.cursorKeyFor('users')],
        );
        expect(stored, hasLength(1));
        expect(backend.pullCalls, greaterThan(1));

        // Second run resumes from the stored cursor: nothing new to apply.
        final second = await puller.pullNow(pageSize: 2);
        expect(second.users, 0);
        expect(await db.query('users'), hasLength(3));
      },
    );

    test('does nothing when the backend is not configured', () async {
      final puller = CloudSyncPuller(backend: const NoopSyncBackend(), db: db);
      expect((await puller.pullNow()).isEmpty, isTrue);
    });
  });

  group('SyncService', () {
    test('pulls even when the outbox is empty', () async {
      final backend = PagingBackend({
        'users': [cloudUser()],
      });
      final service = SyncService(
        SyncOutboxRepository(db),
        backend,
        puller: CloudSyncPuller(backend: backend, db: db),
      );

      final result = await service.syncNow();

      expect(result.pushed, 0);
      expect(result.applied, greaterThan(0));
      expect(await db.query('users'), hasLength(1));
    });

    test('reports no backend instead of pretending to sync', () async {
      final service = SyncService(
        SyncOutboxRepository(db),
        const NoopSyncBackend(),
      );
      expect((await service.syncNow()).skipped, isTrue);
    });
  });
}
