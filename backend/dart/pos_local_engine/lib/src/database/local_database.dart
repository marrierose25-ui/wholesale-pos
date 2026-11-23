
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:uuid/uuid.dart';

import 'package:pos_contracts/pos_contracts.dart';

/// Thrown when the on-disk database carries a `user_version` newer than
/// [LocalDatabase.schemaVersion] — it was last written by a newer build of
/// the app (for example after a rollback to an older installer).
///
/// The open is refused inside sqflite's version transaction, before
/// `user_version` is rewritten, so the file, its tables, indexes, triggers and
/// rows are left byte-for-byte intact. There is no automatic repair: an older
/// build cannot know what the newer schema means, and guessing is how data
/// gets destroyed.
class UnsupportedDatabaseVersionException implements Exception {
  const UnsupportedDatabaseVersionException({
    required this.foundVersion,
    required this.supportedVersion,
  });

  /// The `PRAGMA user_version` found on disk.
  final int foundVersion;

  /// The newest schema this build knows how to migrate.
  final int supportedVersion;

  @override
  String toString() {
    return 'This database was created by a newer version of Wholesale POS '
        '(schema v$foundVersion); this build only supports up to schema '
        'v$supportedVersion. The app will not open it rather than risk '
        'damaging your data. Install the newer version of the app (or restore '
        'the previous installation), then open the database again. The file '
        'was not modified.';
  }
}

class LocalDatabase {
  static const String databaseName = 'wholesale_pos.db';
  static const int schemaVersion = 23;
  static const String deviceIdFileName = 'device_id.txt';
  static const String themeSettingKey = 'theme_mode';

