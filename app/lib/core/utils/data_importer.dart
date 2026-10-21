import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../database/local_database.dart';
import 'data_exporter.dart';

class DataImporter {
  static Future<void> importFromJson(
    Database db,
    String filePath, {
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
      throw Exception('Only an active owner can restore a backup.');
    }
    final file = File(filePath);
    if (!await file.exists()) throw Exception('Backup file not found.');

    final jsonString = await file.readAsString();
    final Map<String, dynamic> data = jsonDecode(jsonString);

    if (data['version'] != LocalDatabase.schemaVersion) {
      throw Exception(
        'Only schema version ${LocalDatabase.schemaVersion} backups are supported. '
        'Older sales without shift associations are not assigned to arbitrary shifts.',
      );
    }
    for (final table in [
      'users',
      'products',
      'sales',
      'sale_items',
      'shifts',
      'cash_movements',
      'audit_logs',
      'devices',
      'counters',
      'settings',
    ]) {
      if (data[table] is! List) {
        throw Exception('Backup is missing the $table table.');
      }
    }
    const requiredFields = <String, List<String>>{
      'users': [
        'id',
        'username',
        'password_hash',
        'salt',
        'role',
        'is_active',
        'created_at',
      ],
      'products': [
        'id',
        'name',
        'code',
        'unit',
        'selling_price_minor_units',
        'is_active',
        'created_at',
        'updated_at',
      ],
      'sales': [
        'id',
        'receipt_number',
        'cashier_id',
        'device_id',
        'subtotal_minor_units',
        'discount_minor_units',
        'total_minor_units',
        'amount_paid_minor_units',
        'change_minor_units',
        'status',
        'created_at',
      ],
      'sale_items': [
        'id',
        'sale_id',
        'product_name_snapshot',
        'unit_price_snapshot_minor_units',
        'quantity',
        'line_discount_minor_units',
        'line_total_minor_units',
      ],
      'shifts': [
        'id',
        'cashier_id',
        'opening_cash_minor_units',
        'status',
        'opened_at',
      ],
      'cash_movements': [
        'id',
        'shift_id',
        'type',
        'amount_minor_units',
        'created_at',
      ],
      'audit_logs': ['id', 'action', 'created_at'],
      'devices': ['id', 'name', 'platform'],
      'counters': ['name', 'value'],
      'settings': ['key', 'value'],
    };
    for (final entry in requiredFields.entries) {
      for (final row in data[entry.key] as List) {
        if (row is! Map ||
            entry.value.any((field) => !row.containsKey(field))) {
          throw Exception('Backup has an invalid ${entry.key} record.');
        }
      }
    }
    final users = data['users'] as List;
    if (!users.any(
      (row) =>
          row['id'] == requestingUserId &&
          row['role'] == 'OWNER' &&
          row['is_active'] == 1,
    )) {
      throw Exception(
        'Backup must retain the active owner performing the restore.',
      );
    }

    // Persist a recoverable snapshot before the replacement transaction starts.
    final recoveryPath = await DataExporter.exportToJson(
      db,
      requestingUserId: requestingUserId,
    );

    await db.transaction((txn) async {
      // Clear existing data
      await txn.delete('audit_logs');
      await txn.delete('cash_movements');
      await txn.delete('sale_items');
      await txn.delete('sales');
      await txn.delete('shifts');
      await txn.delete('devices');
      await txn.delete('products');
      await txn.delete('settings');
      await txn.delete('counters');
      await txn.delete('users');

      // Insert new data
      for (var row in (data['users'] as List)) {
        await txn.insert('users', Map<String, dynamic>.from(row));
      }
      for (var row in (data['devices'] as List)) {
        await txn.insert('devices', Map<String, dynamic>.from(row));
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
      for (var row in (data['counters'] as List)) {
        await txn.insert('counters', Map<String, dynamic>.from(row));
      }
      for (var row in (data['settings'] as List)) {
        await txn.insert('settings', Map<String, dynamic>.from(row));
      }
      final fkErrors = await txn.rawQuery('PRAGMA foreign_key_check');
      if (fkErrors.isNotEmpty) {
        throw Exception('Backup contains broken foreign-key relationships.');
      }
      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': requestingUserId,
        'action': 'BACKUP_RESTORED',
        'details':
            'Restored validated backup; recovery copy saved at $recoveryPath',
        'created_at': DateTime.now().toIso8601String(),
      });
    });
  }
}
