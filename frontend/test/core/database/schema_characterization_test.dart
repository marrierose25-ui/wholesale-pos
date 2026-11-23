import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show sqfliteFfiInit;
import 'package:pos_local_engine/pos_local_engine.dart';
import 'schema_snapshot.dart';

/// Freezes the schema of a freshly created v22 database and records every
/// difference between it and a database upgraded from a genuine historical
/// fixture.
///
/// The known fresh-vs-upgraded discrepancies here (F-2 and the physical column
/// order left behind by additive `ALTER TABLE`) are *preserved* by Stage 6.0.
/// The golden files make them impossible to change by accident.
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

  test('fresh v22 schema matches its snapshot', () async {
    final db = await LocalDatabase.openAt(
      p.join(tempDir.path, 'fresh.db'),
    );
    try {
      final fresh = await SchemaSnapshot.capture(db);
      expect(fresh['user_version'], 22);
      SchemaSnapshot.expectSnapshot(fresh, 'fresh_v22');

      final tables = (fresh['tables'] as Map).keys.toSet();
      expect(tables, hasLength(18));
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

  test('F-2: only files older than v20 gain the picklist index', () async {
    final freshDb = await LocalDatabase.openAt(
      p.join(tempDir.path, 'fresh_f2.db'),
    );
    final fresh = await SchemaSnapshot.capture(freshDb);
    await freshDb.close();

    expect(
      _indexNames(fresh),
      isNot(contains('picklist_items_picklist_id')),
      reason: 'F-2: this is the preserved fresh-install shape',
    );

    // v19 and older take the `<20` upgrade branch, which creates the index.
    final fromV19 = await _upgrade('v19', tempDir);
    expect(
      _indexNames(fromV19),
      contains('picklist_items_picklist_id'),
    );

    // v20 and v21 were created without the index and their upgrade skips the
    // `<20` branch, so they still lack it at v22. F-2 is wider than "fresh
    // installs only".
    for (final version in <String>['v20', 'v21']) {
      final upgraded = await _upgrade(version, tempDir);
      expect(
        _indexNames(upgraded),
        isNot(contains('picklist_items_picklist_id')),
        reason: 'F-2: a $version database never receives the index',
      );
    }

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

  group('fresh v22 versus upgraded v22', () {
    // v2/v3/v4 cannot reach v22 on this build (see
    // historical_fixture_migration_test.dart and the migration log), so they
    // have no upgraded schema to compare.
    final versions = <int>[12, 19, 20, 21, 22];

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

        if (version >= 20) {
          expect(
            diffs,
            isNot(contains(
              'picklist_items.index.picklist_items_picklist_id: '
              'only in upgraded',
            )),
            reason: 'F-2: v20+ upgrade paths never create the index',
          );
        } else {
          // The v20 upgrade branch adds the F-2 index for older files.
          expect(
            diffs,
            contains(
              'picklist_items.index.picklist_items_picklist_id: '
              'only in upgraded',
            ),
          );
        }
        if (version == 22) {
          expect(
            diffs,
            isEmpty,
            reason: 'a genuine v22 file needs no migration and is a fresh '
                'install',
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
