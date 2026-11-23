import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

/// Deterministic description of a SQLite schema, used to freeze the shape of
/// both a fresh v22 database and every genuine historical fixture after the
/// real [LocalDatabase] migration has run.
///
/// The capture is deliberately made from SQLite metadata (`sqlite_master`,
/// `PRAGMA table_info`, `PRAGMA foreign_key_list`, `PRAGMA index_list`,
/// `PRAGMA index_info`) rather than from Dart source. That way an accidental
/// change to the DDL, an index, a trigger, a foreign key or even a column
/// order shows up as a snapshot mismatch.
class SchemaSnapshot {
  SchemaSnapshot._();

  /// Directory holding the frozen snapshots, relative to `app/`.
  static const String snapshotDir = 'test/fixtures/database/snapshots';

  /// When true, [expectSnapshot] rewrites the golden file instead of asserting.
  /// Only used by the fixture tooling run (`UPDATE_DB_SCHEMA_SNAPSHOTS=1`).
  static bool get updateMode =>
      Platform.environment['UPDATE_DB_SCHEMA_SNAPSHOTS'] == '1';

  /// Collapse insignificant whitespace and the quoting SQLite adds when a
  /// table is renamed, so a rebuilt table and a freshly created one compare on
  /// their actual definition rather than on `CREATE TABLE "x"` vs
  /// `CREATE TABLE x`.
  static String normalizeSql(String? sql) {
    if (sql == null) return '';
    return sql
        .replaceAll('"', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAllMapped(RegExp(r'\s+([,)])'), (match) => match.group(1)!)
        .replaceAll(RegExp(r'\(\s+'), '(')
        .trim();
  }

  static Future<Map<String, dynamic>> capture(Database db) async {
    final version =
        (await db.rawQuery('PRAGMA user_version')).first.values.first as int;

    final masterRows = await db.rawQuery(
      "SELECT type, name, tbl_name, sql FROM sqlite_master "
      "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
    );

    final tableNames = masterRows
        .where((row) => row['type'] == 'table')
        .map((row) => row['name'] as String)
        .toList()
      ..sort();

    final tables = <String, dynamic>{};
    for (final table in tableNames) {
      final columns = await db.rawQuery('PRAGMA table_info($table)');
      final foreignKeys = await db.rawQuery(
        'PRAGMA foreign_key_list($table)',
      );
      final indexList = await db.rawQuery('PRAGMA index_list($table)');

      final indexes = <Map<String, dynamic>>[];
      final uniqueConstraints = <List<String>>[];
      for (final index in indexList) {
        final name = index['name'] as String;
        final origin = index['origin'] as String? ?? '';
        final cols = await db.rawQuery('PRAGMA index_info($name)');
        final columnNames = cols
            .map((row) => row['name'] as String?)
            .whereType<String>()
            .toList();
        if (origin == 'c') {
          final sqlRow = await db.rawQuery(
            'SELECT sql FROM sqlite_master WHERE type = ? AND name = ?',
            ['index', name],
          );
          indexes.add({
            'name': name,
            'unique': index['unique'] == 1,
            'partial': index['partial'] == 1,
            'columns': columnNames,
            'sql': normalizeSql(
              sqlRow.isEmpty ? null : sqlRow.first['sql'] as String?,
            ),
          });
        } else if (origin == 'u') {
          uniqueConstraints.add(columnNames);
        }
      }
      indexes.sort(
        (a, b) => (a['name'] as String).compareTo(b['name'] as String),
      );
      uniqueConstraints.sort((a, b) => a.join(',').compareTo(b.join(',')));

      final fkRows = foreignKeys
          .map(
            (row) => {
              'id': row['id'],
              'seq': row['seq'],
              'table': row['table'],
              'from': row['from'],
              'to': row['to'],
              'on_update': row['on_update'],
              'on_delete': row['on_delete'],
              'match': row['match'],
            },
          )
          .toList()
        ..sort(
          (a, b) => '${a['id']}:${a['seq']}'.compareTo(
            '${b['id']}:${b['seq']}',
          ),
        );

      final tableRow = masterRows.firstWhere(
        (row) => row['type'] == 'table' && row['name'] == table,
      );

      tables[table] = {
        'sql': normalizeSql(tableRow['sql'] as String?),
        'columns': columns
            .map(
              (row) => {
                'name': row['name'],
                'type': row['type'],
                'not_null': row['notnull'],
                'default': row['dflt_value'],
                'primary_key': row['pk'],
              },
            )
            .toList(),
        'foreign_keys': fkRows,
        'indexes': indexes,
        'unique_constraints': uniqueConstraints,
      };
    }

    final triggers = <String, String>{
      for (final row in masterRows.where((row) => row['type'] == 'trigger'))
        row['name'] as String: normalizeSql(row['sql'] as String?),
    };

    return {
      'user_version': version,
      'tables': tables,
      'triggers': triggers,
    };
  }

  /// Compare [actual] against `snapshots/<name>.json` and fail with a readable
  /// diff when they differ.
  static void expectSnapshot(Map<String, dynamic> actual, String name) {
    final file = File('$snapshotDir/$name.json');
    final encoded = const JsonEncoder.withIndent('  ').convert(actual);
    if (updateMode) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$encoded\n');
      return;
    }
    if (!file.existsSync()) {
      fail(
        'Missing schema snapshot ${file.path}. '
        'Run with UPDATE_DB_SCHEMA_SNAPSHOTS=1 to create it.',
      );
    }
    final expected = jsonDecode(file.readAsStringSync());
    expect(
      actual,
      equals(expected),
      reason:
          'Schema snapshot "$name" changed. If (and only if) this is an '
          'intentional, approved schema change, regenerate the snapshot with '
          'UPDATE_DB_SCHEMA_SNAPSHOTS=1. A Stage 6.0 characterization run must '
          'never need to update this file.',
    );
  }

