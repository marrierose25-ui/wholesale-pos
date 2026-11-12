import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../repositories/user_repository.dart';
import '../utils/app_logger.dart';
import 'sync_backend.dart';

/// What one page of cloud changes actually did to the local database.
///
/// `skipped` counts rows the local schema refused — a receipt number this
/// device already issued, a second OPEN shift, a duplicate phone number. Those
/// are reported rather than thrown: one awkward historical row must never stop
/// the rest of the shop's history from arriving.
class SyncApplyReport {
  final int sales;
  final int saleItems;
  final int shifts;
  final int cashMovements;
  final int voidRequests;
  final int users;
  final int devices;

  /// Master data the shop keeps on every device: saved names and the
  /// owner's money tracker. Counted separately from the ledger because a
  /// re-applied edit is a normal steady state, not a new transaction.
  final int products;
  final int financeCategories;
  final int financeEntries;

  /// Warehouse Picklists (Digital Fulfillment). Counted separately from the
  /// ledger because, like master data, a re-applied edit is a normal steady
  /// state rather than a new transaction.
  final int picklists;
  final int picklistItems;
  final int skipped;

  const SyncApplyReport({
    this.sales = 0,
    this.saleItems = 0,
    this.shifts = 0,
    this.cashMovements = 0,
    this.voidRequests = 0,
    this.users = 0,
    this.devices = 0,
    this.products = 0,
    this.financeCategories = 0,
    this.financeEntries = 0,
    this.picklists = 0,
    this.picklistItems = 0,
    this.skipped = 0,
  });

  static const SyncApplyReport empty = SyncApplyReport();

  int get inserted =>
      sales +
      saleItems +
      shifts +
      cashMovements +
      voidRequests +
      users +
      devices +
      products +
      financeCategories +
      financeEntries +
      picklists +
      picklistItems;

  SyncApplyReport operator +(SyncApplyReport other) => SyncApplyReport(
    sales: sales + other.sales,
    saleItems: saleItems + other.saleItems,
    shifts: shifts + other.shifts,
    cashMovements: cashMovements + other.cashMovements,
    voidRequests: voidRequests + other.voidRequests,
    users: users + other.users,
    devices: devices + other.devices,
    products: products + other.products,
    financeCategories: financeCategories + other.financeCategories,
    financeEntries: financeEntries + other.financeEntries,
    picklists: picklists + other.picklists,
    picklistItems: picklistItems + other.picklistItems,
    skipped: skipped + other.skipped,
  );

  bool get isEmpty => inserted == 0 && skipped == 0;

  @override
  String toString() =>
      'SyncApplyReport(sales: $sales, items: $saleItems, shifts: $shifts, '
      'cash: $cashMovements, voids: $voidRequests, users: $users, '
      'devices: $devices, products: $products, '
      'persons: $financeCategories, entries: $financeEntries, '
      'picklists: $picklists, picklistItems: $picklistItems, '
      'skipped: $skipped)';
}

/// Writes cloud rows into the local ledger so a device that signs in sees every
/// transaction of the shop, not just its own.
///
/// Rules, in order of importance:
///
///   * **A local row is never overwritten.** Pulling is additive: if the id is
///     already here, the local copy (which may carry a newer edit not yet
///     pushed) wins. The one exception is a sale's void state, which is decided
///     server-side by the owner — and even that is skipped while this device
///     still has an unacked outbox entry for the same sale.
///   * **Foreign keys are satisfied first.** `PRAGMA foreign_keys = ON` is set
///     on every connection, so the cashier, device and shift a sale points at
///     must exist before the sale is inserted. Hence the fixed order below, and
///     the pulled accounts / device rows that fill in the gaps.
///   * **Refusals are counted, never thrown.** A receipt number this till
///     already used, or a second OPEN shift, fails its unique index; the row is
///     skipped and the count surfaces in [SyncApplyReport.skipped].
///   * **Timestamps are re-localised.** The cloud returns `timestamptz`
///     (`…+00:00`); every local write stores `DateTime.now().toIso8601String()`
///     (local, no zone suffix) and date filters compare those strings, so a raw
///     UTC string would silently move an evening sale to the wrong day.
class SyncPullApplier {
  final Database db;

  const SyncPullApplier(this.db);

  /// Marker written into `users.password_hash` when the credential lives in the
  /// cloud pair instead. It is not a valid PBKDF2 string, so it can never match
  /// a typed password on its own: the account exists so foreign keys resolve
  /// and reports can name the cashier. Values are defined once, on
  /// [UserRepository], because the login path compares against them.
  static const String cloudAccountMarker = UserRepository.cloudAccountMarker;

  /// Placeholders used when a pulled row names a parent this device has never
  /// seen. `sales` is the only way a second till learns that another register
  /// (or a cashier created on it) exists, and its three foreign keys are NOT
  /// NULL, so an unresolved one does not merely look wrong — the whole sale is
  /// rejected by the trigger and silently disappears from this device's
  /// history. These ids are the smallest row that can satisfy them.
  static const String unknownUserId = 'cloud-unknown-user';
  static const String unknownShiftId = 'cloud-unknown-shift';
  static const String unknownDeviceId = 'cloud-unknown-device';

  Future<SyncApplyReport> apply(SyncPullResult page) async {
    var sales = 0,
        saleItems = 0,
        shifts = 0,
        cash = 0,
        voids = 0,
        users = 0,
        devices = 0,
        products = 0,
        persons = 0,
        entries = 0,
        picklists = 0,
        picklistItems = 0,
        skipped = 0;

    await db.transaction((txn) async {
      users = await _applyUsers(txn, page.changes['users'] ?? const []);
      // Master data lands before anything that points at it: a pulled
      // collection names a person, and a person the owner created in the
      // browser has to exist here or the entry fails its foreign key.
      products = await _applyProducts(
        txn,
        page.changes['products'] ?? const [],
      );
      persons = await _applyFinanceCategories(
        txn,
        page.changes['finance_categories'] ?? const [],
      );
      // Warehouse Picklists land here: independent of the ledger, but the
      // header must exist before its items point at it (the local FK on
      // `picklist_items.picklist_id` rejects an orphan).
      picklists = await _applyPicklists(
        txn,
        page.changes['picklists'] ?? const [],
      );
      picklistItems = await _applyPicklistItems(
        txn,
        page.changes['picklist_items'] ?? const [],
      );
      devices = await _ensureDevices(txn, page.changes);
      shifts = await _applyShifts(txn, page.changes['shifts'] ?? const []);
      final applied = await _applySales(txn, page.changes['sales'] ?? const []);
      sales = applied.$1;
      skipped += applied.$2;
      final lines = await _applySaleItems(
        txn,
        page.changes['sale_items'] ?? const [],
      );
      saleItems = lines.$1;
      skipped += lines.$2;
      cash = await _applyCashMovements(
        txn,
        page.changes['cash_movements'] ?? const [],
      );
      voids = await _applyVoidRequests(
        txn,
        page.changes['void_requests'] ?? const [],
      );
      entries = await _applyFinanceEntries(
        txn,
        page.changes['finance_entries'] ?? const [],
      );
    });

    // Conflicts are the only thing a caller can act on; keep them visible.
    // Discounting rows that are simply already present (the normal case after
    // the first sync) is why this is not counted per skipped insert.
    return SyncApplyReport(
      sales: sales,
      saleItems: saleItems,
      shifts: shifts,
      cashMovements: cash,
      voidRequests: voids,
      users: users,
      devices: devices,
      products: products,
      financeCategories: persons,
      financeEntries: entries,
      picklists: picklists,
      picklistItems: picklistItems,
      skipped: skipped,
    );
  }

