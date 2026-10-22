import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/finance_repository.dart';
import 'package:wholesale_pos_app/core/models/finance_entry.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late FinanceRepository repository;

  Future<void> insertUser(String id, String role, {int isActive = 1}) async {
    await db.insert('users', {
      'id': id,
      'username': id,
      'password_hash': 'x',
      'salt': 'x',
      'role': role,
      'is_active': isActive,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = FinanceRepository(db);
    await insertUser('owner-1', 'OWNER');
    await insertUser('cashier-1', 'CASHIER');
    await insertUser('former-owner', 'OWNER', isActive: 0);
  });

  tearDown(() async {
    await db.close();
  });

  group('owner-only enforcement', () {
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
}
