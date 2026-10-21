import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DataExporter {
  static Future<String> exportToJson(Database db) async {
    final users = await db.query('users');
    final products = await db.query('products');
    final sales = await db.query('sales');
    final saleItems = await db.query('sale_items');
    final shifts = await db.query('shifts');
    final cashMovements = await db.query('cash_movements');
    final auditLogs = await db.query('audit_logs');

    final exportData = {
      'exported_at': DateTime.now().toIso8601String(),
      'version': 4,
      'users': users,
      'products': products,
      'sales': sales,
      'sale_items': saleItems,
      'shifts': shifts,
      'cash_movements': cashMovements,
      'audit_logs': auditLogs,
    };

    final jsonString = const JsonEncoder.withIndent('  ').convert(exportData);

    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')[0];
    final filePath = p.join(
      directory.path,
      'wholesale_pos_backup_$timestamp.json',
    );

    final file = File(filePath);
    await file.writeAsString(jsonString);

    return filePath;
  }
}
