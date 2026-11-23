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

    // Credentials are NEVER written to the plaintext backup: `users` is
    // exported without password_hash / salt, and the licensing / session /
    // device-identity secrets are stripped from `settings` below. This is an
    // operational snapshot, not a full-fidelity credential restore (audit #7).
    // DataImporter tolerates the omitted hashes by preserving the restoring
    // owner's live password and re-seeding every other account with an unusable
    // hash, so a leaked backup can never be replayed into logins. The
    // non-secret `permissions` list IS carried so a restored staff account
    // keeps its feature ticks.
    final users = await db.query(
      'users',
      columns: [
        'id',
        'username',
        'role',
        'is_active',
        'permissions',
        // Deleted accounts travel with the backup (still flagged), because
        // their sales reference them: dropping the row would break the
        // restore's foreign keys.
        'deleted_at',
        'created_at',
      ],
    );
    final products = await db.query('products');
    final sales = await db.query('sales');
    final saleItems = await db.query('sale_items');
    final voidRequests = await db.query('void_requests');
    final shifts = await db.query('shifts');
    final cashMovements = await db.query('cash_movements');
    // Schema 16 keeps proof photos as BLOBs in their own table. Re-attach them
    // as base64 on the exported movement rows so a backup taken now still
    // restores its photos (the importer writes them back into the legacy
    // column, which the ledger read falls back to).
    final photos = await db.query('cash_movement_photos');
    final photosByMovement = {
      for (final row in photos) row['movement_id'] as String: row['jpeg_bytes'],
    };
    final cashMovementsWithPhotos = <Map<String, dynamic>>[];
    for (final movement in cashMovements) {
      final bytes = photosByMovement[movement['id']];
      if (bytes is List<int> && bytes.isNotEmpty) {
        cashMovementsWithPhotos.add(Map<String, dynamic>.from(movement)
          ..['photo'] = base64Encode(bytes));
      } else {
        cashMovementsWithPhotos.add(movement);
      }
    }
    final auditLogs = await db.query('audit_logs');
    final devices = await db.query('devices');
    final counters = await db.query('counters');
    // Drop keys that hold licensing / session / device-identity secrets: the
    // signed license, the activation code, the per-install + hardware UUIDs,
    // and the cached auth session. None of these are needed to restore the
    // business data (they are re-derived on next activation / login), and all
    // of them are directly exploitable if a backup leaks. Everything else
    // (theme, shop prefs, etc.) is safe to carry.
    const secretSettingKeys = {
      'auth_session',
      'license_code',
      'activation_code',
      'device_hw_uuid',
      'device_install_uuid',
    };
    final allSettings = await db.query('settings');
    final settings = allSettings
        .where((row) => !secretSettingKeys.contains(row['key']))
        .toList();
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
      'cash_movements': cashMovementsWithPhotos,
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