import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqflite/sqflite.dart';
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

    // Schema 8 backups restore directly. Schema 6 backups are accepted and
    // normalized on import (sale-item quantities are converted to the new
    // flexible columns); anything older is rejected rather than guessed at.
    final backupVersion = data['version'];
    if (backupVersion is! int ||
        backupVersion < 6 ||
        backupVersion > LocalDatabase.schemaVersion) {
      throw Exception(
        'Only schema version 6 through ${LocalDatabase.schemaVersion} '
        'backups are supported. Older backups are not guessed at.',
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
    // The finance tables were introduced in schema 7 and void_requests in
    // schema 8; older backups simply start with none.
    final financeCategories = data['finance_categories'] is List
        ? data['finance_categories'] as List
        : <dynamic>[];
    final financeEntries = data['finance_entries'] is List
        ? data['finance_entries'] as List
        : <dynamic>[];
    final voidRequests = data['void_requests'] is List
        ? data['void_requests'] as List
        : <dynamic>[];

    final requiredFields = <String, List<String>>{
      // password_hash / salt are intentionally NOT required: the plaintext
      // backup never carries them (audit #7). Missing credentials are re-seeded
      // on restore below (owner keeps their live password; everyone else is
      // locked until the owner resets it).
      'users': ['id', 'username', 'role', 'is_active', 'created_at'],
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
        'line_total_minor_units',
        if (backupVersion >= 7) 'quantity_text',
        if (backupVersion < 7) 'quantity',
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
    const financeRequiredFields = <String, List<String>>{
      'finance_categories': ['id', 'name', 'created_at', 'updated_at'],
      'finance_entries': [
        'id',
        'category_id',
        'source',
        'amount_minor_units',
        'status',
        'entry_date',
        'created_at',
        'created_by',
        'updated_at',
      ],
    };
    for (final entry in financeRequiredFields.entries) {
      final rows = entry.key == 'finance_categories'
          ? financeCategories
          : financeEntries;
      for (final row in rows) {
        if (row is! Map ||
            entry.value.any((field) => !row.containsKey(field))) {
          throw Exception('Backup has an invalid ${entry.key} record.');
        }
      }
    }
    // void_requests is optional (introduced in schema 8). When present its
    // rows reference sales and users, so they are validated here and restored
    // after those parents.
    const voidRequestRequired = [
      'id',
      'sale_id',
      'requested_by',
      'reason',
      'status',
      'created_at',
    ];
    for (final row in voidRequests) {
      if (row is! Map ||
          voidRequestRequired.any((field) => !row.containsKey(field))) {
        throw Exception('Backup has an invalid void_requests record.');
      }
    }

    // Normalize sale items to the schema 7 shape. Rows from schema 6 backups
    // carried an integer `quantity`; schema 7 rows pass through unchanged.
    final saleItems = (data['sale_items'] as List)
        .map((row) => _normalizeSaleItem(row as Map))
        .toList();

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

    // Capture the restoring owner's live credentials before the table replace
    // so a hash-free backup cannot lock the owner out of their own machine.
    final ownerCred = await db.query(
      'users',
      columns: ['password_hash', 'salt'],
      where: 'id = ?',
      whereArgs: [requestingUserId],
      limit: 1,
    );
    var reseededCount = 0;

    // Persist a recoverable snapshot before the replacement transaction starts.
    final recoveryPath = await DataExporter.exportToJson(
      db,
      requestingUserId: requestingUserId,
    );

    await db.transaction((txn) async {
      // Clear existing data
      await txn.delete('audit_logs');
      await txn.delete('cash_movements');
      await txn.delete('cash_movement_photos');
      await txn.delete('void_requests');
      await txn.delete('sale_items');
      await txn.delete('sales');
      await txn.delete('shifts');
      await txn.delete('finance_entries');
      await txn.delete('finance_categories');
      await txn.delete('devices');
      await txn.delete('products');
      await txn.delete('settings');
      await txn.delete('counters');
      await txn.delete('sync_outbox');
      await txn.delete('users');

      // Insert new data
      for (var row in (data['users'] as List)) {
        final user = Map<String, dynamic>.from(row);
        // Backups omit password_hash / salt by design. Re-seed:
        //  - the restoring owner keeps their live credentials (no lock-out);
        //  - every other account gets a structurally-valid but random digest
        //    that no password can match, so it stays unusable until the owner
        //    resets it from the Users screen.
        if (user['password_hash'] == null || user['salt'] == null) {
          if (user['id'] == requestingUserId && ownerCred.isNotEmpty) {
            user['password_hash'] = ownerCred.first['password_hash'];
            user['salt'] = ownerCred.first['salt'];
          } else {
            user['password_hash'] = _unusableHash();
            user['salt'] = _randomSalt();
            reseededCount++;
          }
        }
        // Backups taken before the permissions column default it here so a
        // restored staff account keeps today's cashier matrix and owners stay
        // tick-free (owners bypass the list). The column is stored as JSON text.
        if (!user.containsKey('permissions') || user['permissions'] == null) {
          user['permissions'] = jsonEncode(
            user['role'] == 'OWNER'
                ? const <String>[]
                : const ['pos', 'register', 'reports'],
          );
        }
        await txn.insert('users', user);
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
      for (var row in saleItems) {
        await txn.insert('sale_items', Map<String, dynamic>.from(row));
      }
      for (var row in voidRequests) {
        await txn.insert('void_requests', Map<String, dynamic>.from(row));
      }
      for (var row in (data['cash_movements'] as List)) {
        await txn.insert('cash_movements', Map<String, dynamic>.from(row));
      }
      for (var row in financeCategories) {
        await txn.insert('finance_categories', Map<String, dynamic>.from(row));
      }
      for (var row in financeEntries) {
        await txn.insert('finance_entries', Map<String, dynamic>.from(row));
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
      // Restoring brings back the backup's sync cursors, which would point the
      // next pull at stale positions and risk missing rows. Drop them so the
      // restored till re-syncs from scratch on the next drain.
      await txn.delete(
        'settings',
        where: 'key LIKE ?',
        whereArgs: ['sync_cursor.%'],
      );
      final fkErrors = await txn.rawQuery('PRAGMA foreign_key_check');
      if (fkErrors.isNotEmpty) {
        throw Exception('Backup contains broken foreign-key relationships.');
      }
      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': requestingUserId,
        'action': 'BACKUP_RESTORED',
        'details':
            'Restored validated schema $backupVersion backup; '
            'recovery copy saved at $recoveryPath'
            '${reseededCount > 0 ? '; $reseededCount account(s) password '
                      'reset required (backup carries no credentials)' : ''}',
        'created_at': DateTime.now().toIso8601String(),
      });
    });
  }

  /// 16 random bytes, base64url — matches UserRepository's salt shape.
  static String _randomSalt() {
    final rnd = Random.secure();
    return base64Url.encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
  }

  /// A well-formed pbkdf2 digest whose tail is random, so no password can ever
  /// reproduce it — the account is effectively locked until a password reset.
  static String _unusableHash() {
    final rnd = Random.secure();
    final derived = base64.encode(
      List<int>.generate(32, (_) => rnd.nextInt(256)),
    );
    return 'pbkdf2-sha256\$v=1\$i=210000\$$derived';
  }

  /// Converts a backed-up sale-item row to the schema 7 shape. Schema 6 rows
  /// stored an integer `quantity`; it becomes both the exact quantity text
  /// and the numeric billing quantity in milliunits. Schema 7 rows already
  /// carry `quantity_text` and pass through unchanged — including a null
  /// billing quantity, which marks a manually entered line amount.
  static Map<String, dynamic> _normalizeSaleItem(Map row) {
    final isLegacy = row['quantity_text'] == null;
    final legacyQuantity = row['quantity'] is int ? row['quantity'] as int : 1;
    return {
      'id': row['id'],
      'sale_id': row['sale_id'],
      'product_id': row['product_id'] ?? 'MANUAL',
      'product_name_snapshot': row['product_name_snapshot'],
      'unit_price_snapshot_minor_units': row['unit_price_snapshot_minor_units'],
      'quantity_text': isLegacy ? '$legacyQuantity' : row['quantity_text'],
      'billing_quantity_milliunits': isLegacy
          ? legacyQuantity * 1000
          : row['billing_quantity_milliunits'],
      'line_discount_minor_units': row['line_discount_minor_units'] ?? 0,
      'line_total_minor_units': row['line_total_minor_units'],
      'notes': row['notes'],
    };
  }
}