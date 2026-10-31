import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/models/product.dart';
import 'package:wholesale_pos_app/core/repositories/finance_repository.dart';
import 'package:wholesale_pos_app/core/repositories/product_repository.dart';
import 'package:wholesale_pos_app/core/repositories/shift_repository.dart';
import 'package:wholesale_pos_app/core/repositories/user_repository.dart';
import 'package:wholesale_pos_app/core/sync/sync_backend.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox_entry.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox_repository.dart';
import 'package:wholesale_pos_app/core/sync/sync_pull_applier.dart';

/// One page of the delta feed, in the shape the gateway returns it.
SyncPullResult pageOf(String table, List<Map<String, dynamic>> rows) =>
    SyncPullResult(changes: {table: rows});

Map<String, dynamic> cloudProduct({
  String id = 'prod-1',
  String name = 'Sugar 50kg',
  String? code = 'SGR50',
  int price = 250000,
  int isActive = 1,
  String updatedAt = '2026-10-28T10:00:00+00:00',
}) => {
  'id': id,
  'name': name,
  'code': code,
  'category': 'grocery',
  'unit': 'bag',
  'selling_price_minor_units': price,
  'is_active': isActive,
  'created_at': '2026-10-01T08:00:00+00:00',
  'updated_at': updatedAt,
};

Map<String, dynamic> cloudPerson({
  String id = 'person-1',
  String name = 'Alemu',
  String updatedAt = '2026-10-28T10:00:00+00:00',
  String? deletedAt,
}) => {
  'id': id,
  'name': name,
  'created_at': '2026-10-01T08:00:00+00:00',
  'updated_at': updatedAt,
  'deleted_at': deletedAt,
};

Map<String, dynamic> cloudEntry({
  String id = 'entry-1',
  String categoryId = 'person-1',
  int amount = 500000,
  String status = 'PENDING',
  String? completedAt,
  String updatedAt = '2026-10-28T10:00:00+00:00',
}) => {
  'id': id,
  'category_id': categoryId,
  'source': 'Delivery',
  'amount_minor_units': amount,
  'description': 'first tranche',
  'status': status,
  'entry_date': '2026-10-20T06:00:00+00:00',
  'created_at': '2026-10-20T06:00:00+00:00',
  'created_by': 'user-cloud',
  'completed_at': completedAt,
  'completed_by': null,
  'updated_at': updatedAt,
  'payment_method': 'CASH',
};

/// A deposit as the cloud serves it. `source_finance_entry_id` is what makes two
/// rows written by two different devices recognisably the same money.
Map<String, dynamic> cloudMovement({
  String id = 'mv-1',
  String? sourceEntry = 'entry-1',
  int amount = 10000,
  String? photo,
}) => {
  'id': id,
  'shift_id': 'shift-1',
  'user_id': 'user-1',
  'type': 'DEPOSIT',
  'amount_minor_units': amount,
  'reason': 'Collected from Alemu',
  'created_at': '2026-10-28T10:00:00+00:00',
  'source_finance_entry_id': sourceEntry,
  'photo': ?photo,
};