  /// Canonical list of differences between a fresh v22 schema and one that was
  /// upgraded to v22 from a historical fixture.
  ///
  /// Kept as strings so the golden file is reviewable in a diff.
  static List<String> differences(
    Map<String, dynamic> fresh,
    Map<String, dynamic> upgraded,
  ) {
    final diffs = <String>[];

    final freshTables = (fresh['tables'] as Map).cast<String, dynamic>();
    final upgradedTables = (upgraded['tables'] as Map)
        .cast<String, dynamic>();
    final tableNames = <String>{...freshTables.keys, ...upgradedTables.keys}
        .toList()
      ..sort();

    for (final table in tableNames) {
      final a = freshTables[table] as Map<String, dynamic>?;
      final b = upgradedTables[table] as Map<String, dynamic>?;
      if (a == null) {
        diffs.add('$table: table only in upgraded');
        continue;
      }
      if (b == null) {
        diffs.add('$table: table only in fresh');
        continue;
      }

      if (a['sql'] != b['sql']) {
        diffs.add('$table.sql: fresh=${a['sql']} upgraded=${b['sql']}');
      }

      final aCols = (a['columns'] as List).cast<Map<String, dynamic>>();
      final bCols = (b['columns'] as List).cast<Map<String, dynamic>>();
      final aNames = aCols.map((c) => c['name'] as String).toList();
      final bNames = bCols.map((c) => c['name'] as String).toList();
      if (aNames.join(',') != bNames.join(',')) {
        diffs.add(
          '$table.columns: fresh=[${aNames.join(', ')}] '
          'upgraded=[${bNames.join(', ')}]',
        );
      } else {
        for (var i = 0; i < aCols.length; i++) {
          if (jsonEncode(aCols[i]) != jsonEncode(bCols[i])) {
            diffs.add(
              '$table.column.${aNames[i]}: fresh=${aCols[i]} '
              'upgraded=${bCols[i]}',
            );
          }
        }
      }

      final aFks = jsonEncode(a['foreign_keys']);
      final bFks = jsonEncode(b['foreign_keys']);
      if (aFks != bFks) {
        diffs.add('$table.foreign_keys: fresh=$aFks upgraded=$bFks');
      }

      final aIndexes = (a['indexes'] as List).cast<Map<String, dynamic>>();
      final bIndexes = (b['indexes'] as List).cast<Map<String, dynamic>>();
      final aIndexByName = {
        for (final index in aIndexes) index['name'] as String: index,
      };
      final bIndexByName = {
        for (final index in bIndexes) index['name'] as String: index,
      };
      final indexNames = <String>{
        ...aIndexByName.keys,
        ...bIndexByName.keys,
      }.toList()
        ..sort();
      for (final name in indexNames) {
        final x = aIndexByName[name];
        final y = bIndexByName[name];
        if (y == null) {
          diffs.add('$table.index.$name: only in fresh');
        } else if (x == null) {
          diffs.add('$table.index.$name: only in upgraded');
        } else if (jsonEncode(x) != jsonEncode(y)) {
          diffs.add(
            '$table.index.$name: fresh=$x upgraded=$y',
          );
        }
      }

      final aUnique = jsonEncode(a['unique_constraints']);
      final bUnique = jsonEncode(b['unique_constraints']);
      if (aUnique != bUnique) {
        diffs.add(
          '$table.unique_constraints: fresh=$aUnique upgraded=$bUnique',
        );
      }
    }

    final freshTriggers = (fresh['triggers'] as Map).cast<String, dynamic>();
    final upgradedTriggers = (upgraded['triggers'] as Map)
        .cast<String, dynamic>();
    final triggerNames = <String>{
      ...freshTriggers.keys,
      ...upgradedTriggers.keys,
    }.toList()
      ..sort();
    for (final name in triggerNames) {
      if (freshTriggers[name] != upgradedTriggers[name]) {
        diffs.add(
          'trigger.$name: fresh=${freshTriggers[name]} '
          'upgraded=${upgradedTriggers[name]}',
        );
      }
    }

    diffs.sort();
    return diffs;
  }

  static void expectDifferenceSnapshot(
    List<String> actual,
    String name,
  ) {
    final file = File('$snapshotDir/$name.json');
    final encoded = const JsonEncoder.withIndent('  ').convert(actual);
    if (updateMode) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$encoded\n');
      return;
    }
    if (!file.existsSync()) {
      fail(
        'Missing difference snapshot ${file.path}. '
        'Run with UPDATE_DB_SCHEMA_SNAPSHOTS=1 to create it.',
      );
    }
    expect(
      actual,
      equals(jsonDecode(file.readAsStringSync())),
      reason:
          'The fresh-vs-upgraded schema differences changed. Stage 6.0 '
          'preserves the known F-2 discrepancy on purpose; changing this '
          'golden file requires an approved architectural stage.',
    );
  }
}
