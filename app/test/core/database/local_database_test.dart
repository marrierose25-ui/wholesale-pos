import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';

void main() {
  test('Database initializes and creates all required tables', () async {
    final db = await LocalDatabase.openInMemory();

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
    );

    final tableNames = tables.map((t) => t['name'] as String).toList();

    expect(tableNames, contains('users'));
    expect(tableNames, contains('products'));
    expect(tableNames, contains('sales'));
    expect(tableNames, contains('sale_items'));
    expect(tableNames, contains('audit_logs'));
    expect(tableNames, contains('devices'));

    await db.close();
  });

  test('Registers and reuses a generated device ID', () async {
    final db = await LocalDatabase.openInMemory();
    final first = await LocalDatabase.registerCurrentDevice(db);
    final second = await LocalDatabase.registerCurrentDevice(db);
    expect(first, isNot('device-1'));
    expect(second, first);
    await db.close();
  });
}
