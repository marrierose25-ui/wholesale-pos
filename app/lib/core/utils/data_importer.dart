import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DataImporter {
  static Future<void> importFromJson(Database db, String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) throw Exception('Backup file not found.');

    final jsonString = await file.readAsString();
    final Map<String, dynamic> data = jsonDecode(jsonString);

    if (!data.containsKey('version') || data['version'] < 4) {
      throw Exception(
        'Incompatible backup version. Please use a newer backup.',
      );
    }

    await db.transaction((txn) async {
      // Clear existing data
      await txn.delete('audit_logs');
      await txn.delete('cash_movements');
      await txn.delete('sale_items');
      await txn.delete('sales');
      await txn.delete('shifts');
      await txn.delete('products');
      await txn.delete('users');

      // Insert new data
      for (var row in (data['users'] as List)) {
        await txn.insert('users', Map<String, dynamic>.from(row));
      }
      for (var row in (data['products'] as List)) {
        await txn.insert('products', Map<String, dynamic>.from(row));
      }
      for (var row in (data['shifts'] as List)) {
        await txn.insert('shifts', Map<String, dynamic>.from(row));
      }
      for (var row in (data['sales'] as List)) {
        await txn.insert('sales', Map<String, dynamic>.from(row));
      }
      for (var row in (data['sale_items'] as List)) {
        await txn.insert('sale_items', Map<String, dynamic>.from(row));
      }
      for (var row in (data['cash_movements'] as List)) {
        await txn.insert('cash_movements', Map<String, dynamic>.from(row));
      }
      for (var row in (data['audit_logs'] as List)) {
        await txn.insert('audit_logs', Map<String, dynamic>.from(row));
      }
    });
  }
}
