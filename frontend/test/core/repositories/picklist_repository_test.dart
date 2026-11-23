import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_core/pos_core.dart';

// Soft-delete + edit behaviour of the Warehouse picklist store. A delete must
// never physically remove a row: it writes a tombstone that syncs to every
// device, and every read filters it out.
void main() {
  late Database db;
  late SqflitePicklistRepository repository;

  final now = DateTime(2026, 11, 11, 10);

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = SqflitePicklistRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Picklist header({String status = Picklist.statusPending, String id = 'p1'}) =>
      Picklist(
        id: id,
        customerName: 'Aymen',
        status: status,
        createdBy: 'u1',
        createdAt: now,
        updatedAt: now,
      );

  PicklistItem item({
    String id = 'i1',
    String product = 'Sugar',
    int requested = 5,
    int taken = 0,
    int price = 4550,
  }) => PicklistItem(
    id: id,
    picklistId: 'p1',
    productName: product,
    requestedQty: requested,
    takenQty: taken,
    unit: 'Karton',
    unitPriceMinorUnits: price,
    lineTotalMinorUnits: price * requested,
    updatedAt: now,
  );

  Future<List<Map<String, Object?>>> outbox(String entityType) async {
    final rows = await db.query(
      'sync_outbox',
      where: 'entity_type = ?',
      whereArgs: [entityType],
    );
    return rows;
  }

  test(
    'editing a line recomputes its total and re-derives the status',
    () async {
      await repository.createPicklist(header(), [
        item(id: 'i1'),
        item(id: 'i2', product: 'Flour', requested: 2, taken: 2),
      ]);

      await repository.updatePicklistItem(
        item(id: 'i1', product: 'Salt', requested: 3, price: 1000),
      );

      final lines = await repository.getItems('p1');
      final salt = lines.firstWhere((line) => line.id == 'i1');
      expect(salt.productName, 'Salt');
      expect(salt.requestedQty, 3);
      expect(salt.unitPriceMinorUnits, 1000);
      expect(salt.lineTotalMinorUnits, 3000);

      final list = (await repository.getPicklists()).single;
      expect(list.status, Picklist.statusPartial);
    },
  );

  test('lowering the requested quantity clamps taken progress and re-derives status', () async {
    await repository.createPicklist(header(), [item(requested: 5, taken: 3)]);

    await repository.updatePicklistItem(
      item(requested: 2, taken: 3, price: 4550),
    );

    final line = (await repository.getItems('p1')).single;
    expect(line.requestedQty, 2);
    // The warehouse had taken 3 of 5; after the correction only 2 were ever
    // requested, so the stored progress is clamped instead of exceeding it.
    expect(line.takenQty, 2);
    expect(line.isFulfilled, isTrue);
    expect(line.lineTotalMinorUnits, 4550 * 2);

    final list = (await repository.getPicklists()).single;
    expect(list.status, Picklist.statusCompleted);
  });

  test('an edit whose line total cannot be represented is rejected', () async {
    await repository.createPicklist(header(), [item()]);

    await expectLater(
      repository.updatePicklistItem(
        // 2,000,000,000 x 2 is above the cloud's 32-bit money column.
        item(requested: 2, price: 2000000000),
      ),
      throwsA(isA<Exception>()),
    );

    final line = (await repository.getItems('p1')).single;
    expect(line.productName, 'Sugar');
    expect(line.requestedQty, 5);
    expect(line.unitPriceMinorUnits, 4550);
  });

  test(
    'creating a list recomputes the total and clamps taken progress',
    () async {
      await repository.createPicklist(header(), [
        PicklistItem(
          id: 'i1',
          picklistId: 'p1',
          productName: '  Sugar  ',
          requestedQty: 5,
          takenQty: 9,
          unit: 'Karton',
          unitPriceMinorUnits: 4550,
          lineTotalMinorUnits: 1,
          updatedAt: now,
        ),
      ]);

      final line = (await repository.getItems('p1')).single;
      expect(line.productName, 'Sugar');
      expect(line.takenQty, 5);
      expect(line.lineTotalMinorUnits, 4550 * 5);
    },
  );

  test('deleting the last active line also tombstones the header', () async {
    await repository.createPicklist(header(), [item()]);

    await repository.deletePicklistItem('p1', 'i1');

    expect(await repository.getItems('p1'), isEmpty);
    expect(await repository.getPicklists(), isEmpty);
    final rows = await db.query('picklists');
    expect(rows.single['deleted_at'], isNotNull);

    // The tombstone travels as an UPSERT, not a DELETE (the cloud refuses a
    // device DELETE), and its payload carries the timestamp.
    final payloads = (await outbox('picklist_item'))
        .map((row) => jsonDecode(row['payload'] as String) as Map)
        .toList();
    final deleted = payloads.last['picklist_item'] as Map;
    expect(deleted['deleted_at'], isNotNull);
  });

  test('deleting a whole list hides the header and every line', () async {
    await repository.createPicklist(header(), [
      item(id: 'i1'),
      item(id: 'i2', product: 'Flour'),
    ]);

    await repository.deletePicklist('p1');

    expect(await repository.getPicklists(), isEmpty);
    expect(await repository.getItems('p1'), isEmpty);
    final lines = await db.query('picklist_items');
    expect(lines, hasLength(2));
    expect(lines.every((row) => row['deleted_at'] != null), isTrue);
  });

  test('a completed list stays frozen for edit and delete', () async {
    await repository.createPicklist(header(status: Picklist.statusCompleted), [
      item(taken: 5),
    ]);

    await expectLater(
      repository.updatePicklistItem(item(product: 'Salt')),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      repository.deletePicklistItem('p1', 'i1'),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      repository.deletePicklist('p1'),
      throwsA(isA<Exception>()),
    );
    expect(await repository.getPicklists(), hasLength(1));
    expect(await repository.getItems('p1'), hasLength(1));
  });
}
