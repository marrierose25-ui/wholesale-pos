import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/local_database.dart';

class DataExporter {
  static Future<String> exportToJson(
    Database db, {
    required String requestingUserId,
  }) async {
    final user = await db.query(
      'users',
      columns: ['role', 'is_active'],
      where: 'id = ?',
      whereArgs: [requestingUserId],
      limit: 1,
    );
    if (user.isEmpty ||
        user.first['role'] != 'OWNER' ||
        user.first['is_active'] != 1) {
      throw Exception('Only an active owner can export data.');
    }

    final users = await db.query('users');
    final products = await db.query('products');
    final sales = await db.query('sales');
    final saleItems = await db.query('sale_items');
    final voidRequests = await db.query('void_requests');
    final shifts = await db.query('shifts');
    final cashMovements = await db.query('cash_movements');
    final auditLogs = await db.query('audit_logs');
    final devices = await db.query('devices');
    final counters = await db.query('counters');
    final settings = await db.query('settings');
    final financeCategories = await db.query('finance_categories');
    final financeEntries = await db.query('finance_entries');

    final exportData = {
      'exported_at': DateTime.now().toIso8601String(),
      'version': LocalDatabase.schemaVersion,
      'users': users,
      'products': products,
      'sales': sales,
      'sale_items': saleItems,
      'void_requests': voidRequests,
      'shifts': shifts,
      'cash_movements': cashMovements,
      'audit_logs': auditLogs,
      'devices': devices,
      'counters': counters,
      'settings': settings,
      'finance_categories': financeCategories,
      'finance_entries': financeEntries,
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

    await db.insert('audit_logs', {
      'id': const Uuid().v4(),
      'user_id': requestingUserId,
      'action': 'BACKUP_EXPORTED',
      'details': 'Backup written to $filePath',
      'created_at': DateTime.now().toIso8601String(),
    });

    return filePath;
  }
}
