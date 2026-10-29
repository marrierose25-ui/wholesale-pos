import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/finance_repository.dart';
import 'package:wholesale_pos_app/core/models/finance_entry.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late FinanceRepository repository;

  Future<void> insertUser(
    String id,
    String role, {
    int isActive = 1,
    List<String> permissions = const [],
  }) async {
    await db.insert('users', {
      'id': id,
      'username': id,
      'password_hash': 'x',
      'salt': 'x',
      'role': role,
      'is_active': isActive,
      'permissions': jsonEncode(permissions),
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = FinanceRepository(db);
    await insertUser('owner-1', 'OWNER');
    await insertUser('cashier-1', 'CASHIER');
    await insertUser('trusted-1', 'CASHIER', permissions: ['pos', 'finance']);
    await insertUser('former-owner', 'OWNER', isActive: 0);
  });

  tearDown(() async {
    await db.close();
  });

  group('access is a tick, not a role', () {
    test('a cashier is rejected by every finance method', () async {
      await expectLater(repository.getCategories('cashier-1'), throwsException);
      await expectLater(
        repository.getCategorySummaries('cashier-1'),
        throwsException,
      );
      await expectLater(
        repository.createCategory(ownerId: 'cashier-1', name: 'Bob'),
        throwsException,
      );
      await expectLater(
        repository.renameCategory(
          ownerId: 'cashier-1',
          categoryId: 'anything',
          newName: 'X',
        ),
        throwsException,
      );
      await expectLater(
        repository.addEntry(
          ownerId: 'cashier-1',
          categoryId: 'anything',
          source: 'Bank',
          amountMinorUnits: 100,
        ),
        throwsException,
      );
      await expectLater(
        repository.updateEntry(
          ownerId: 'cashier-1',
          entryId: 'anything',
          source: 'Bank',
          amountMinorUnits: 100,
        ),
        throwsException,
      );
      await expectLater(
        repository.markCompleted(ownerId: 'cashier-1', entryId: 'anything'),
        throwsException,
      );
      await expectLater(
        repository.searchEntries(ownerId: 'cashier-1'),
        throwsException,
      );
      await expectLater(
        repository.getPersonTotals('cashier-1', 'anything'),
        throwsException,
      );

      // Nothing was written by the denied attempts.
      expect(await db.query('finance_categories'), isEmpty);
      expect(await db.query('finance_entries'), isEmpty);
    });

    test('a deactivated owner is rejected', () async {
      await expectLater(
        repository.getCategories('former-owner'),
        throwsException,
      );
    });

    test('a cashier ticked for Money Tracking keeps the whole area', () async {
      final person = await repository.createCategory(
        ownerId: 'trusted-1',
        name: 'Alem',
      );
      await repository.addEntry(
        ownerId: 'trusted-1',
        categoryId: person.id,
        source: 'Shop rent',
        amountMinorUnits: 5000,
      );

      expect((await repository.getCategories('trusted-1')).single.name, 'Alem');
      expect(
        await repository.searchEntries(ownerId: 'trusted-1'),
        hasLength(1),
      );
      expect(await repository.getCategorySummaries('trusted-1'), hasLength(1));
      // The actor is the ticked account, not the owner: the audit trail must
      // name whoever actually touched the money.
      final logs = await db.query('audit_logs', orderBy: 'created_at');
      expect(logs.map((r) => r['user_id']).toSet(), {'trusted-1'});
    });

    test('removing the tick closes the area again, even mid-session', () async {
      await repository.createCategory(ownerId: 'trusted-1', name: 'Alem');
      await db.update(
        'users',
        {
          'permissions': jsonEncode(['pos']),
        },
        where: 'id = ?',
        whereArgs: ['trusted-1'],
      );
      await expectLater(repository.getCategories('trusted-1'), throwsException);
    });
  });

  group('people (categories)', () {
    test('creates and lists people; duplicate names are rejected', () async {
      await repository.createCategory(ownerId: 'owner-1', name: 'Alem');
      await repository.createCategory(ownerId: 'owner-1', name: 'Hanna');

      final people = await repository.getCategories('owner-1');
      expect(people.map((p) => p.name), ['Alem', 'Hanna']);

      await expectLater(
        repository.createCategory(ownerId: 'owner-1', name: ' alem '),
        throwsException,
      );
    });

    test('renaming keeps all entries attached to the person', () async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      await repository.addEntry(
        ownerId: 'owner-1',
        categoryId: category.id,
        source: 'CBE Birr',
        amountMinorUnits: 500000,
      );

      await repository.renameCategory(
        ownerId: 'owner-1',
        categoryId: category.id,
        newName: 'Alem Tadesse',
      );

      final entries = await repository.searchEntries(ownerId: 'owner-1');
      expect(entries.length, 1);
      expect(entries.first.categoryName, 'Alem Tadesse');
    });

    test('empty names are rejected', () async {
      await expectLater(
        repository.createCategory(ownerId: 'owner-1', name: '   '),
        throwsException,
      );
    });
  });

  group('entry lifecycle', () {
    test('pending entry becomes completed and stays in history', () async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      final entry = await repository.addEntry(
        ownerId: 'owner-1',
        categoryId: category.id,
        source: 'Dashen Bank',
        amountMinorUnits: 100000,
        description: 'monthly withdrawal',
      );
      expect(entry.status, FinanceEntry.statusPending);

      var pending = await repository.searchEntries(
        ownerId: 'owner-1',
        status: FinanceEntry.statusPending,
      );
      expect(pending.length, 1);

      await repository.markCompleted(ownerId: 'owner-1', entryId: entry.id);

      // Gone from pending...
      pending = await repository.searchEntries(
        ownerId: 'owner-1',
        status: FinanceEntry.statusPending,
      );
      expect(pending, isEmpty);

      // ...but still present in history, searchable, with a completion stamp.
      final completed = await repository.searchEntries(
        ownerId: 'owner-1',
        status: FinanceEntry.statusCompleted,
      );
      expect(completed.length, 1);
      expect(completed.first.completedAt, isNotNull);
      expect(completed.first.completedBy, 'owner-1');

      final all = await repository.searchEntries(ownerId: 'owner-1');
      expect(all.length, 1);
    });

    test('completed entries are immutable', () async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      final entry = await repository.addEntry(
        ownerId: 'owner-1',
        categoryId: category.id,
        source: 'Bank',
        amountMinorUnits: 100000,
      );
      await repository.markCompleted(ownerId: 'owner-1', entryId: entry.id);

      await expectLater(
        repository.updateEntry(
          ownerId: 'owner-1',
          entryId: entry.id,
          source: 'Changed',
          amountMinorUnits: 999,
        ),
        throwsException,
      );
      await expectLater(
        repository.markCompleted(ownerId: 'owner-1', entryId: entry.id),
        throwsException,
      );
    });

    test('pending entries can be edited', () async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      final entry = await repository.addEntry(
        ownerId: 'owner-1',
        categoryId: category.id,
        source: 'Bank',
        amountMinorUnits: 100000,
      );
      await repository.updateEntry(
        ownerId: 'owner-1',
        entryId: entry.id,
        source: 'Liberty Bank',
        amountMinorUnits: 150000,
      );

      final entries = await repository.searchEntries(ownerId: 'owner-1');
      expect(entries.single.source, 'Liberty Bank');
      expect(entries.single.amountMinorUnits, 150000);
    });

    test('amounts must be positive and a source is required', () async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      await expectLater(
        repository.addEntry(
          ownerId: 'owner-1',
          categoryId: category.id,
          source: 'Bank',
          amountMinorUnits: 0,
        ),
        throwsException,
      );
      await expectLater(
        repository.addEntry(
          ownerId: 'owner-1',
          categoryId: category.id,
          source: '  ',
          amountMinorUnits: 100,
        ),
        throwsException,
      );
    });
  });

  group('search and totals', () {
    late String categoryId;

    setUp(() async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      categoryId = category.id;
      await repository.addEntry(
        ownerId: 'owner-1',
        categoryId: categoryId,
        source: 'CBE Birr app',
        amountMinorUnits: 500000,
        description: 'rent money',
      );
      await repository.addEntry(
        ownerId: 'owner-1',
        categoryId: categoryId,
        source: 'Abysseum branch',
        amountMinorUnits: 250000,
      );
    });

    test('matches source, description, and person name', () async {
      expect(
        await repository.searchEntries(
          ownerId: 'owner-1',
          searchQuery: 'abysseum',
        ),
        hasLength(1),
      );
      expect(
        await repository.searchEntries(ownerId: 'owner-1', searchQuery: 'rent'),
        hasLength(1),
      );
      expect(
        await repository.searchEntries(ownerId: 'owner-1', searchQuery: 'alem'),
        hasLength(2),
      );
    });

    test('wildcards in the query match literally', () async {
      expect(
        await repository.searchEntries(ownerId: 'owner-1', searchQuery: '%'),
        isEmpty,
      );
    });

    test('person totals separate pending from completed', () async {
      final entries = await repository.searchEntries(
        ownerId: 'owner-1',
        status: FinanceEntry.statusPending,
      );
      // Complete the 500000 entry specifically so the totals are deterministic.
      final target = entries.firstWhere((e) => e.amountMinorUnits == 500000);
      await repository.markCompleted(ownerId: 'owner-1', entryId: target.id);

      final totals = await repository.getPersonTotals('owner-1', categoryId);
      expect(totals['pending_total'], 250000);
      expect(totals['completed_total'], 500000);

      final summaries = await repository.getCategorySummaries('owner-1');
      expect(summaries.single['pending_count'], 1);
      expect(summaries.single['pending_total'], 250000);
    });

    test('every mutation is written to the audit log', () async {
      final logs = await db.query(
        'audit_logs',
        where: "action LIKE 'FINANCE%'",
      );
      expect(logs.length, 3); // 1 category + 2 entries
    });
  });

  group('recycle bin (soft delete)', () {
    test('a binned person and their entries leave the active area', () async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      await repository.addEntry(
        ownerId: 'owner-1',
        categoryId: category.id,
        source: 'Bank',
        amountMinorUnits: 100000,
      );
      expect(await repository.getCategories('owner-1'), hasLength(1));

      await repository.deleteCategory(
        ownerId: 'owner-1',
        categoryId: category.id,
      );

      // Gone from every active view...
      expect(await repository.getCategories('owner-1'), isEmpty);
      expect(await repository.searchEntries(ownerId: 'owner-1'), isEmpty);
      expect(await repository.getCategorySummaries('owner-1'), isEmpty);
      final totals = await repository.getPersonTotals('owner-1', category.id);
      expect(totals['pending_total'], 0);

      // ...but the rows are kept and listed in the bin.
      expect(
        await db.query(
          'finance_categories',
          where: 'id = ?',
          whereArgs: [category.id],
        ),
        hasLength(1),
      );
      final binned = await repository.getDeletedCategories('owner-1');
      expect(binned.map((c) => c.name), ['Alem']);
      expect(binned.single.deletedAt, isNotNull);
    });

    test('restore brings a binned person back to the active area', () async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      await repository.deleteCategory(
        ownerId: 'owner-1',
        categoryId: category.id,
      );

      await repository.restoreCategory(
        ownerId: 'owner-1',
        categoryId: category.id,
      );

      expect((await repository.getCategories('owner-1')).map((c) => c.name), [
        'Alem',
      ]);
      expect(await repository.getDeletedCategories('owner-1'), isEmpty);
    });

    test('permanent delete removes the person and their entries', () async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      await repository.addEntry(
        ownerId: 'owner-1',
        categoryId: category.id,
        source: 'Bank',
        amountMinorUnits: 100000,
      );

      // Only people already in the bin can be purged.
      await expectLater(
        repository.permanentlyDeleteCategory(
          ownerId: 'owner-1',
          categoryId: category.id,
        ),
        throwsException,
      );

      await repository.deleteCategory(
        ownerId: 'owner-1',
        categoryId: category.id,
      );
      await repository.permanentlyDeleteCategory(
        ownerId: 'owner-1',
        categoryId: category.id,
      );

      expect(
        await db.query(
          'finance_categories',
          where: 'id = ?',
          whereArgs: [category.id],
        ),
        isEmpty,
      );
      expect(
        await db.query(
          'finance_entries',
          where: 'category_id = ?',
          whereArgs: [category.id],
        ),
        isEmpty,
      );
    });

    test('double-delete and restore-active are rejected', () async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      await repository.deleteCategory(
        ownerId: 'owner-1',
        categoryId: category.id,
      );
      await expectLater(
        repository.deleteCategory(ownerId: 'owner-1', categoryId: category.id),
        throwsException,
      );
      await expectLater(
        repository.restoreCategory(
          ownerId: 'owner-1',
          categoryId: (await repository.createCategory(
            ownerId: 'owner-1',
            name: 'Hanna',
          )).id,
        ),
        throwsException,
      );
    });
  });

  group('payment method', () {
    test(
      'round-trips and normalizes to upper-case; unset stays null',
      () async {
        final category = await repository.createCategory(
          ownerId: 'owner-1',
          name: 'Alem',
        );
        final cash = await repository.addEntry(
          ownerId: 'owner-1',
          categoryId: category.id,
          source: 'CBE',
          amountMinorUnits: 100000,
          paymentMethod: 'cash',
        );
        expect(cash.paymentMethod, 'CASH');
        final stored = await db.query(
          'finance_entries',
          where: 'id = ?',
          whereArgs: [cash.id],
        );
        expect(stored.single['payment_method'], 'CASH');

        final neutral = await repository.addEntry(
          ownerId: 'owner-1',
          categoryId: category.id,
          source: 'Wire',
          amountMinorUnits: 50000,
        );
        expect(neutral.paymentMethod, isNull);
      },
    );

    test('an unknown payment method is rejected', () async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      await expectLater(
        repository.addEntry(
          ownerId: 'owner-1',
          categoryId: category.id,
          source: 'Crypto',
          amountMinorUnits: 1000,
          paymentMethod: 'crypto',
        ),
        throwsException,
      );
    });
  });

  group('cash collections deposit into the register', () {
    test('completing a CASH entry inserts a register DEPOSIT', () async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      final entry = await repository.addEntry(
        ownerId: 'owner-1',
        categoryId: category.id,
        source: 'Cash at door',
        amountMinorUnits: 250000,
        paymentMethod: 'CASH',
      );

      await repository.markCompleted(ownerId: 'owner-1', entryId: entry.id);

      final deposits = await db.query(
        'cash_movements',
        where: "type = 'DEPOSIT'",
      );
      expect(deposits, hasLength(1));
      expect(deposits.single['amount_minor_units'], 250000);
      expect(deposits.single['user_id'], 'owner-1');
      expect(deposits.single['reason'], contains('Alem'));

      // A perpetual OPEN shift exists to receive the deposit.
      final shifts = await db.query('shifts', where: "status = 'OPEN'");
      expect(shifts, hasLength(1));
      expect(deposits.single['shift_id'], shifts.single['id']);
    });

    test('a BANK collection never touches the drawer', () async {
      final category = await repository.createCategory(
        ownerId: 'owner-1',
        name: 'Alem',
      );
      final entry = await repository.addEntry(
        ownerId: 'owner-1',
        categoryId: category.id,
        source: 'CBE transfer',
        amountMinorUnits: 250000,
        paymentMethod: 'BANK',
      );

      await repository.markCompleted(ownerId: 'owner-1', entryId: entry.id);

      expect(await db.query('cash_movements'), isEmpty);
      expect(await db.query('shifts'), isEmpty);
    });

    test(
      'a collection with no payment method does not touch the drawer',
      () async {
        final category = await repository.createCategory(
          ownerId: 'owner-1',
          name: 'Alem',
        );
        final entry = await repository.addEntry(
          ownerId: 'owner-1',
          categoryId: category.id,
          source: 'Unspecified',
          amountMinorUnits: 250000,
        );

        await repository.markCompleted(ownerId: 'owner-1', entryId: entry.id);

        expect(await db.query('cash_movements'), isEmpty);
      },
    );
  });
}
