import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:uuid/uuid.dart';

class LocalDatabase {
  static const String databaseName = 'wholesale_pos.db';
  static const int schemaVersion = 14;
  static const String deviceIdFileName = 'device_id.txt';
  static const String themeSettingKey = 'theme_mode';

  LocalDatabase._();

  static void _configureFactory() {
    // On desktop (and in `flutter test`, which runs on the host VM) use the
    // pure-Dart FFI engine. On Android/iOS the native sqflite plugin is already
    // the default factory, so nothing is overridden there.
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      ffi.sqfliteFfiInit();
      databaseFactory = ffi.databaseFactoryFfi;
    }
  }

  static Future<Database> open() async {
    _configureFactory();
    final dir = await getApplicationSupportDirectory();
    return _openAt(p.join(dir.path, databaseName));
  }

  /// Opens a database at an explicit path. Used by tests that need to exercise
  /// migrations against a real file.
  static Future<Database> openAt(String path) async {
    _configureFactory();
    return _openAt(path);
  }

  static Future<Database> openInMemory() async {
    _configureFactory();
    return databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  static Future<Database> _openAt(String path) {
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  /// Returns the stable ID of this installation. The ID is persisted next to
  /// the database so a restored backup can safely add the row back instead of
  /// attaching new sales to another machine's device record.
  static Future<String> registerCurrentDevice(Database db) async {
    if (db.path == inMemoryDatabasePath) {
      final existing = await db.query('devices', orderBy: 'rowid', limit: 1);
      if (existing.isNotEmpty) return existing.first['id']! as String;
      final id = const Uuid().v4();
      await _insertDeviceIfMissing(db, id);
      return id;
    }

    final stateFile = File(p.join(p.dirname(db.path), deviceIdFileName));
    String? id;
    try {
      if (await stateFile.exists()) {
        final saved = (await stateFile.readAsString()).trim();
        if (saved.isNotEmpty) id = saved;
      }
    } catch (_) {
      id = null;
    }
    if (id == null) {
      id = const Uuid().v4();
      await stateFile.writeAsString(id, flush: true);
    }
    await _insertDeviceIfMissing(db, id);
    return id;
  }

  static Future<void> _insertDeviceIfMissing(Database db, String id) async {
    final existing = await db.query(
      'devices',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    await db.insert('devices', {
      'id': id,
      'name': '${Platform.localHostname} Register',
      'platform': Platform.operatingSystem,
    });
  }

  static Future<String?> getSetting(Database db, String key) async {
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  static Future<void> setSetting(Database db, String key, String value) async {
    await db.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE shifts (
          id TEXT PRIMARY KEY,
          cashier_id TEXT NOT NULL,
          opening_cash_minor_units INTEGER NOT NULL,
          closing_cash_minor_units INTEGER,
          expected_cash_minor_units INTEGER,
          status TEXT NOT NULL,
          opened_at TEXT NOT NULL,
          closed_at TEXT
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute(
        "ALTER TABLE sales ADD COLUMN payment_method TEXT NOT NULL DEFAULT 'CASH'",
      );
    }
    if (oldVersion < 4) {
      await db.execute(
        "ALTER TABLE users ADD COLUMN salt TEXT NOT NULL DEFAULT ''",
      );
      await db.execute("ALTER TABLE sales ADD COLUMN shift_id TEXT");
      await db.execute("ALTER TABLE sales ADD COLUMN void_reason TEXT");
      await db.execute('''
        CREATE TABLE cash_movements (
          id TEXT PRIMARY KEY,
          shift_id TEXT NOT NULL,
          type TEXT NOT NULL,
          amount_minor_units INTEGER NOT NULL,
          reason TEXT,
          created_at TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE sales ADD COLUMN voided_at TEXT');
      await db.execute('ALTER TABLE sales ADD COLUMN voided_by TEXT');
      await db.execute('ALTER TABLE sales ADD COLUMN voided_shift_id TEXT');
      await db.execute('ALTER TABLE cash_movements ADD COLUMN user_id TEXT');
      final openShifts = await db.rawQuery(
        "SELECT COUNT(*) AS count FROM shifts WHERE status = 'OPEN'",
      );
      if ((openShifts.first['count'] as int) <= 1) {
        await db.execute(
          "CREATE UNIQUE INDEX one_open_shift ON shifts(status) WHERE status = 'OPEN'",
        );
      }
      await db.execute('''
        CREATE TRIGGER prevent_second_open_shift_insert
        BEFORE INSERT ON shifts WHEN NEW.status = 'OPEN'
        AND EXISTS (SELECT 1 FROM shifts WHERE status = 'OPEN')
        BEGIN SELECT RAISE(ABORT, 'A shift is already open'); END
      ''');
      await db.execute('''
        CREATE TRIGGER prevent_second_open_shift_update
        BEFORE UPDATE OF status ON shifts WHEN NEW.status = 'OPEN'
        AND EXISTS (SELECT 1 FROM shifts WHERE status = 'OPEN' AND id != NEW.id)
        BEGIN SELECT RAISE(ABORT, 'A shift is already open'); END
      ''');
      await db.execute('CREATE INDEX sales_shift_id ON sales(shift_id)');
    }
    if (oldVersion < 6) {
      await _rebuildCashMovementsWithUserForeignKey(db);
      await db.execute('''
        CREATE TABLE IF NOT EXISTS counters (
          name TEXT PRIMARY KEY,
          value INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
      await _createIndexesAndTriggers(db);
    }
    if (oldVersion < 7) {
      await _rebuildSaleItemsWithFlexibleQuantities(db);
      await db.execute('''
        CREATE TABLE IF NOT EXISTS finance_categories (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS finance_entries (
          id TEXT PRIMARY KEY,
          category_id TEXT NOT NULL,
          source TEXT NOT NULL,
          amount_minor_units INTEGER NOT NULL,
          description TEXT,
          status TEXT NOT NULL DEFAULT 'PENDING',
          entry_date TEXT NOT NULL,
          created_at TEXT NOT NULL,
          created_by TEXT NOT NULL,
          completed_at TEXT,
          completed_by TEXT,
          updated_at TEXT NOT NULL,
          FOREIGN KEY(category_id) REFERENCES finance_categories(id),
          FOREIGN KEY(created_by) REFERENCES users(id),
          FOREIGN KEY(completed_by) REFERENCES users(id)
        )
      ''');
      await _createIndexesAndTriggers(db);
    }
    if (oldVersion < 8) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS void_requests (
          id TEXT PRIMARY KEY,
          sale_id TEXT NOT NULL,
          requested_by TEXT NOT NULL,
          reason TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'PENDING',
          created_at TEXT NOT NULL,
          decided_by TEXT,
          decided_at TEXT,
          FOREIGN KEY(sale_id) REFERENCES sales(id),
          FOREIGN KEY(requested_by) REFERENCES users(id),
          FOREIGN KEY(decided_by) REFERENCES users(id)
        )
      ''');
      await _createIndexesAndTriggers(db);
    }
    if (oldVersion < 9) {
      // Local-only change queue for the future cloud sync. Business tables are
      // unchanged; this just records what still needs pushing to the server.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS sync_outbox (
          id TEXT PRIMARY KEY,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          operation TEXT NOT NULL,
          payload TEXT NOT NULL,
          created_at TEXT NOT NULL,
          synced_at TEXT
        )
      ''');
      await _createIndexesAndTriggers(db);
    }
    if (oldVersion < 10) {
      // Money tracking gains a recycle bin (soft delete on people) and a
      // payment method on entries so cash collections can deposit to the
      // register. Both are additive ALTERs, guarded so a re-run is a no-op.
      final catCols = await db.rawQuery(
        'PRAGMA table_info(finance_categories)',
      );
      if (!catCols.any((column) => column['name'] == 'deleted_at')) {
        await db.execute(
          'ALTER TABLE finance_categories ADD COLUMN deleted_at TEXT',
        );
      }
      final entryCols = await db.rawQuery('PRAGMA table_info(finance_entries)');
      if (!entryCols.any((column) => column['name'] == 'payment_method')) {
        await db.execute(
          "ALTER TABLE finance_entries ADD COLUMN payment_method TEXT",
        );
      }
      await _createIndexesAndTriggers(db);
    }
    if (oldVersion < 11) {
      // Per-account feature permissions replace the fixed Owner/Cashier nav
      // split. Additive column, guarded so a re-run is a no-op, then backfill
      // existing CASHIER rows with the tabs they already saw (today's cashier
      // matrix) so an upgrade never strips a cashier's access. OWNER rows stay
      // '[]' — they bypass the tick list.
      final userCols = await db.rawQuery('PRAGMA table_info(users)');
      if (!userCols.any((column) => column['name'] == 'permissions')) {
        await db.execute(
          "ALTER TABLE users ADD COLUMN permissions TEXT NOT NULL DEFAULT '[]'",
        );
      }
      await db.execute(
        "UPDATE users SET permissions = '[\"pos\",\"register\",\"reports\"]' "
        "WHERE role = 'CASHIER' AND permissions = '[]'",
      );
    }
    if (oldVersion < 12) {
      // Optional proof photo on register movements (mainly debits): a
      // compressed JPEG stored as base64 TEXT so it rides the row everywhere
      // the movement goes — ledger, outbox payload, backups. Additive column,
      // guarded so a re-run is a no-op.
      final movementCols = await db.rawQuery(
        'PRAGMA table_info(cash_movements)',
      );
      if (!movementCols.any((column) => column['name'] == 'photo')) {
        await db.execute('ALTER TABLE cash_movements ADD COLUMN photo TEXT');
      }
    }
    if (oldVersion < 13) {
      // Marks the permanent, non-deactivatable training account. Additive
      // column, guarded so a re-run is a no-op; existing rows are all 0 and the
      // demo row is seeded by UserRepository.ensureDemoUser().
      final userCols = await db.rawQuery('PRAGMA table_info(users)');
      if (!userCols.any((column) => column['name'] == 'is_demo')) {
        await db.execute(
          'ALTER TABLE users ADD COLUMN is_demo INTEGER NOT NULL DEFAULT 0',
        );
      }
    }
    if (oldVersion < 14) {
      // Deleted accounts. A row that already recorded sales, shifts, cash
      // movements, finance entries or void requests cannot be dropped without
      // orphaning that history (and the FK would reject it), so it is flagged
      // here instead and hidden from every user-facing query. Additive column,
      // guarded so a re-run is a no-op.
      final detailCols = await db.rawQuery('PRAGMA table_info(users)');
      if (!detailCols.any((column) => column['name'] == 'deleted_at')) {
        await db.execute('ALTER TABLE users ADD COLUMN deleted_at TEXT');
      }
    }
  }

  /// Schema 6 stored quantities as plain integers. Schema 7 keeps the exact
  /// text the cashier typed ("2 boxes and 1 piece") plus a separate numeric
  /// billing quantity in milliunits, so descriptive entries are never forced
  /// into a number. Existing rows keep their values: the integer quantity is
  /// copied into both new columns.
  static Future<void> _rebuildSaleItemsWithFlexibleQuantities(
    Database db,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info(sale_items)');
    if (columns.any((column) => column['name'] == 'quantity_text')) return;

    await db.execute('''
      CREATE TABLE sale_items_v7 (
        id TEXT PRIMARY KEY,
        sale_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        product_name_snapshot TEXT NOT NULL,
        unit_price_snapshot_minor_units INTEGER NOT NULL,
        quantity_text TEXT NOT NULL,
        billing_quantity_milliunits INTEGER,
        line_discount_minor_units INTEGER NOT NULL DEFAULT 0,
        line_total_minor_units INTEGER NOT NULL,
        notes TEXT,
        FOREIGN KEY(sale_id) REFERENCES sales(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      INSERT INTO sale_items_v7
        (id, sale_id, product_id, product_name_snapshot,
         unit_price_snapshot_minor_units, quantity_text,
         billing_quantity_milliunits, line_discount_minor_units,
         line_total_minor_units, notes)
      SELECT id, sale_id, product_id, product_name_snapshot,
         unit_price_snapshot_minor_units, CAST(quantity AS TEXT),
         quantity * 1000, line_discount_minor_units,
         line_total_minor_units, NULL
      FROM sale_items
    ''');
    await db.execute('DROP TABLE sale_items');
    await db.execute('ALTER TABLE sale_items_v7 RENAME TO sale_items');
  }

  /// Schema 5 added `user_id` with ALTER TABLE, which SQLite cannot attach a
  /// foreign key to. Rebuild the table once so upgraded databases match fresh
  /// installs.
  static Future<void> _rebuildCashMovementsWithUserForeignKey(
    Database db,
  ) async {
    final foreignKeys = await db.rawQuery(
      'PRAGMA foreign_key_list(cash_movements)',
    );
    if (foreignKeys.any((row) => row['table'] == 'users')) return;

    await db.execute('''
      CREATE TABLE cash_movements_v6 (
        id TEXT PRIMARY KEY,
        shift_id TEXT NOT NULL,
        type TEXT NOT NULL,
        amount_minor_units INTEGER NOT NULL,
        reason TEXT,
        created_at TEXT NOT NULL,
        user_id TEXT,
        FOREIGN KEY(shift_id) REFERENCES shifts(id),
        FOREIGN KEY(user_id) REFERENCES users(id)
      )
    ''');
    await db.execute('''
      INSERT INTO cash_movements_v6
        (id, shift_id, type, amount_minor_units, reason, created_at, user_id)
      SELECT id, shift_id, type, amount_minor_units, reason, created_at, user_id
      FROM cash_movements
    ''');
    await db.execute('DROP TABLE cash_movements');
    await db.execute('ALTER TABLE cash_movements_v6 RENAME TO cash_movements');
  }

  static Future<void> _createIndexesAndTriggers(DatabaseExecutor db) async {
    final openShifts = await db.rawQuery(
      "SELECT COUNT(*) AS count FROM shifts WHERE status = 'OPEN'",
    );
    if ((openShifts.first['count'] as int) <= 1) {
      await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS one_open_shift ON shifts(status) WHERE status = 'OPEN'",
      );
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS sales_shift_id ON sales(shift_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS sales_created_at ON sales(created_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS sale_items_sale_id ON sale_items(sale_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS audit_logs_created_at ON audit_logs(created_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS cash_movements_shift_id ON cash_movements(shift_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS finance_entries_category_id '
      'ON finance_entries(category_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS finance_entries_status '
      'ON finance_entries(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS finance_entries_entry_date '
      'ON finance_entries(entry_date)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS void_requests_sale_id '
      'ON void_requests(sale_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS void_requests_status '
      'ON void_requests(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS sync_outbox_pending '
      'ON sync_outbox(synced_at)',
    );
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS prevent_second_open_shift_insert
      BEFORE INSERT ON shifts WHEN NEW.status = 'OPEN'
      AND EXISTS (SELECT 1 FROM shifts WHERE status = 'OPEN')
      BEGIN SELECT RAISE(ABORT, 'A shift is already open'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS prevent_second_open_shift_update
      BEFORE UPDATE OF status ON shifts WHEN NEW.status = 'OPEN'
      AND EXISTS (SELECT 1 FROM shifts WHERE status = 'OPEN' AND id != NEW.id)
      BEGIN SELECT RAISE(ABORT, 'A shift is already open'); END
    ''');
  }

  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        username TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        salt TEXT NOT NULL,
        role TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        permissions TEXT NOT NULL DEFAULT '[]',
        is_demo INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE products (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        code TEXT UNIQUE NOT NULL,
        category TEXT,
        unit TEXT NOT NULL,
        selling_price_minor_units INTEGER NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE devices (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        platform TEXT NOT NULL,
        license_key TEXT,
        last_sync_at TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE shifts (
        id TEXT PRIMARY KEY,
        cashier_id TEXT NOT NULL,
        opening_cash_minor_units INTEGER NOT NULL,
        closing_cash_minor_units INTEGER,
        expected_cash_minor_units INTEGER,
        status TEXT NOT NULL,
        opened_at TEXT NOT NULL,
        closed_at TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE cash_movements (
        id TEXT PRIMARY KEY,
        shift_id TEXT NOT NULL,
        type TEXT NOT NULL,
        amount_minor_units INTEGER NOT NULL,
        reason TEXT,
        created_at TEXT NOT NULL,
        user_id TEXT,
        photo TEXT,
        FOREIGN KEY(shift_id) REFERENCES shifts(id),
        FOREIGN KEY(user_id) REFERENCES users(id)
      )
    ''');

    batch.execute('''
      CREATE TABLE sales (
        id TEXT PRIMARY KEY,
        receipt_number TEXT UNIQUE NOT NULL,
        cashier_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        shift_id TEXT NOT NULL,
        customer_name TEXT,
        payment_method TEXT NOT NULL DEFAULT 'CASH',
        subtotal_minor_units INTEGER NOT NULL,
        discount_minor_units INTEGER NOT NULL,
        total_minor_units INTEGER NOT NULL,
        amount_paid_minor_units INTEGER NOT NULL,
        change_minor_units INTEGER NOT NULL,
        status TEXT NOT NULL,
        void_reason TEXT,
        voided_at TEXT,
        voided_by TEXT,
        voided_shift_id TEXT,
        created_at TEXT NOT NULL,
        synced_at TEXT,
        FOREIGN KEY(cashier_id) REFERENCES users(id),
        FOREIGN KEY(device_id) REFERENCES devices(id),
        FOREIGN KEY(shift_id) REFERENCES shifts(id)
      )
    ''');

    batch.execute('''
      CREATE TABLE sale_items (
        id TEXT PRIMARY KEY,
        sale_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        product_name_snapshot TEXT NOT NULL,
        unit_price_snapshot_minor_units INTEGER NOT NULL,
        quantity_text TEXT NOT NULL,
        billing_quantity_milliunits INTEGER,
        line_discount_minor_units INTEGER NOT NULL DEFAULT 0,
        line_total_minor_units INTEGER NOT NULL,
        notes TEXT,
        FOREIGN KEY(sale_id) REFERENCES sales(id) ON DELETE CASCADE
      )
    ''');

    batch.execute('''
      CREATE TABLE finance_categories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE finance_entries (
        id TEXT PRIMARY KEY,
        category_id TEXT NOT NULL,
        source TEXT NOT NULL,
        amount_minor_units INTEGER NOT NULL,
        description TEXT,
        status TEXT NOT NULL DEFAULT 'PENDING',
        entry_date TEXT NOT NULL,
        created_at TEXT NOT NULL,
        created_by TEXT NOT NULL,
        completed_at TEXT,
        completed_by TEXT,
        updated_at TEXT NOT NULL,
        payment_method TEXT,
        FOREIGN KEY(category_id) REFERENCES finance_categories(id),
        FOREIGN KEY(created_by) REFERENCES users(id),
        FOREIGN KEY(completed_by) REFERENCES users(id)
      )
    ''');

    batch.execute('''
      CREATE TABLE void_requests (
        id TEXT PRIMARY KEY,
        sale_id TEXT NOT NULL,
        requested_by TEXT NOT NULL,
        reason TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'PENDING',
        created_at TEXT NOT NULL,
        decided_by TEXT,
        decided_at TEXT,
        FOREIGN KEY(sale_id) REFERENCES sales(id),
        FOREIGN KEY(requested_by) REFERENCES users(id),
        FOREIGN KEY(decided_by) REFERENCES users(id)
      )
    ''');

    batch.execute('''
      CREATE TABLE audit_logs (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        action TEXT NOT NULL,
        details TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE counters (
        name TEXT PRIMARY KEY,
        value INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    // Transactional outbox: every business write appends a row here inside the
    // same transaction, and a background worker drains it to the cloud when a
    // SyncBackend is configured. Rows survive restarts and offline periods.
    batch.execute('''
      CREATE TABLE sync_outbox (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        operation TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT NOT NULL,
        synced_at TEXT
      )
    ''');

    await batch.commit(noResult: true);
    await _createIndexesAndTriggers(db);
  }
}