void main() {
  late Database db;
  late SyncOutboxRepository outbox;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    outbox = SyncOutboxRepository(db);
    await db.insert('users', {
      'id': 'user-1',
      'username': '0911111111',
      'password_hash': 'pbkdf2-sha256\$v=1\$i=1000\$abc',
      'salt': 's',
      'role': 'OWNER',
      'is_active': 1,
      'permissions': '[]',
      'is_demo': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'user-1',
      'opening_cash_minor_units': 0,
      'status': 'OPEN',
      'opened_at': DateTime.now().toIso8601String(),
    });
  });

  tearDown(() async {
    await db.close();
  });

  /// A local saved name with a KNOWN age, so newest-wins is deterministic
  /// instead of depending on when the test ran.
  Future<void> seedLocalProduct({
    required String id,
    int price = 1000,
    String code = 'LOCAL',
    String updatedAt = '2026-10-01T00:00:00.000',
  }) async {
    await db.insert('products', {
      'id': id,
      'name': 'Local name',
      'code': code,
      'unit': 'kg',
      'selling_price_minor_units': price,
      'is_active': 1,
      'created_at': '2026-09-01T00:00:00.000',
      'updated_at': updatedAt,
    });
  }

  group('outbox timestamps', () {
    test('a naive local instant is uploaded as the same moment in UTC', () {
      // The heart of the two-way date bug: Postgres reads a suffix-free string
      // in its own zone (UTC), so an East-African 14:00 would otherwise be
      // filed as 14:00 UTC and shown three hours late on every other surface.
      final converted = SyncOutbox.timestampsToUtc({
        'updated_at': '2026-10-28T14:00:00.000',
        'entry_date': '2026-10-28T14:00:00.000',
        'name': '2026-10-28T14:00:00.000',
        'amount_minor_units': '2026',
      });
      final offset = DateTime.parse('2026-10-28T14:00:00.000')
          .toUtc()
          .toIso8601String();
      expect(converted['updated_at'], offset);
      expect(converted['entry_date'], offset);
      // Only `..._at` / `..._date` columns move; a value that parses but is not
      // a timestamp column is left alone.
      expect(converted['name'], '2026-10-28T14:00:00.000');
      expect(converted['amount_minor_units'], '2026');
    });

    test('an already-UTC value is passed through untouched', () {
      final converted = SyncOutbox.timestampsToUtc({
        'created_at': '2026-10-28T14:00:00Z',
      });
      expect(converted['created_at'], '2026-10-28T14:00:00Z');
    });
  });

  group('enqueue', () {
    test('a saved name is queued as whole master-data rows', () async {
      final products = ProductRepository(db);
      final now = DateTime.now();
      await products.save(
        Product(
          id: 'prod-1',
          name: 'Wheat',
          code: 'WHT',
          unit: 'quintal',
          sellingPriceMinorUnits: 120000,
          createdAt: now,
          updatedAt: now,
        ),
      );

      var pending = await outbox.pending();
      expect(pending, hasLength(1));
      expect(pending.single.entityType, SyncEntities.product);
      expect(pending.single.entityId, 'prod-1');
      expect((pending.single.payload['product'] as Map)['name'], 'Wheat');

      // Master data is mutable: a price edit must queue AGAIN rather than be
      // dropped as a duplicate of the create, or the cloud would keep the old
      // price while the till showed the new one.
      await products.update(
        Product(
          id: 'prod-1',
          name: 'Wheat',
          code: 'WHT',
          unit: 'quintal',
          sellingPriceMinorUnits: 130000,
          createdAt: now,
          updatedAt: now.add(const Duration(minutes: 5)),
        ),
      );
      pending = await outbox.pending();
      expect(pending, hasLength(2));
      expect(
        pending.every((e) => e.entityType == SyncEntities.product),
        isTrue,
      );
      final latest = pending.last.payload['product'] as Map;
      expect(latest['selling_price_minor_units'], 130000);
      expect(latest['updated_at'], isNotNull);
    });

    test('an account is queued without its local credential', () async {
      final users = SqfliteUserRepository(db);
      await users.createUser(
        '0922222222',
        'cashier-password',
        'CASHIER',
        permissions: const ['pos'],
      );

      final pending = await outbox.pending();
      final entry = pending.singleWhere(
        (e) => e.entityType == SyncEntities.user,
      );
      final row = entry.payload['user'] as Map;
      // The till's own PBKDF2 pair never leaves the device; only the format the
      // browser can verify is published, and the server treats it as opaque.
      expect(row.containsKey('password_hash'), isFalse);
      expect(row.containsKey('salt'), isFalse);
      expect(row['pw_hash'], isNotNull);
      // The cloud's own format: `<iterations>$<base64>` derived over the
      // decoded salt bytes, which is what `pos-api` can verify.
      expect(
        RegExp(r'^\d+\$[A-Za-z0-9+/]+={0,2}$').hasMatch('${row['pw_hash']}'),
        isTrue,
      );
      expect(row['pw_salt'], isNotNull);
      expect(row['username'], '0922222222');
      expect(row['updated_at'], isNotNull);
    });

    test('deactivating an account re-queues it', () async {
      final users = SqfliteUserRepository(db);
      await users.createUser('0922222222', 'cashier-password', 'CASHIER');
      final before = (await outbox.pending()).length;

      final created = (await users.getAllUsers()).firstWhere(
        (u) => u.username == '0922222222',
      );
      await users.setUserActive(
        targetUserId: created.id,
        active: false,
        actingUserId: 'user-1',
      );

      final after = await outbox.pending();
      expect(after.length, greaterThan(before));
      final flipped = after.lastWhere((e) => e.entityType == SyncEntities.user);
      expect((flipped.payload['user'] as Map)['is_active'], 0);
    });

    test('the money tracker queues people, entries and a purge', () async {
      final finance = SqfliteFinanceRepository(db);
      final person = await finance.createCategory(
        ownerId: 'user-1',
        name: 'Alemu',
      );
      final entry = await finance.addEntry(
        ownerId: 'user-1',
        categoryId: person.id,
        source: 'Delivery',
        amountMinorUnits: 5000,
        paymentMethod: 'CASH',
      );
      await finance.markCompleted(ownerId: 'user-1', entryId: entry.id);

      final pending = await outbox.pending();
      List<String> idsOf(String type) => pending
          .where((e) => e.entityType == type)
          .map((e) => e.entityId)
          .toList();
      expect(idsOf(SyncEntities.financeCategory), [person.id]);
      // Two edits to one collection: added, then marked taken. Both must go.
      expect(idsOf(SyncEntities.financeEntry), hasLength(2));
      // A cash collection physically enters the drawer, so the deposit is
      // queued too — that is what moves the Register Shift on every surface.
      expect(idsOf(SyncEntities.cashMovement), hasLength(1));
      // The queued deposit has to name its collection. The cloud refuses a second
      // deposit for one entry through `cash_movements_one_per_finance_entry`, and
      // that index can only compare a value that is actually in the payload.
      final deposit =
          pending
                  .lastWhere((e) => e.entityType == SyncEntities.cashMovement)
                  .payload['cash_movement']
              as Map;
      expect(deposit['source_finance_entry_id'], entry.id);
      final completed =
          pending
                  .lastWhere((e) => e.entityType == SyncEntities.financeEntry)
                  .payload['finance_entry']
              as Map;
      expect(completed['status'], 'COMPLETED');
      expect(completed['completed_at'], isNotNull);

      await finance.deleteCategory(ownerId: 'user-1', categoryId: person.id);
      await finance.permanentlyDeleteCategory(
        ownerId: 'user-1',
        categoryId: person.id,
      );
      final purged = await outbox.pending();
      expect(
        purged.any(
          (e) =>
              e.entityType == SyncEntities.financeCategory &&
              e.operation == SyncOperations.delete,
        ),
        isTrue,
        reason: 'a permanent purge must reach the cloud too',
      );
    });
  });

  group('pull applies master data newest-wins', () {
    late SyncPullApplier applier;
    setUp(() => applier = SyncPullApplier(db));

    test('a name created in the browser lands on the till', () async {
      final report = await applier.apply(pageOf('products', [cloudProduct()]));
      expect(report.products, 1);

      final row = (await db.query(
        'products',
        where: 'id = ?',
        whereArgs: ['prod-1'],
      )).single;
      expect(row['name'], 'Sugar 50kg');
      expect(row['selling_price_minor_units'], 250000);
      // Re-localised: the local convention is naive wall clock, and date
      // filters compare those strings.
      expect('${row['updated_at']}'.contains('+'), isFalse);
      expect('${row['updated_at']}'.endsWith('Z'), isFalse);
    });

    test('a browser rename beats this till\'s older copy', () async {
      await seedLocalProduct(id: 'prod-1', price: 1000, code: 'SGR50');

      final report = await applier.apply(
        pageOf('products', [cloudProduct(name: 'Sugar 25kg', price: 140000)]),
      );
      expect(report.products, 1);

      final row = (await db.query(
        'products',
        where: 'id = ?',
        whereArgs: ['prod-1'],
      )).single;
      expect(row['name'], 'Sugar 25kg');
      expect(row['selling_price_minor_units'], 140000);
    });

    test('an older cloud copy never overwrites a newer local edit', () async {
      await seedLocalProduct(id: 'prod-1', price: 1000);

      final report = await applier.apply(
        pageOf('products', [
          cloudProduct(
            name: 'Stale',
            price: 700,
            updatedAt: '2025-01-01T10:00:00+00:00',
          ),
        ]),
      );
      expect(report.products, 0);

      final row = (await db.query(
        'products',
        where: 'id = ?',
        whereArgs: ['prod-1'],
      )).single;
      expect(row['name'], 'Local name');
      expect(row['selling_price_minor_units'], 1000);
    });

    test('an edit this till has not finished uploading wins', () async {
      await seedLocalProduct(id: 'prod-1', price: 1000);
      await SyncOutbox.upsertRow(
        db,
        entityType: SyncEntities.product,
        entityId: 'prod-1',
        row: {
          'id': 'prod-1',
          'name': 'Being edited',
          'selling_price_minor_units': 999,
        },
      );

      final report = await applier.apply(
        pageOf('products', [cloudProduct(name: 'Concurrent', price: 140000)]),
      );
      expect(report.products, 0);
      final row = (await db.query(
        'products',
        where: 'id = ?',
        whereArgs: ['prod-1'],
      )).single;
      expect(row['name'], 'Local name');
    });

    test('a browser name with no barcode keeps a unique local code', () async {
      await seedLocalProduct(id: 'other', code: 'SGR50');

      // `products.code` is UNIQUE NOT NULL here while the browser leaves it
      // null, and a second null would collide with the first row's own code.
      await applier.apply(
        pageOf('products', [cloudProduct(id: 'prod-9', code: null)]),
      );
      await applier.apply(
        pageOf('products', [cloudProduct(id: 'prod-10', code: 'SGR50')]),
      );

      final codes = (await db.query(
        'products',
        columns: ['code'],
      )).map((r) => r['code']).toList();
      expect(codes.toSet(), hasLength(codes.length));
      final taken = (await db.query(
        'products',
        where: 'id = ?',
        whereArgs: ['prod-10'],
      )).single;
      expect(taken['code'], 'prod-10');
    });

    test('a person and their collection land together', () async {
      final applier = SyncPullApplier(db);
      final persons = await applier.apply(
        pageOf('finance_categories', [cloudPerson()]),
      );
      final report = await applier.apply(
        pageOf('finance_entries', [cloudEntry()]),
      );

      expect(persons.financeCategories, 1);
      expect(report.financeEntries, 1);
      final entry = (await db.query('finance_entries')).single;
      expect(entry['status'], 'PENDING');
      expect(entry['amount_minor_units'], 500000);
      expect('${entry['entry_date']}'.contains('+'), isFalse);

      // Marking it taken on another surface is an UPDATE of the same row.
      final done = await applier.apply(
        pageOf('finance_entries', [
          cloudEntry(
            status: 'COMPLETED',
            completedAt: '2026-10-29T09:00:00+00:00',
            updatedAt: '2026-10-29T09:00:00+00:00',
          ),
        ]),
      );
      expect(done.financeEntries, 1);
      expect((await db.query('finance_entries')).single['status'], 'COMPLETED');
    });

    test(
      'a collection whose person has not arrived yet is skipped, not faked',
      () async {
        final report = await applier.apply(
          pageOf('finance_entries', [cloudEntry(categoryId: 'nobody')]),
        );
        expect(report.financeEntries, 0);
        expect(await db.query('finance_entries'), isEmpty);
        // And it never invented a person in the owner's money list either.
        expect(await db.query('finance_categories'), isEmpty);
      },
    );

    test('the same page replayed writes nothing', () async {
      await applier.apply(pageOf('products', [cloudProduct()]));
      final replay = await applier.apply(pageOf('products', [cloudProduct()]));
      // The update is a no-op on identical values; the row count is the proof.
      expect(
        await db.query('products', where: 'id = ?', whereArgs: ['prod-1']),
        hasLength(1),
      );
      expect(replay.skipped, 0);
    });
  });

  group('account merge', () {
    test('the browser copy of a login is adopted, not added as a second account', () async {
      // The shop was registered on the till AND in the browser, so the same
      // human exists twice under two ids. Inserting the cloud row (a mangled
      // duplicate login) showed the owner two owner accounts and split their
      // history; the login is the identity, so it is merged instead.
      await db.insert('users', {
        'id': 'till-owner',
        'username': '0940634848',
        'password_hash': 'pbkdf2-sha256\$v=1\$i=1000\$localhash',
        'salt': 'localsalt',
        'role': 'OWNER',
        'is_active': 1,
        'permissions': '[]',
        'is_demo': 0,
        'created_at': '2026-01-01T00:00:00.000',
      });

      await SyncPullApplier(db).apply(
        pageOf('users', [
          cloudUserRow(
            id: 'web-owner',
            username: '0940634848',
            role: 'OWNER',
            pwSalt: 'websalt',
            pwHash: 'webhash',
          ),
        ]),
      );

      // Only this login: the harness also holds an unrelated owner row. A
      // second row, or one whose name was mangled with `#`, is the bug.
      final rows = await db.query(
        'users',
        where: "username LIKE '0940634848%'",
      );
      expect(
        rows,
        hasLength(1),
        reason: 'one owner login, not a 0940634848# copy',
      );
      final owner = rows.single;
      expect(owner['id'], 'till-owner', reason: 'the till keeps its own id');
      // What the browser owns follows the browser; what the till owns does not.
      expect(owner['cloud_pw_hash'], 'webhash');
      expect(owner['cloud_pw_salt'], 'websalt');
      expect(owner['password_hash'], 'pbkdf2-sha256\$v=1\$i=1000\$localhash');
      expect(owner['role'], 'OWNER');
    });

    test(
      'a cashier switched off in the browser is switched off here',
      () async {
        await SyncPullApplier(db).apply(
          pageOf('users', [
            cloudUserRow(id: 'user-1', username: '0911111111', active: false),
          ]),
        );
        final row = (await db.query(
          'users',
          where: 'id = ?',
          whereArgs: ['user-1'],
        )).single;
        expect(row['is_active'], 0);
      },
    );
  });

  group('a pulled deposit never pays a collection twice', () {
    test('the cloud copy of a collection this till already paid is skipped', () async {
      // The till wrote its DEPOSIT under its own uuid and the gateway holds the
      // same money under a different one — the browser completed the entry, or
      // `pos_add_cash_movement` minted a fresh id for this push. Ids differ, so
      // the existing-id guard cannot see it; only the entry id says it is one
      // payment. Without the guard the register showed the deposit twice while
      // the browser showed it once.
      await db.insert('cash_movements', {
        'id': 'till-mv',
        'shift_id': 'shift-1',
        'user_id': 'user-1',
        'type': 'DEPOSIT',
        'amount_minor_units': 10000,
        'reason': 'Collected from Alemu',
        'created_at': DateTime.now().toIso8601String(),
        'source_finance_entry_id': 'entry-1',
      });

      final report = await SyncPullApplier(db)
          .apply(pageOf('cash_movements', [cloudMovement(id: 'cloud-mv')]));

      expect(report.cashMovements, 0);
      final rows = await db.query(
        'cash_movements',
        where: 'source_finance_entry_id = ?',
        whereArgs: ['entry-1'],
      );
      expect(rows, hasLength(1), reason: 'one drawer payment per collection');
      expect(
        rows.single['id'],
        'till-mv',
        reason: 'the till keeps its own row',
      );
    });

    test('a collection this till has not paid still lands, with its entry id', () async {
      final report = await SyncPullApplier(db)
          .apply(pageOf('cash_movements', [cloudMovement(id: 'cloud-mv')]));

      expect(report.cashMovements, 1);
      final row = (await db.query(
        'cash_movements',
        where: 'id = ?',
        whereArgs: ['cloud-mv'],
      )).single;
      expect(
        row['source_finance_entry_id'],
        'entry-1',
        reason:
            'the tag has to survive the pull, or the next copy is a duplicate',
      );
    });

    test('a pulled PWA proof photo is stored as a BLOB and read back', () async {
      // A browser-recorded movement with a photo reaches this till over the
      // pull feed (cash_movements select:'*'). It must land in the schema-16
      // BLOB table so getCashMovements hands the ledger a base64 proof again —
      // the PWA-to-app half of bidirectional photo sync.
      final photo = base64Encode(utf8.encode('pwa-jpeg-bytes'));
      await SyncPullApplier(db).apply(
        pageOf('cash_movements', [
          cloudMovement(id: 'pwa-mv', sourceEntry: null, photo: photo),
        ]),
      );

      final blob = (await db.query(
        'cash_movement_photos',
        where: 'movement_id = ?',
        whereArgs: ['pwa-mv'],
      )).single;
      expect(base64Encode(blob['jpeg_bytes'] as List<int>), photo);

      final ledger = await SqfliteShiftRepository(db)
          .getCashMovements(shiftId: 'shift-1');
      expect(
        ledger.firstWhere((m) => m.id == 'pwa-mv').photo,
        photo,
        reason: 'the app shows the photo the browser attached',
      );
    });
  });

  group('pull coverage', () {
    test('every entity the gateway serves is walked, parents first', () {
      expect(
        CloudSyncPuller.tableOrder,
        containsAll(<String>[
          'users',
          'products',
          'shifts',
          'sales',
          'sale_items',
          'cash_movements',
          'void_requests',
          'finance_categories',
          'finance_entries',
        ]),
      );
      expect(
        CloudSyncPuller.tableOrder.indexOf('finance_categories'),
        lessThan(CloudSyncPuller.tableOrder.indexOf('finance_entries')),
        reason: 'a collection names a person: the person has to land first',
      );
      expect(
        CloudSyncPuller.tableOrder.indexOf('users'),
        lessThan(CloudSyncPuller.tableOrder.indexOf('sales')),
      );
    });

    test('a pull of the master-data tables reaches the local schema', () async {
      final backend = _MasterDataBackend();
      final puller = CloudSyncPuller(backend: backend, db: db);
      final report = await puller.pullNow();

      expect(report.products, 1);
      expect(report.financeCategories, 1);
      expect(report.financeEntries, 1);
      expect(
        backend.requested,
        containsAll(<String>[
          'products',
          'finance_categories',
          'finance_entries',
        ]),
      );
    });
  });
}

