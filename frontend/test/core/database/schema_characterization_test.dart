import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show sqfliteFfiInit;
import 'package:pos_local_engine/pos_local_engine.dart';
import 'schema_snapshot.dart';

/// Freezes the schema of a freshly created database and records every
/// difference between it and a database upgraded from a genuine historical
/// fixture.
///
/// Stage 0 closed finding F-2: `picklist_items_picklist_id` now exists on
/// every path (fresh `_onCreate`, the `<20` upgrade branch and the v23
/// convergence migration). The remaining fresh-vs-upgraded differences are
/// the physical column order and `sqlite_master.sql` text left behind by
/// additive `ALTER TABLE` — cosmetic artefacts the golden files freeze so
/// they cannot change by accident.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('stage60_schema_');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows can hold the SQLite handle for a moment.
    }
  });

  test('fresh schema matches its snapshot', () async {
    final db = await LocalDatabase.openAt(
      p.join(tempDir.path, 'fresh.db'),
    );
    try {
      final fresh = await SchemaSnapshot.capture(db);
      expect(fresh['user_version'], LocalDatabase.schemaVersion);
      SchemaSnapshot.expectSnapshot(
        fresh,
        'fresh_v${LocalDatabase.schemaVersion}',
      );

      final tables = (fresh['tables'] as Map).keys.toSet();
      expect(tables, hasLength(20));
      expect(
        tables,
        containsAll([
          'users',
          'products',
          'devices',
          'shifts',
          'cash_movements',
          'cash_movement_photos',
          'sales',
          'sale_items',
          'finance_categories',
          'finance_entries',
          'void_requests',
          'picklists',
          'picklist_items',
          'picklist_customers',
          'stores',
          'store_inventory',
          'audit_logs',
          'counters',
          'settings',
          'sync_outbox',
        ]),
      );
    } finally {
      await db.close();
    }
  });

  test('picklist_items_picklist_id exists on every install path', () async {
    final freshDb = await LocalDatabase.openAt(
      p.join(tempDir.path, 'fresh_f2.db'),
    );
    final fresh = await SchemaSnapshot.capture(freshDb);
    await freshDb.close();

    // Stage 0 closed F-2: a fresh install now creates the index.
    expect(_indexNames(fresh), contains('picklist_items_picklist_id'));

    // And so does every historical upgrade path, including the v20/v21/v22
    // files that previously never received it.
    for (final version in <String>[
      'v2', 'v3', 'v4', 'v5', 'v12', 'v19', 'v20', 'v21', 'v22',
    ]) {
      final upgraded = await _upgrade(version, tempDir);
      expect(
        _indexNames(upgraded),
        contains('picklist_items_picklist_id'),
        reason: '$version must converge on the picklist index',
      );
    }

    final fromV19 = await _upgrade('v19', tempDir);
    final upgradedTable =
        (fromV19['tables'] as Map)['picklist_items'] as Map<String, dynamic>;
    final upgradedIndex = (upgradedTable['indexes'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere(
          (index) => index['name'] == 'picklist_items_picklist_id',
        );
    expect(upgradedIndex['columns'], ['picklist_id']);
    expect(upgradedIndex['unique'], isFalse);
    expect(upgradedIndex['partial'], isFalse);
  });

  group('fresh versus upgraded schema', () {
    final versions = <int>[2, 3, 4, 5, 12, 19, 20, 21, 22];

    for (final version in versions) {
      test('differences from v$version are frozen', () async {
        final freshDb = await LocalDatabase.openAt(
          p.join(tempDir.path, 'fresh_v$version.db'),
        );
        final fresh = await SchemaSnapshot.capture(freshDb);
        await freshDb.close();

        final upgraded = await _upgrade('v$version', tempDir);

        final diffs = SchemaSnapshot.differences(fresh, upgraded);
        SchemaSnapshot.expectDifferenceSnapshot(
          diffs,
          'fresh_vs_upgraded_v$version',
        );

        // Stage 0: the picklist index now exists on both sides for every
        // version, so it can never appear in the diff list.
        expect(
          diffs,
          isNot(contains(
            'picklist_items.index.picklist_items_picklist_id: '
            'only in upgraded',
          )),
        );
        expect(
          diffs,
          isNot(contains(
            'picklist_items.index.picklist_items_picklist_id: '
            'only in fresh',
          )),
        );
        if (version == 22) {
          expect(
            diffs,
            isEmpty,
            reason: 'a genuine v22 file upgrades cleanly to the current '
                'schema, which is a fresh install',
          );
        }
      });
    }
  });
}

Future<Map<String, dynamic>> _upgrade(
  String version,
  Directory tempDir,
) async {
  final copy = File(p.join(tempDir.path, 'upgrade_from_$version.db'));
  await File(
    'test/fixtures/database/$version/wholesale_pos.db',
  ).copy(copy.path);
  final db = await LocalDatabase.openAt(copy.path);
  try {
    return await SchemaSnapshot.capture(db);
  } finally {
    await db.close();
  }
}

Set<String> _indexNames(Map<String, dynamic> snapshot) {
  final names = <String>{};
  final tables = (snapshot['tables'] as Map).cast<String, dynamic>();
  for (final table in tables.values) {
    for (final index in (table as Map)['indexes'] as List) {
      names.add((index as Map)['name'] as String);
    }
  }
  return names;
}