  // ---------------------------------------------------------------------------
  // Reference rows (must land before anything that points at them).
  // ---------------------------------------------------------------------------

  Future<int> _applyUsers(
    Transaction txn,
    List<Map<String, dynamic>> rows,
  ) async {
    var created = 0;
    for (final row in rows) {
      final id = _str(row['id']);
      if (id == null || id.isEmpty) continue;

      // Login is verified offline, so a device that never created the account
      // can only sign it in if the credential travels with the identity. The
      // gateway releases this row to a device holding a VALID SIGNED LICENSE
      // for the same tenant — the same trust boundary the local database file
      // already sits behind — and the hash is still only usable after the same
      // offline brute-force an attacker who copied the SQLite file would face.
      //
      // `pos-api` hashes with its own iteration count and derives over the
      // decoded salt bytes, so the value cannot be written into the local
      // `password_hash`/`salt` pair (a different format, and one a password
      // reset on this PC would overwrite). It lands in the cloud pair instead,
      // which `UserRepository` also verifies.
      final hash = _str(row['pw_hash']);
      final salt = _str(row['pw_salt']);
      final hasCredential =
          hash != null && salt != null && hash.isNotEmpty && salt.isNotEmpty;
      final credential = hasCredential
          ? <String, Object?>{'cloud_pw_hash': hash, 'cloud_pw_salt': salt}
          : const <String, Object?>{};

      // The training account is ONE login whatever the row id says: the browser
      // seeds it server-side while this till seeds its own copy, so inserting a
      // second `demo` row would leave the owner's browser password unable to
      // open the demo here. Adopt the cloud credential onto the local demo.
      if (row['is_demo'] == true) {
        final demo = await _localDemo(txn, id);
        if (demo != null) {
          // Not `_safely` here. This is the one row on the page whose failure is
          // invisible and expensive: drop it and the owner's browser password
          // stops opening the demo on this till, with a sync that still reports
          // success. Try twice, then say so in the log with the row it was on.
          final values = <String, Object?>{
            ...credential,
            'is_demo': 1,
            // The ticks are the owner's training plan for this login, so
            // they follow the cloud even though the role cannot.
            'permissions': _permissionsJson(row['permissions']),
          };
          var landed = false;
          for (var attempt = 1; attempt <= 2 && !landed; attempt++) {
            try {
              await txn.update(
                'users',
                values,
                where: 'id = ?',
                whereArgs: [demo],
              );
              landed = true;
              if (attempt > 1) {
                AppLogger.info(
                  'Demo credential adopted on retry $attempt (local $demo).',
                );
              }
            } catch (error) {
              AppLogger.warn(
                'Demo credential for $demo failed on attempt $attempt/2: '
                '$error',
              );
            }
          }
          if (!landed) {
            AppLogger.error(
              'Demo credential for $demo (cloud $id) did not land: the '
              'browser password will not open the demo on this till.',
            );
          }
          continue;
        }
      }

      if (await _exists(txn, 'users', id)) {
        // A credential created, reset or rotated in the browser has to land or
        // the account can only sign in on the web. Only the cloud pair is
        // written: the local pair may hold a newer password set on this PC.
        await _refreshUserState(txn, id, row, credential);
        continue;
      }

      var username = _str(row['username']) ?? '';
      // The login name IS the person: usernames are phone numbers and unique per
      // shop on both surfaces. A till registered the shop and the browser
      // registered it too, so the same human exists twice — once per surface,
      // under two ids. Inserting the cloud copy here would show the owner two
      // owner accounts on the Users screen and split the cashier's history.
      // Adopt it onto the account already here instead: the id stays this
      // device's own, and only what the cloud owns (the credential, the role,
      // the ticks, whether it may sign in at all) is refreshed onto it.
      if (username.isNotEmpty) {
        final twin = await _twinForUsername(txn, username);
        if (twin != null) {
          await _refreshUserState(txn, twin, row, credential);
          continue;
        }
      } else {
        username = 'user-$id';
      }

      final permissions = row['permissions'];

      created += await _insert(txn, 'users', {
        'id': id,
        'username': username,
        'password_hash': cloudAccountMarker,
        'salt': '',
        'cloud_pw_hash': hasCredential ? hash : null,
        'cloud_pw_salt': hasCredential ? salt : null,
        'role': _str(row['role']) ?? 'CASHIER',
        'is_active': row['active'] == false ? 0 : 1,
        // jsonb arrives as a decoded list; a text column arrives as the JSON
        // text itself. Both have to land as the local TEXT form.
        'permissions': _permissionsJson(permissions),
        'is_demo': row['is_demo'] == true ? 1 : 0,
        'deleted_at': _localIso(row['deleted_at']),
        'created_at': _localIso(row['created_at']) ?? _nowIso(),
      });
    }
    return created;
  }

  /// Applies the parts of an account the cloud owns onto a row that is already
  /// here: the credential, the role, the feature ticks, whether it may sign in
  /// at all, and whether it was deleted.
  ///
  /// A till now uploads the accounts it created, so this is the merge half of
  /// that: an edit made in the browser (revoke, retick, reset password) has to
  /// reach every register, or a cashier switched off on the web could still sign
  /// in on a till that had already pulled them, forever.
  Future<void> _refreshUserState(
    Transaction txn,
    String id,
    Map<String, dynamic> row,
    Map<String, Object?> credential,
  ) async {
    final isDemo = row['is_demo'] == true;
    final role = _str(row['role']);
    final values = <String, Object?>{
      ...credential,
      // The training account keeps its role and can never be switched off;
      // everything else follows the cloud.
      if (!isDemo && role != null) 'role': role,
      if (!isDemo) 'is_active': row['active'] == false ? 0 : 1,
      if (!isDemo) 'deleted_at': _localIso(row['deleted_at']),
      'permissions': _permissionsJson(row['permissions']),
    };
    await _safely(txn, () async {
      await txn.update('users', values, where: 'id = ?', whereArgs: [id]);
    });
  }