Map<String, dynamic> cloudUserRow({
  required String id,
  required String username,
  String role = 'CASHIER',
  bool active = true,
  String pwSalt = 'salt',
  String pwHash = 'hash',
}) => {
  'id': id,
  'username': username,
  'role': role,
  'active': active,
  'pw_salt': pwSalt,
  'pw_hash': pwHash,
  'permissions': const ['pos'],
  'is_demo': false,
  'deleted_at': null,
  'created_at': '2026-10-28T08:00:00+00:00',
  'updated_at': '2026-10-28T08:00:00+00:00',
};

/// Serves one page of each master-data table and then nothing, so the puller's
/// table selection (not just its applier) is covered.
class _MasterDataBackend implements SyncBackend {
  final List<String> requested = [];

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
    final table = tables!.single;
    requested.add(table);
    if (cursor != null) return const SyncPullResult.empty();
    final rows = switch (table) {
      'products' => [cloudProduct()],
      'finance_categories' => [cloudPerson()],
      'finance_entries' => [cloudEntry()],
      _ => const <Map<String, dynamic>>[],
    };
    if (rows.isEmpty) return const SyncPullResult.empty();
    return SyncPullResult(
      changes: {table: rows},
      nextCursor: {'received_at': '2026-10-28T10:00:00+00:00', 'id': 'last'},
      hasMore: false,
    );
  }
}