  /// Suffix of the safety copy taken before a schema change. See
  /// [_backupBeforeSchemaChange].
  static const String backupSuffix = '.bak';

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
        onDowngrade: _onDowngrade,
      ),
    );
  }

  static Future<Database> _openAt(String path) {
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          // `onConfigure` is the last moment before sqflite reads `user_version`
          // and starts writing, so the copy taken here is the pre-migration
          // file, byte for byte.
          await _backupBeforeSchemaChange(db);
        },
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onDowngrade: _onDowngrade,
      ),
    );
  }

  /// Refuses to open a database written by a newer build.
  ///
  /// sqflite calls this inside the version transaction, before it stamps
  /// `user_version` with this build's version. Throwing rolls the transaction
  /// back, so the on-disk version — and everything else in the file — is
  /// preserved exactly. Without this callback sqflite would silently rewrite
  /// `user_version` to the lower number while leaving the newer schema in
  /// place, and every later open by the newer build would see a database it
  /// no longer recognises.
  static Future<void> _onDowngrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    throw UnsupportedDatabaseVersionException(
      foundVersion: oldVersion,
      supportedVersion: newVersion,
    );
  }

  /// Copies the on-disk database to `<path>.bak` when this build is about to
  /// change its schema version.
  ///
  /// `onUpgrade` runs inside one SQLite transaction, so a migration that throws
  /// rolls back and the file is left as it was. What that does NOT protect
  /// against is a migration that completes and is simply wrong — a rebuild that
  /// copies a table and drops a column it did not mean to, which is the failure
  /// mode every past schema bug in this project has had. By then the damage is
  /// committed and the only copy of the shop's real ledger is the `.bak` this
  /// made first, and renaming it back over `wholesale_pos.db` is the whole
  /// recovery procedure.
  ///
  /// Three deliberate details:
  ///   * A brand-new file (`user_version == 0`) is skipped: there is nothing in
  ///     it to save, and `onCreate` is not a migration.
  ///   * An already-current file is skipped, so a bad migration that DID land
  ///     cannot overwrite last week's good backup on the next launch.
  ///   * A file NEWER than this build is backed up too. `_onDowngrade` then
  ///     refuses the open, so the copy is the only write-adjacent artefact:
  ///     it preserves the newer file's bytes before the shop rolls a till back
  ///     to an older installer and wonders where the data went.
  ///
  /// A failed backup does NOT stop the open. A till that cannot write its
  /// backup still has to trade; refusing to start turns a disk problem into a
  /// closed shop. The failure is logged, and logged loudly, because it means
  /// this run has no safety copy.
  static Future<void> _backupBeforeSchemaChange(Database db) async {
    final path = db.path;
    if (path == inMemoryDatabasePath) return;

    final int onDisk;
    try {
      onDisk = await db.getVersion();
    } catch (e) {
      AppLogger.warn(
        'MIGRATION BACKUP SKIPPED: could not read the schema '
        'version of $path: $e',
      );
      return;
    }
    if (onDisk == 0 || onDisk == schemaVersion) return;

    try {
      final file = File(path);
      if (!await file.exists()) return;
      // The database has no `-wal`/`-shm` sidecars to worry about: this project
      // never sets `journal_mode = WAL`, so SQLite is in rollback-journal mode,
      // where the main file is only amended once a transaction has committed
      // and its journal is gone. This process holds the only handle and has run
      // no write yet, so a plain copy is a consistent snapshot.
      await file.copy('$path$backupSuffix');
      AppLogger.info(
        'MIGRATION BACKUP: schema v$onDisk -> v$schemaVersion, '
        'pre-change copy at $path$backupSuffix',
      );
    } catch (e) {
      AppLogger.warn(
        'MIGRATION BACKUP FAILED for v$onDisk -> v$schemaVersion: '
        '$e — the migration will run with NO safety copy of this file.',
      );
    }
  }

  /// Ensures at most one OPEN shift. Older data may contain >1 if a
  /// historical close bug left rows stuck; auto-close all but the newest.
  static Future<void> _closeDuplicateOpenShifts(Database db) async {
    final rows = await db.rawQuery(
      "SELECT id, opened_at FROM shifts WHERE status = 'OPEN' ORDER BY opened_at ASC",
    );
    if (rows.length <= 1) return;
    final now = DateTime.now().toUtc().toIso8601String();
    for (var i = 0; i < rows.length - 1; i++) {
      final id = rows[i]['id'] as String;
      AppLogger.warn('MIGRATION: auto-closing stale duplicate open shift $id');
      await db.update(
        'shifts',
        {'status': 'CLOSED', 'closed_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
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
      try {
        await _closeDuplicateOpenShifts(db);
      } catch (e) {
        AppLogger.warn(
          'MIGRATION WARNING: could not close duplicate open shifts: $e',
        );
      }
      try {
        await db.execute(
          'CREATE UNIQUE INDEX IF NOT EXISTS one_open_shift '
          "ON shifts(status) WHERE status = 'OPEN'",
        );
      } catch (e) {
        AppLogger.warn('MIGRATION WARNING: one_open_shift index failed: $e');
      }
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
      await db.execute(
        'CREATE INDEX IF NOT EXISTS sales_shift_id ON sales(shift_id)',
      );
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
    if (oldVersion < 15) {
      // An account created or reset in the browser is hashed by `pos-api` into
      // a different format from this app's PBKDF2 rows, and it is re-issued
      // whenever the owner resets it there. Keeping it in its own pair means a
      // browser password can be accepted here without ever overwriting a
      // password this device set. Additive columns, guarded so a re-run is a
      // no-op.
      final userCols = await db.rawQuery('PRAGMA table_info(users)');
      if (!userCols.any((column) => column['name'] == 'cloud_pw_hash')) {
        await db.execute('ALTER TABLE users ADD COLUMN cloud_pw_hash TEXT');
      }
      if (!userCols.any((column) => column['name'] == 'cloud_pw_salt')) {
        await db.execute('ALTER TABLE users ADD COLUMN cloud_pw_salt TEXT');
      }
    }
    if (oldVersion < 16) {
      // Proof photos move out of the movement row into a BLOB table. Storing
      // them as base64 TEXT on `cash_movements` inflated every ledger query and
      // every backup by a third, and the row travelled with the photo attached
      // everywhere it was read. The column is kept (nullable, no longer
      // written) so an older build pointed at this file still opens it.
      await _createCashMovementPhotosTable(db);
      final pending = await db.rawQuery(
        "SELECT id, photo FROM cash_movements "
        "WHERE photo IS NOT NULL AND photo <> ''",
      );
      final now = DateTime.now().toUtc().toIso8601String();
      for (final row in pending) {
        try {
          await db.insert('cash_movement_photos', {
            'movement_id': row['id'] as String,
            'jpeg_bytes': base64Decode(row['photo'] as String),
            'created_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        } catch (_) {
          // A corrupt base64 payload keeps its legacy TEXT value: dropping the
          // photo silently would be worse than leaving the row unmigrated.
          continue;
        }
        await db.update(
          'cash_movements',
          {'photo': null},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    }
    if (oldVersion < 17) {
      // Which collection put this money in the drawer. A cash collection is
      // deposited by the till AND, if the browser completed the same entry, by
      // `pos_complete_finance` — and the cloud refuses a second deposit per
      // entry through `cash_movements_one_per_finance_entry` while this device
      // had nothing to compare against. The id travels in the outbox payload
      // now, so the two paths agree on one movement instead of writing two.
      // Additive column, guarded so a re-run is a no-op.
      final movementCols = await db.rawQuery(
        'PRAGMA table_info(cash_movements)',
      );
      if (!movementCols.any(
        (column) => column['name'] == 'source_finance_entry_id',
      )) {
        await db.execute(
          'ALTER TABLE cash_movements ADD COLUMN source_finance_entry_id TEXT',
        );
      }
    }
    if (oldVersion < 18) {
      // A drawer belongs to an account (see [_createShiftCashierGuards]).
      await _createShiftCashierGuards(db);
    }
    if (oldVersion < 19) {
      // The stamp the cloud compares before it lets one surface overwrite
      // another. Without it, an older edit pulled from the browser could
      // replace a newer one made on the till.
      final userCols = await db.rawQuery('PRAGMA table_info(users)');
      if (!userCols.any((column) => column['name'] == 'updated_at')) {
        await db.execute('ALTER TABLE users ADD COLUMN updated_at TEXT');
      }
      await db.execute(
        'UPDATE users SET updated_at = created_at WHERE updated_at IS NULL',
      );
    }
    if (oldVersion < 20) {
      // Warehouse Picklists (Digital Fulfillment): an independent feature with
      // its own tables. A picklist header is created against a customer name
      // and its line items are ticked up as warehouse workers take stock, so
      // both tables are mutable and carry an `updated_at` the sync compares.
      // Kept entirely separate from Sales/Shifts/Finance — nothing here points
      // at those tables and they point at nothing here.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS picklists (
          id TEXT PRIMARY KEY,
          customer_name TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'PENDING',
          created_by TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS picklist_items (
          id TEXT PRIMARY KEY,
          picklist_id TEXT NOT NULL,
          product_name TEXT NOT NULL,
          requested_qty INTEGER NOT NULL,
          taken_qty INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL,
          FOREIGN KEY(picklist_id) REFERENCES picklists(id) ON DELETE CASCADE
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS picklist_items_picklist_id '
        'ON picklist_items(picklist_id)',
      );
    }
    if (oldVersion < 21) {
      // Warehouse Picklist upgrade: line pricing (unit, unit price, computed
      // line total) so a picklist can carry a value, and a reusable customer
      // directory so the create form can pick a saved customer instead of
      // retyping it. Purely additive — the existing picklist rows keep working
      // with the defaulted zero/null pricing, and nothing here touches Sales /
      // Shifts / Finance.
      final itemCols = await db.rawQuery('PRAGMA table_info(picklist_items)');
      if (!itemCols.any((column) => column['name'] == 'unit')) {
        await db.execute('ALTER TABLE picklist_items ADD COLUMN unit TEXT');
      }
      if (!itemCols.any(
        (column) => column['name'] == 'unit_price_minor_units',
      )) {
        await db.execute(
          'ALTER TABLE picklist_items ADD COLUMN unit_price_minor_units '
          'INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!itemCols.any(
        (column) => column['name'] == 'line_total_minor_units',
      )) {
        await db.execute(
          'ALTER TABLE picklist_items ADD COLUMN line_total_minor_units '
          'INTEGER NOT NULL DEFAULT 0',
        );
      }
      await db.execute('''
        CREATE TABLE IF NOT EXISTS picklist_customers (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          phone TEXT,
          created_at TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 22) {
      // Warehouse Picklist edit/delete: a soft-delete tombstone on both the
      // header and its lines. A physical delete would vanish from one device
      // and never reach the others (the sync feed has no delete channel), so
      // the row stays and every read filters `deleted_at IS NULL`. Additive and
      // guarded, so a re-run is a no-op.
      final headerCols = await db.rawQuery('PRAGMA table_info(picklists)');
      if (!headerCols.any((column) => column['name'] == 'deleted_at')) {
        await db.execute('ALTER TABLE picklists ADD COLUMN deleted_at TEXT');
      }
      final itemCols = await db.rawQuery('PRAGMA table_info(picklist_items)');
      if (!itemCols.any((column) => column['name'] == 'deleted_at')) {
        await db.execute(
          'ALTER TABLE picklist_items ADD COLUMN deleted_at TEXT',
        );
      }
    }
    if (oldVersion < 23) {
      // Converge `picklist_items_picklist_id` onto every database. The index
      // was introduced with the picklist tables at v20 but only created on
      // the `<20` upgrade branch, so databases created at v20 or later —
      // fresh installs and v20/v21/v22 upgrades alike — never received it.
      // `IF NOT EXISTS` makes this a no-op wherever it already exists.
      await db.execute(
        'CREATE INDEX IF NOT EXISTS picklist_items_picklist_id '
        'ON picklist_items(picklist_id)',
      );
    }
  }

  /// Proof photos are BLOBs in their own table (schema 16), one per movement.
  /// `IF NOT EXISTS` keeps the upgrade idempotent and lets both the migration
  /// and a fresh install share one definition.
  static Future<void> _createCashMovementPhotosTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cash_movement_photos (
        movement_id TEXT PRIMARY KEY,
        jpeg_bytes BLOB NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(movement_id) REFERENCES cash_movements(id) ON DELETE CASCADE
      )
    ''');
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

  /// Creates every index and trigger the current schema expects.
  ///
  /// `_onUpgrade` calls this helper at several points (`<6` through `<10`),
  /// which means it can run while `finance_entries`, `void_requests` or
  /// `sync_outbox` do not exist yet — their tables are only created by later
  /// steps in the same upgrade. Every statement is therefore gated on the
  /// table actually being present; a later call later in the same upgrade
  /// creates whatever was deferred, so every supported path still converges
  /// on the full index/trigger set.
  static Future<void> _createIndexesAndTriggers(DatabaseExecutor db) async {
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((row) => row['name'] as String).toSet();

    Future<void> indexOn(String table, String sql) async {
      if (tables.contains(table)) await db.execute(sql);
    }

    if (tables.contains('shifts')) {
      try {
        await db.execute(
          'CREATE UNIQUE INDEX IF NOT EXISTS one_open_shift '
          "ON shifts(status) WHERE status = 'OPEN'",
        );
      } catch (e) {
        AppLogger.warn('WARNING: one_open_shift index failed: $e');
      }
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
    await indexOn(
      'sales',
      'CREATE INDEX IF NOT EXISTS sales_shift_id ON sales(shift_id)',
    );
    await indexOn(
      'sales',
      'CREATE INDEX IF NOT EXISTS sales_created_at ON sales(created_at)',
    );
    await indexOn(
      'sale_items',
      'CREATE INDEX IF NOT EXISTS sale_items_sale_id ON sale_items(sale_id)',
    );
    await indexOn(
      'audit_logs',
      'CREATE INDEX IF NOT EXISTS audit_logs_created_at '
      'ON audit_logs(created_at)',
    );
    await indexOn(
      'cash_movements',
      'CREATE INDEX IF NOT EXISTS cash_movements_shift_id '
      'ON cash_movements(shift_id)',
    );
    await indexOn(
      'finance_entries',
      'CREATE INDEX IF NOT EXISTS finance_entries_category_id '
      'ON finance_entries(category_id)',
    );
    await indexOn(
      'finance_entries',
      'CREATE INDEX IF NOT EXISTS finance_entries_status '
      'ON finance_entries(status)',
    );
    await indexOn(
      'finance_entries',
      'CREATE INDEX IF NOT EXISTS finance_entries_entry_date '
      'ON finance_entries(entry_date)',
    );
    await indexOn(
      'void_requests',
      'CREATE INDEX IF NOT EXISTS void_requests_sale_id '
      'ON void_requests(sale_id)',
    );
    await indexOn(
      'void_requests',
      'CREATE INDEX IF NOT EXISTS void_requests_status '
      'ON void_requests(status)',
    );
    await indexOn(
      'sync_outbox',
      'CREATE INDEX IF NOT EXISTS sync_outbox_pending '
      'ON sync_outbox(synced_at)',
    );
    await indexOn(
      'picklist_items',
      'CREATE INDEX IF NOT EXISTS picklist_items_picklist_id '
      'ON picklist_items(picklist_id)',
    );
    await _createShiftCashierGuards(db);
  }

  /// A drawer belongs to an account. A pulled shift could otherwise name an
  /// operator this file has never heard of, and the ledger then showed a blank
  /// cashier for the whole session.
  ///
  /// This is enforced with guards rather than a `cashier_id` foreign key:
  /// SQLite cannot attach one with ALTER TABLE, and rebuilding `shifts` is not
  /// an option because `sales` and `cash_movements` reference it — dropping it
  /// fails the deferred foreign key check at COMMIT even once the copy is
  /// renamed back into place. The guards apply the same rule on the way in and
  /// leave every stored row untouched.
  ///
  /// The empty cashier stays allowed: it is the placeholder the pull writes
  /// when a sale lands before its drawer, and it is replaced when the shift row
  /// itself arrives.
  static Future<void> _createShiftCashierGuards(DatabaseExecutor db) async {
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((row) => row['name'] as String).toSet();
    if (!tables.contains('shifts') || !tables.contains('users')) return;
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS shifts_cashier_must_exist_insert
      BEFORE INSERT ON shifts WHEN NEW.cashier_id != ''
      AND NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.cashier_id)
      BEGIN SELECT RAISE(ABORT, 'shifts.cashier_id must reference a known user'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS shifts_cashier_must_exist_update
      BEFORE UPDATE OF cashier_id ON shifts WHEN NEW.cashier_id != ''
      AND NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.cashier_id)
      BEGIN SELECT RAISE(ABORT, 'shifts.cashier_id must reference a known user'); END
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
        cloud_pw_hash TEXT,
        cloud_pw_salt TEXT,
        role TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        permissions TEXT NOT NULL DEFAULT '[]',
        is_demo INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT
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
        source_finance_entry_id TEXT,
        FOREIGN KEY(shift_id) REFERENCES shifts(id),
        FOREIGN KEY(user_id) REFERENCES users(id)
      )
    ''');

    batch.execute('''
      CREATE TABLE cash_movement_photos (
        movement_id TEXT PRIMARY KEY,
        jpeg_bytes BLOB NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(movement_id) REFERENCES cash_movements(id) ON DELETE CASCADE
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

    // Warehouse Picklists (schema 20): independent of Sales/Shifts/Finance.
    batch.execute('''
      CREATE TABLE picklists (
        id TEXT PRIMARY KEY,
        customer_name TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'PENDING',
        created_by TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE picklist_items (
        id TEXT PRIMARY KEY,
        picklist_id TEXT NOT NULL,
        product_name TEXT NOT NULL,
        requested_qty INTEGER NOT NULL,
        taken_qty INTEGER NOT NULL DEFAULT 0,
        unit TEXT,
        unit_price_minor_units INTEGER NOT NULL DEFAULT 0,
        line_total_minor_units INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        FOREIGN KEY(picklist_id) REFERENCES picklists(id) ON DELETE CASCADE
      )
    ''');

    // Reusable customer directory for the Warehouse create form (schema 21).
    // Independent of the ledger customers/users tables — it only names who a
    // picklist is for, so it never touches Sales or Finance.
    batch.execute('''
      CREATE TABLE picklist_customers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        created_at TEXT NOT NULL
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