  /// jsonb arrives as a decoded list, a text column as the JSON text itself.
  static String _permissionsJson(Object? value) {
    if (value is String) return value.isEmpty ? '[]' : value;
    return jsonEncode(value is List ? value : const <String>[]);
  }

  /// The account this till already treats as the training login: the flagged
  /// row, else one that signs in as `demo`. [excludeId] is the incoming cloud
  /// row, which by definition is not the local one yet.
  Future<String?> _localDemo(Transaction txn, String excludeId) async {
    final rows = await txn.query(
      'users',
      columns: const ['id'],
      where:
          'deleted_at IS NULL AND (is_demo = 1 OR LOWER(username) = ?) '
          'AND id <> ?',
      whereArgs: ['demo', excludeId],
      orderBy: 'is_demo DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  /// Another till's device id has to resolve for the sale's foreign key even
  /// though this PC knows nothing else about it.
  Future<int> _ensureDevices(
    Transaction txn,
    Map<String, List<Map<String, dynamic>>> changes,
  ) async {
    final ids = <String>{};
    for (final row in changes['sales'] ?? const <Map<String, dynamic>>[]) {
      final id = _str(row['device_id']);
      if (id != null && id.isNotEmpty) ids.add(id);
    }
    for (final row in changes['shifts'] ?? const <Map<String, dynamic>>[]) {
      final id = _str(row['device_id']);
      if (id != null && id.isNotEmpty) ids.add(id);
    }

    var created = 0;
    for (final id in ids) {
      if (await _exists(txn, 'devices', id)) continue;
      created += await _insert(txn, 'devices', {
        'id': id,
        'name': 'Device ${_short(id, 8)}',
        'platform': 'cloud',
        'license_key': null,
        'last_sync_at': null,
      });
    }
    return created;
  }

  /// The device a pulled sale names, created on demand. A sale's `device_id` is
  /// NOT NULL and references `devices`, so a register this PC has never talked
  /// to would otherwise cost the whole sale.
  Future<String> _ensureDevice(Transaction txn, Object? rawId) async {
    final id = _str(rawId) ?? unknownDeviceId;
    if (await _exists(txn, 'devices', id)) return id;
    await _insert(txn, 'devices', {
      'id': id,
      'name': id == unknownDeviceId
          ? 'Unknown register'
          : 'Device ${_short(id, 8)}',
      'platform': 'cloud',
      'license_key': null,
      'last_sync_at': null,
    });
    return id;
  }

  /// The cashier a pulled row names, created on demand. Accounts are uploaded
  /// now, but a sale recorded before this till ever saw the cashier still has to
  /// land here, and `sales.cashier_id` is a NOT NULL foreign key.
  ///
  /// The placeholder is inactive and soft-deleted on purpose: it resolves the
  /// foreign key and names the cashier in history, but it can never sign in and
  /// never shows up in the Users screen. It is replaced by the real row the
  /// moment the cloud ever publishes that id ([_refreshUserState] clears
  /// `deleted_at` and the flags).
  Future<String> _ensureUser(Transaction txn, Object? rawId) async {
    final id = _str(rawId) ?? unknownUserId;
    if (await _exists(txn, 'users', id)) return id;
    var username = id == unknownUserId
        ? 'cashier-unknown'
        : 'cashier-${_short(id, 8)}';
    if (await _twinForUsername(txn, username) != null) {
      username = '$username-${DateTime.now().microsecondsSinceEpoch}';
    }
    await _insert(txn, 'users', {
      'id': id,
      'username': username,
      'password_hash': cloudAccountMarker,
      'salt': '',
      'role': 'CASHIER',
      'is_active': 0,
      'permissions': '[]',
      'is_demo': 0,
      'deleted_at': _nowIso(),
      'created_at': _nowIso(),
    });
    return id;
  }

  /// The drawer a pulled row names. `sales.shift_id` and
  /// `cash_movements.shift_id` are NOT NULL foreign keys, and the cloud creates
  /// a shift on demand when it applies a push — so a sale can arrive one page
  /// before the shift it belongs to. A closed, zero-cash container is enough to
  /// keep the history: drawing cash is this register's own business.
  Future<String> _ensureShift(Transaction txn, Object? rawId) async {
    final id = _str(rawId) ?? unknownShiftId;
    if (await _exists(txn, 'shifts', id)) return id;
    await _insert(txn, 'shifts', {
      'id': id,
      'cashier_id': '',
      'opening_cash_minor_units': 0,
      'closing_cash_minor_units': null,
      'expected_cash_minor_units': null,
      'status': 'CLOSED',
      'opened_at': _nowIso(),
      'closed_at': _nowIso(),
    });
    return id;
  }

  // ---------------------------------------------------------------------------
  // Business rows.
  // ---------------------------------------------------------------------------

  Future<int> _applyShifts(
    Transaction txn,
    List<Map<String, dynamic>> rows,
  ) async {
    var created = 0;
    for (final row in rows) {
      final id = _str(row['id']);
      if (id == null || id.isEmpty) continue;
      if (await _exists(txn, 'shifts', id)) {
        await _refreshShiftState(txn, id, row);
        continue;
      }
      final values = <String, Object?>{
        'id': id,
        'cashier_id': await _ensureUser(txn, row['cashier_id']),
        'opening_cash_minor_units': _int(row['opening_cash_minor_units']),
        'closing_cash_minor_units': _nullableInt(
          row['closing_cash_minor_units'],
        ),
        'expected_cash_minor_units': _nullableInt(
          row['expected_cash_minor_units'],
        ),
        'status': _str(row['status']) ?? 'CLOSED',
        'opened_at': _localIso(row['opened_at']) ?? _nowIso(),
        'closed_at': _localIso(row['closed_at']),
      };
      _closeOut(values);
      if (values['status'] == 'OPEN') {
        // Fresh-install merge: a device that joined the shop starts with an
        // empty local OPEN shift while the real drawer lives in the cloud. The
        // `one_open_shift` index (and the insert trigger) allow exactly one OPEN
        // row, so the pulled cloud shift could not land alongside it. Keeping
        // the empty local shift open and the cloud shift closed left all pulled
        // sales on the closed row while the register read the empty open one —
        // a zero balance. Merge instead: move everything that referenced the
        // local shift onto the cloud shift, delete the empty local shift, then
        // insert the cloud shift as the one true OPEN drawer.
        final localOpen = await txn.query(
          'shifts',
          columns: const ['id'],
          where: "status = 'OPEN' AND id <> ?",
          whereArgs: [id],
          limit: 1,
        );
        if (localOpen.isNotEmpty) {
          final localId = localOpen.first['id'] as String;
          // Insert the cloud shift as CLOSED first so FK targets exist while
          // local OPEN is still present (the one_open_shift constraint allows
          // any number of CLOSED rows alongside the single OPEN row).
          final closedValues = Map<String, Object?>.from(values)
            ..['status'] = 'CLOSED';
          _closeOut(closedValues);
          await txn.insert('shifts', closedValues);
          await txn.update(
            'sales',
            {'shift_id': id},
            where: 'shift_id = ?',
            whereArgs: [localId],
          );
          await txn.update(
            'sales',
            {'voided_shift_id': id},
            where: 'voided_shift_id = ?',
            whereArgs: [localId],
          );
          await txn.update(
            'cash_movements',
            {'shift_id': id},
            where: 'shift_id = ?',
            whereArgs: [localId],
          );
          await txn.delete('shifts', where: 'id = ?', whereArgs: [localId]);
          // Re-open the merged cloud shift; the trigger permits this because
          // no other OPEN shift remains.
          await txn.update(
            'shifts',
            {
              'status': 'OPEN',
              'closing_cash_minor_units': values['closing_cash_minor_units'],
              'expected_cash_minor_units': values['expected_cash_minor_units'],
              'closed_at': values['closed_at'],
            },
            where: 'id = ?',
            whereArgs: [id],
          );
          created++;
          continue;
        }
      }
      var inserted = await _insert(txn, 'shifts', values);
      if (inserted == 0 && values['status'] == 'OPEN') {
        // This register already has its OWN open drawer (the local trigger
        // allows exactly one). Another till's open shift still has to exist
        // here or every sale it recorded fails its foreign key, so it is kept
        // as a closed historical container. The local drawer state is the
        // register's own business; this row is only a parent for old sales.
        values['status'] = 'CLOSED';
        _closeOut(values);
        inserted = await _insert(txn, 'shifts', values);
      }
      created += inserted;
    }
    return created;
  }

  /// Makes a `CLOSED` row self-consistent before it is written.
  ///
  /// The cloud can send a shift that is closed but carries no closing count —
  /// a till that closed while its outbox row had no figure, or the OPEN-to-
  /// CLOSED fallback in [_applyShifts], which reuses a row that never had one.
  /// Every drawer report sums that column, so a null silently drops the whole
  /// session out of the totals: fall back to the expected figure, then zero.
  /// `closed_at` gets the same treatment, because a closed shift with no close
  /// time is missing from every date-ranged report.
  void _closeOut(Map<String, Object?> values) {
    if (values['status'] != 'CLOSED') return;
    values['closing_cash_minor_units'] ??=
        values['expected_cash_minor_units'] ?? 0;
    values['closed_at'] ??= _nowIso();
  }

  /// A drawer closed elsewhere has to close here too.
  ///
  /// The local `one_open_shift` index allows exactly one OPEN row for the whole
  /// database, so a shift this till pulled while it was OPEN and never learned
  /// was closed is not cosmetic — `ShiftRepository.openShift` refuses to start
  /// another drawer while it sits there, and the register is locked out of
  /// ringing up anything at all.
  ///
  /// One-way on purpose: only `CLOSED` is taken from the cloud, and only onto a
  /// row this device still has open, so a stale page can never reopen a drawer
  /// or rewrite the figures this register counted for its own session.
  Future<void> _refreshShiftState(
    Transaction txn,
    String id,
    Map<String, dynamic> row,
  ) async {
    if (_str(row['status']) != 'CLOSED') return;
    if (await _hasPending(txn, 'shift', id)) return;
    final closing = _nullableInt(row['closing_cash_minor_units']);
    final expected = _nullableInt(row['expected_cash_minor_units']);
    await _safely(txn, () async {
      await txn.update(
        'shifts',
        {
          'status': 'CLOSED',
          // Only take the cloud's figures when it actually sent them: this
          // register counted its own drawer, and a page whose closing count is
          // null must not wipe that count out of the day's totals.
          'closing_cash_minor_units': ?closing,
          'expected_cash_minor_units': ?expected,
          'closed_at': _localIso(row['closed_at']) ?? _nowIso(),
        },
        where: "id = ? AND status = 'OPEN'",
        whereArgs: [id],
      );
    });
  }

  /// True while this device still holds an unacked write for the entity, whose
  /// local copy is newer than anything the server can send back.
  Future<bool> _hasPending(
    Transaction txn,
    String entityType,
    String entityId,
  ) async {
    final pending = await txn.query(
      'sync_outbox',
      columns: const ['id'],
      where: 'entity_type = ? AND entity_id = ? AND synced_at IS NULL',
      whereArgs: [entityType, entityId],
      limit: 1,
    );
    return pending.isNotEmpty;
  }

  /// Returns `(inserted, skippedByLocalUniqueIndex)`.
  Future<(int, int)> _applySales(
    Transaction txn,
    List<Map<String, dynamic>> rows,
  ) async {
    var created = 0;
    var skipped = 0;
    for (final row in rows) {
      final id = _str(row['id']);
      if (id == null || id.isEmpty) continue;

      if (await _exists(txn, 'sales', id)) {
        await _refreshVoidState(txn, id, row);
        continue;
      }

      // Order matters: `users` is never uploaded from a till, and the cloud
      // mints the shift when it applies a push, so either parent can be
      // unknown here. All three columns are NOT NULL foreign keys — resolving
      // them first is the difference between "the sale is on this device" and
      // the insert being refused and the sale vanishing without a trace.
      final cashierId = await _ensureUser(txn, row['cashier_id']);
      final shiftId = await _ensureShift(txn, row['shift_id']);
      final deviceId = await _ensureDevice(txn, row['device_id']);

      final inserted = await _insert(txn, 'sales', {
        'id': id,
        // Receipt numbers are allocated per till and are internal identifiers
        // (never shown in sales history), so two registers legitimately issue
        // the same one. The local column is UNIQUE, so the pulled copy is
        // namespaced instead of being dropped — losing the transaction would
        // defeat the whole point of the pull.
        'receipt_number': await _receiptFor(
          txn,
          _str(row['receipt_number']) ?? id,
          deviceId.isNotEmpty ? deviceId : id,
        ),
        'cashier_id': cashierId,
        'device_id': deviceId,
        'shift_id': shiftId,
        'customer_name': _str(row['customer_name']),
        'payment_method': _str(row['payment_method']) ?? 'CASH',
        'subtotal_minor_units': _int(row['subtotal_minor_units']),
        'discount_minor_units': _int(row['discount_minor_units']),
        'total_minor_units': _int(row['total_minor_units']),
        'amount_paid_minor_units': _int(row['amount_paid_minor_units']),
        'change_minor_units': _int(row['change_minor_units']),
        'status': _str(row['status']) ?? 'COMPLETED',
        'void_reason': _str(row['void_reason']),
        'voided_at': _localIso(row['voided_at']),
        'voided_by': _str(row['voided_by']),
        'voided_shift_id': _str(row['voided_shift_id']),
        'created_at': _localIso(row['created_at']) ?? _nowIso(),
        // It came from the cloud, so it is by definition already synced.
        'synced_at': _nowIso(),
      });
      if (inserted == 1) {
        created++;
      } else {
        skipped++;
      }
    }
    return (created, skipped);
  }

  /// A void approved by the owner on another device must show as void here.
  /// Skipped while this device still holds an unacked write for the same sale:
  /// the local intent has not reached the server yet, so the server's copy is
  /// the older one.
  ///
  /// One-way: only `VOIDED` is taken from the cloud. A sale is never un-voided
  /// server-side, so applying a stale `COMPLETED` page would put a voided sale
  /// back into this register's takings — the money would silently reappear.
  Future<void> _refreshVoidState(
    Transaction txn,
    String saleId,
    Map<String, dynamic> row,
  ) async {
    if (_str(row['status']) != 'VOIDED') return;
    if (await _hasPending(txn, 'sale', saleId)) return;

    await _safely(txn, () async {
      await txn.update(
        'sales',
        {
          'status': _str(row['status']) ?? 'COMPLETED',
          'void_reason': _str(row['void_reason']),
          'voided_at': _localIso(row['voided_at']),
          'voided_by': _str(row['voided_by']),
          'voided_shift_id': _str(row['voided_shift_id']),
        },
        where: 'id = ?',
        whereArgs: [saleId],
      );
    });
  }

  /// Returns `(inserted, skipped)`. A line whose sale is not here yet is
  /// counted, not guessed at: inserting it against a missing parent would be
  /// refused, and inventing a sale would invent money.
  Future<(int, int)> _applySaleItems(
    Transaction txn,
    List<Map<String, dynamic>> rows,
  ) async {
    var created = 0;
    var skipped = 0;
    for (final row in rows) {
      final id = _str(row['id']);
      if (id == null || id.isEmpty) continue;
      if (await _exists(txn, 'sale_items', id)) continue;
      final saleId = _str(row['sale_id']);
      if (saleId == null || !await _exists(txn, 'sales', saleId)) {
        // The parent has not landed (a backlogged `sales` walk, or a sale the
        // cloud rejected). Nothing to attach to.
        skipped++;
        continue;
      }
      created += await _insert(txn, 'sale_items', {
        'id': id,
        'sale_id': saleId,
        'product_id': _str(row['product_id']) ?? '',
        'product_name_snapshot': _str(row['product_name_snapshot']) ?? '',
        'unit_price_snapshot_minor_units': _int(
          row['unit_price_snapshot_minor_units'],
        ),
        'quantity_text': _str(row['quantity_text']) ?? '1',
        'billing_quantity_milliunits': _nullableInt(
          row['billing_quantity_milliunits'],
        ),
        'line_discount_minor_units': _int(row['line_discount_minor_units']),
        'line_total_minor_units': _int(row['line_total_minor_units']),
        'notes': _str(row['notes']),
      });
    }
    return (created, skipped);
  }

  Future<int> _applyCashMovements(
    Transaction txn,
    List<Map<String, dynamic>> rows,
  ) async {
    var created = 0;
    for (final row in rows) {
      final id = _str(row['id']);
      if (id == null || id.isEmpty) continue;
      if (await _exists(txn, 'cash_movements', id)) continue;
      // One collection, one deposit — on this device too. A till that completed
      // the entry itself already wrote the movement under its own id, and the
      // cloud row for the same collection would otherwise land beside it as a
      // second line in the register. The entry id is the only key that survives
      // the two paths choosing different uuids.
      final sourceEntry = _str(row['source_finance_entry_id']);
      if (sourceEntry != null && sourceEntry.isNotEmpty) {
        final already = await txn.query(
          'cash_movements',
          columns: ['id'],
          where: 'source_finance_entry_id = ?',
          whereArgs: [sourceEntry],
          limit: 1,
        );
        if (already.isNotEmpty) continue;
      }
      // Same NOT NULL foreign keys as a sale: the drawer it belongs to and the
      // person who moved the cash.
      final shiftId = await _ensureShift(txn, row['shift_id']);
      final userId = _str(row['user_id']);
      if (userId != null) await _ensureUser(txn, userId);
      final createdAt = _localIso(row['created_at']) ?? _nowIso();
      created += await _insert(txn, 'cash_movements', {
        'id': id,
        'shift_id': shiftId,
        'type': _str(row['type']) ?? 'CREDIT',
        'amount_minor_units': _int(row['amount_minor_units']),
        'reason': _str(row['reason']),
        'created_at': createdAt,
        'user_id': userId,
        'source_finance_entry_id': sourceEntry,
      });
      // A push never carries the photo (it is stripped from the outbox
      // payload), but an older cloud row may still hold the base64 copy. Keep
      // it as a BLOB in the schema-16 table instead of the dead TEXT column.
      final photo = _str(row['photo']);
      if (photo != null && photo.isNotEmpty && photo.length <= 200 * 1024) {
        try {
          await txn.insert('cash_movement_photos', {
            'movement_id': id,
            'jpeg_bytes': base64Decode(photo),
            'created_at': createdAt,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        } catch (_) {
          // A corrupt pulled photo must not fail the whole page.
        }
      }
    }
    return created;
  }

  Future<int> _applyVoidRequests(
    Transaction txn,
    List<Map<String, dynamic>> rows,
  ) async {
    var created = 0;
    for (final row in rows) {
      final id = _str(row['id']);
      if (id == null || id.isEmpty) continue;
      if (await _exists(txn, 'void_requests', id)) {
        await _refreshVoidRequestState(txn, id, row);
        continue;
      }
      final saleId = _str(row['sale_id']);
      if (saleId == null || !await _exists(txn, 'sales', saleId)) continue;
      final requestedBy = await _ensureUser(txn, row['requested_by']);
      final decidedBy = _str(row['decided_by']);
      if (decidedBy != null) await _ensureUser(txn, decidedBy);
      created += await _insert(txn, 'void_requests', {
        'id': id,
        'sale_id': saleId,
        'requested_by': requestedBy,
        'reason': _str(row['reason']) ?? '',
        'status': _str(row['status']) ?? 'PENDING',
        'created_at': _localIso(row['created_at']) ?? _nowIso(),
        'decided_by': decidedBy,
        'decided_at': _localIso(row['decided_at']),
      });
    }
    return created;
  }

  /// A void request decided in the browser has to stop showing as pending on
  /// every till, or the cashier keeps asking the owner about a decision that was
  /// already made. One-way (PENDING → decided) for the same reason a void is
  /// never undone.
  Future<void> _refreshVoidRequestState(
    Transaction txn,
    String id,
    Map<String, dynamic> row,
  ) async {
    final status = _str(row['status']);
    if (status == null || status == 'PENDING') return;
    if (await _hasPending(txn, 'void_request', id)) return;
    final decidedBy = _str(row['decided_by']);
    if (decidedBy != null) await _ensureUser(txn, decidedBy);
    await _safely(txn, () async {
      await txn.update(
        'void_requests',
        {
          'status': status,
          'decided_by': decidedBy,
          'decided_at': _localIso(row['decided_at']) ?? _nowIso(),
        },
        where: "id = ? AND status = 'PENDING'",
        whereArgs: [id],
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Master data: mutable rows, applied newest-wins.
  //
  // The ledger rule ("a local row is never overwritten") exists because a sale
  // is immutable money and a stale page must not restate it. A saved name, a
  // person or a collection is the opposite: the shop edits them from whichever
  // screen is nearest, so the copy that is simply older is the one that loses.
  // `updated_at` decides, and an entity this device has not finished uploading
  // is left alone — its own edit is the newer one.
  // ---------------------------------------------------------------------------

  Future<int> _applyProducts(
    Transaction txn,
    List<Map<String, dynamic>> rows,
  ) async {
    var count = 0;
    for (final row in rows) {
      final id = _str(row['id']);
      if (id == null || id.isEmpty) continue;
      final name = _str(row['name']);
      if (name == null || name.isEmpty) continue;

      // `products.code` is NOT NULL and UNIQUE here, while the browser leaves
      // a saved name without a barcode. The id is a stable stand-in: unique by
      // construction. A code that another product here already claims moves to
      // the same stand-in, or the UNIQUE index would refuse the whole row and
      // the name would keep its stale price.
      var code = _str(row['code']) ?? id;
      if (code != id && await _codeTaken(txn, code, id)) code = id;
      final values = <String, Object?>{
        'id': id,
        'name': name,
        'code': code,
        'category': _str(row['category']),
        'unit': _str(row['unit']) ?? '',
        'selling_price_minor_units': _int(row['selling_price_minor_units']),
        'is_active': row['is_active'] == 0 ? 0 : 1,
        'created_at': _localIso(row['created_at']) ?? _nowIso(),
        'updated_at': _localIso(row['updated_at']) ?? _nowIso(),
      };

      if (!await _exists(txn, 'products', id)) {
        count += await _insert(txn, 'products', values);
        continue;
      }
      if (await _hasPending(txn, 'product', id)) continue;
      final local = await txn.query(
        'products',
        columns: const ['updated_at'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (local.isEmpty ||
          !_outdated(local.first['updated_at'], values['updated_at'])) {
        continue;
      }
      await _safely(txn, () async {
        await txn.update('products', values, where: 'id = ?', whereArgs: [id]);
      });
      count++;
    }
    return count;
  }

  Future<int> _applyFinanceCategories(
    Transaction txn,
    List<Map<String, dynamic>> rows,
  ) async {
    var count = 0;
    for (final row in rows) {
      final id = _str(row['id']);
      if (id == null || id.isEmpty) continue;
      final name = _str(row['name']);
      if (name == null || name.isEmpty) continue;
      final values = <String, Object?>{
        'id': id,
        'name': name,
        'created_at': _localIso(row['created_at']) ?? _nowIso(),
        'updated_at': _localIso(row['updated_at']) ?? _nowIso(),
        'deleted_at': _localIso(row['deleted_at']),
      };

      if (!await _exists(txn, 'finance_categories', id)) {
        count += await _insert(txn, 'finance_categories', values);
        continue;
      }
      if (await _hasPending(txn, 'finance_category', id)) continue;
      final local = await txn.query(
        'finance_categories',
        columns: const ['updated_at'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (local.isEmpty ||
          !_outdated(local.first['updated_at'], values['updated_at'])) {
        continue;
      }
      await _safely(txn, () async {
        await txn.update(
          'finance_categories',
          values,
          where: 'id = ?',
          whereArgs: [id],
        );
      });
      count++;
    }
    return count;
  }

  Future<int> _applyFinanceEntries(
    Transaction txn,
    List<Map<String, dynamic>> rows,
  ) async {
    var count = 0;
    for (final row in rows) {
      final id = _str(row['id']);
      if (id == null || id.isEmpty) continue;
      // The person is a NOT NULL foreign key. `finance_categories` is walked
      // before this table and the puller stops a run at the first table that
      // did not finish, so a parent is never left behind — if one still is, the
      // entry is skipped rather than inventing a phantom person in the owner's
      // money list. It arrives on a later tick, once the person has.
      final categoryId = _str(row['category_id']);
      if (categoryId == null ||
          categoryId.isEmpty ||
          !await _exists(txn, 'finance_categories', categoryId)) {
        continue;
      }
      final createdBy = await _ensureUser(txn, row['created_by']);
      final completedBy = _str(row['completed_by']);
      if (completedBy != null) await _ensureUser(txn, completedBy);
      final values = <String, Object?>{
        'id': id,
        'category_id': categoryId,
        'source': _str(row['source']) ?? '',
        'amount_minor_units': _int(row['amount_minor_units']),
        'description': _str(row['description']),
        'status': _str(row['status']) ?? 'PENDING',
        'entry_date': _localIso(row['entry_date']) ?? _nowIso(),
        'created_at': _localIso(row['created_at']) ?? _nowIso(),
        'created_by': createdBy,
        'completed_at': _localIso(row['completed_at']),
        'completed_by': completedBy,
        'updated_at': _localIso(row['updated_at']) ?? _nowIso(),
        'payment_method': _str(row['payment_method']),
      };

      if (!await _exists(txn, 'finance_entries', id)) {
        count += await _insert(txn, 'finance_entries', values);
        continue;
      }
      if (await _hasPending(txn, 'finance_entry', id)) continue;
      final local = await txn.query(
        'finance_entries',
        columns: const ['updated_at', 'status'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (local.isEmpty ||
          !_outdated(local.first['updated_at'], values['updated_at'])) {
        continue;
      }
      await _safely(txn, () async {
        await txn.update(
          'finance_entries',
          values,
          where: 'id = ?',
          whereArgs: [id],
        );
      });
      count++;
    }
    return count;
  }

  // Warehouse Picklists: mutable master-style rows, applied newest-wins, exactly
  // like saved names and money persons. A picklist header and its items are
  // edited from whichever surface is nearest (a worker ticking stock), so the
  // copy that is simply older loses; `updated_at` decides, and an entity this
  // device has not finished uploading is left alone.

  Future<int> _applyPicklists(
    Transaction txn,
    List<Map<String, dynamic>> rows,
  ) async {
    var count = 0;
    for (final row in rows) {
      final id = _str(row['id']);
      if (id == null || id.isEmpty) continue;
      final customerName = _str(row['customer_name']);
      if (customerName == null || customerName.isEmpty) continue;
      final values = <String, Object?>{
        'id': id,
        'customer_name': customerName,
        'status': _str(row['status']) ?? 'PENDING',
        'created_by': _str(row['created_by']) ?? '',
        'created_at': _localIso(row['created_at']) ?? _nowIso(),
        'updated_at': _localIso(row['updated_at']) ?? _nowIso(),
        // Soft-delete tombstone: a list removed on any device leaves this row
        // in place so the deletion reaches every other device; reads filter it.
        'deleted_at': _localIso(row['deleted_at']),
      };

      if (!await _exists(txn, 'picklists', id)) {
        count += await _insert(txn, 'picklists', values);
        continue;
      }
      if (await _hasPending(txn, 'picklist', id)) continue;
      final local = await txn.query(
        'picklists',
        columns: const ['updated_at'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (local.isEmpty ||
          !_outdated(local.first['updated_at'], values['updated_at'])) {
        continue;
      }
      await _safely(txn, () async {
        await txn.update('picklists', values, where: 'id = ?', whereArgs: [id]);
      });
      count++;
    }
    return count;
  }

  Future<int> _applyPicklistItems(
    Transaction txn,
    List<Map<String, dynamic>> rows,
  ) async {
    var count = 0;
    for (final row in rows) {
      final id = _str(row['id']);
      if (id == null || id.isEmpty) continue;
      final productName = _str(row['product_name']);
      if (productName == null || productName.isEmpty) continue;
      // `picklist_id` is a NOT NULL foreign key. [CloudSyncPuller.tableOrder]
      // walks `picklists` before this table, so a parent the cloud published
      // has already landed; one that has not is skipped, not invented, and
      // arrives on a later tick once the header does.
      final picklistId = _str(row['picklist_id']);
      if (picklistId == null ||
          picklistId.isEmpty ||
          !await _exists(txn, 'picklists', picklistId)) {
        continue;
      }
      final values = <String, Object?>{
        'id': id,
        'picklist_id': picklistId,
        'product_name': productName,
        'requested_qty': _int(row['requested_qty']),
        'taken_qty': _int(row['taken_qty']),
        // Schema 21 pricing. These ride the cloud row and must land here too,
        // otherwise a list created in the PWA shows 0.00 Br on the till even
        // though the cloud has the price.
        'unit': _str(row['unit']),
        'unit_price_minor_units': _int(row['unit_price_minor_units']),
        'line_total_minor_units': _int(row['line_total_minor_units']),
        'updated_at': _localIso(row['updated_at']) ?? _nowIso(),
        // Tombstone for a line deleted on another device.
        'deleted_at': _localIso(row['deleted_at']),
      };

      if (!await _exists(txn, 'picklist_items', id)) {
        count += await _insert(txn, 'picklist_items', values);
        continue;
      }
      if (await _hasPending(txn, 'picklist_item', id)) continue;
      final local = await txn.query(
        'picklist_items',
        columns: const ['updated_at'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (local.isEmpty ||
          !_outdated(local.first['updated_at'], values['updated_at'])) {
        continue;
      }
      await _safely(txn, () async {
        await txn.update(
          'picklist_items',
          values,
          where: 'id = ?',
          whereArgs: [id],
        );
      });
      count++;
    }
    return count;
  }

  /// True when the row already here was last touched at or before [incoming],
  /// so the incoming copy is the newer one. Both sides are the local naive ISO
  /// form ([_localIso] has already converted the cloud's `timestamptz`), which
  /// sorts as text.
  static bool _outdated(Object? local, Object? incoming) {
    if (incoming == null) return false;
    final here = '$local';
    if (here.isEmpty) return true;
    return here.compareTo('$incoming') <= 0;
  }

  Future<bool> _codeTaken(Transaction txn, String code, String id) async {
    final rows = await txn.query(
      'products',
      columns: const ['id'],
      where: 'code = ? AND id <> ?',
      whereArgs: [code, id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // ---------------------------------------------------------------------------
  // Helpers.
  // ---------------------------------------------------------------------------

  Future<bool> _exists(Transaction txn, String table, String id) async {
    final rows = await txn.query(
      table,
      columns: const ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Returns [receipt] unchanged when this till has not used it, otherwise a
  /// device/id-tagged variant that is guaranteed to be free. A receipt number
  /// is internal (sales history searches never match on it), so a rename is
  /// invisible to the operator and far preferable to dropping a sale.
  Future<String> _receiptFor(
    Transaction txn,
    String receipt,
    String tagSource,
  ) async {
    if (!await _receiptTaken(txn, receipt)) return receipt;
    final tag = _short(tagSource, 8);
    final tagged = '$receipt#$tag';
    if (!await _receiptTaken(txn, tagged)) return tagged;
    return '$receipt#$tag-${DateTime.now().microsecondsSinceEpoch}';
  }

  Future<bool> _receiptTaken(Transaction txn, String receipt) async {
    final rows = await txn.query(
      'sales',
      columns: const ['id'],
      where: 'receipt_number = ?',
      whereArgs: [receipt],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// The live-or-binned account already using this login, under a different id.
  Future<String?> _twinForUsername(Transaction txn, String username) async {
    final rows = await txn.query(
      'users',
      columns: const ['id'],
      where: 'username = ?',
      whereArgs: [username],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  /// Inserts one row, returning 1 when it landed and 0 when a unique index
  /// refused it (skipped instead of aborting the whole page).
  Future<int> _insert(
    Transaction txn,
    String table,
    Map<String, Object?> values,
  ) async {
    var ok = 0;
    await _safely(txn, () async {
      await txn.insert(table, values);
      ok = 1;
    });
    return ok;
  }

  Future<void> _safely(Transaction txn, Future<void> Function() body) async {
    try {
      await body();
    } on DatabaseException {
      // A conflict the local schema owns: duplicate receipt number, a second
      // OPEN shift, an orphaned foreign key. Counted by the caller, never
      // fatal — the rest of the page still has to arrive.
    }
  }

  static String _nowIso() => DateTime.now().toIso8601String();

  static String _short(String value, int length) =>
      value.length <= length ? value : value.substring(0, length);

  /// Cloud `timestamptz` → the local convention (local time, no zone suffix),
  /// so date-range filters keep comparing like with like.
  static String? _localIso(Object? value) {
    if (value == null) return null;
    final raw = '$value'.trim();
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    return parsed.toLocal().toIso8601String();
  }

  static String? _str(Object? value) {
    if (value == null) return null;
    final text = '$value';
    return text.isEmpty ? null : text;
  }

  static int _int(Object? value) => _nullableInt(value) ?? 0;

  static int? _nullableInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }
}

/// Drives a pull from start to finish: read the stored cursor, page through the
/// backend, apply each page, persist the cursor after every page.
///
/// Paging matters even for a young shop: the gateway caps a page at `limit`
/// rows per table, and a first sync of a year of trading is far more than one.
/// Persisting the cursor per page means a crash or a closed laptop resumes
/// where it stopped instead of re-reading everything.
class CloudSyncPuller {
  /// Cloud tables in dependency order: a parent row must exist before anything
  /// that points at it, so users land first and void requests last.
  static const List<String> tableOrder = [
    'users',
    'products',
    'picklists',
    'picklist_items',
    'shifts',
    'sales',
    'sale_items',
    'cash_movements',
    'void_requests',
    'finance_categories',
    'finance_entries',
  ];

  /// Prefix of the settings key holding one table's last committed cursor.
  static const String cursorSettingKey = 'sync_cursor';

  /// One-time flag for the picklist-pricing repair below. Bump the suffix if a
  /// future column needs the same re-read.
  static const String _picklistPriceBackfillKey =
      'sync_backfill.picklist_item_prices.v1';

  /// Ceiling per run, per table, so one enormous backlog cannot pin the till on
  /// the network. The next tick continues from the stored cursor.
  static const int maxPagesPerRun = 20;

  final SyncBackend backend;
  final Database db;

  const CloudSyncPuller({required this.backend, required this.db});

  static String cursorKeyFor(String table) => '$cursorSettingKey.$table';

  Future<SyncApplyReport> pullNow({int pageSize = 1000}) async {
    if (!backend.isConfigured) return SyncApplyReport.empty;

    await _backfillPicklistPrices();

    // One table at a time. A keyset cursor only orders rows within a single
    // table, so paging them together would let a busy table push the cursor
    // past rows a quieter one has not delivered yet — silently losing sales.
    //
    // Dependency order is also a stop condition: `sale_items` cannot be
    // attached to a sale that is still queued behind [maxPagesPerRun] pages of
    // `sales`, and `cash_movements` / `void_requests` need the same parents.
    // When a table runs out of pages this run, the walk stops there and the
    // next tick resumes it, rather than pulling children into a gap.
    var total = SyncApplyReport.empty;
    for (final table in tableOrder) {
      final (report, complete) = await _pullTable(table, pageSize);
      total = total + report;
      if (!complete) break;
    }
    return total;
  }

  /// Returns `(applied, exhaustedTheTable)`. `false` means the table still had
  /// pages left when the per-run ceiling was reached.
  Future<(SyncApplyReport, bool)> _pullTable(String table, int pageSize) async {
    final applier = SyncPullApplier(db);
    var cursor = await _readCursor(table);
    var applied = SyncApplyReport.empty;

    for (var page = 0; page < maxPagesPerRun; page++) {
      final result = await backend.pull(
        cursor: cursor,
        limit: pageSize,
        tables: [table],
      );
      if (!result.isEmpty) {
        applied = applied + await applier.apply(result);
      }

      final next = result.nextCursor;
      // Without a new cursor the loop would re-read the same page forever.
      if (next == null) return (applied, true);
      cursor = next;
      await _writeCursor(table, next);
      if (!result.hasMore) return (applied, true);
    }
    return (applied, false);
  }

  /// Older builds pulled `picklist_items` without copying the schema-21 price
  /// columns, so lines created in the PWA landed here with 0.00 Br. The cursor
  /// has already moved past those rows, so the corrected applier would never
  /// see them again. Clear that one cursor once: the next pull re-reads every
  /// picklist line, and the newest-wins update backfills the price in place.
  /// A fresh install has no cursor, so this is a no-op beyond setting the flag.
  Future<void> _backfillPicklistPrices() async {
    final seen = await db.query(
      'settings',
      columns: const ['key'],
      where: 'key = ?',
      whereArgs: const [_picklistPriceBackfillKey],
      limit: 1,
    );
    if (seen.isNotEmpty) return;
    await db.delete(
      'settings',
      where: 'key = ?',
      whereArgs: [cursorKeyFor('picklist_items')],
    );
    await db.insert('settings', {
      'key': _picklistPriceBackfillKey,
      'value': '1',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, String>?> _readCursor(String table) async {
    final rows = await db.query(
      'settings',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [cursorKeyFor(table)],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['value'];
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map &&
          decoded['received_at'] != null &&
          decoded['id'] != null) {
        return {
          'received_at': '${decoded['received_at']}',
          'id': '${decoded['id']}',
        };
      }
    } on FormatException {
      // A corrupt cursor costs one full re-read; it can never lose data,
      // because applying a known row is a no-op.
    }
    return null;
  }

  Future<void> _writeCursor(String table, Map<String, String> cursor) async {
    await db.insert('settings', {
      'key': cursorKeyFor(table),
      'value': jsonEncode(cursor),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
