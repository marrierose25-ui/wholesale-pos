import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../repositories/user_repository.dart';
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
  final int skipped;

  const SyncApplyReport({
    this.sales = 0,
    this.saleItems = 0,
    this.shifts = 0,
    this.cashMovements = 0,
    this.voidRequests = 0,
    this.users = 0,
    this.devices = 0,
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
      devices;

  SyncApplyReport operator +(SyncApplyReport other) => SyncApplyReport(
    sales: sales + other.sales,
    saleItems: saleItems + other.saleItems,
    shifts: shifts + other.shifts,
    cashMovements: cashMovements + other.cashMovements,
    voidRequests: voidRequests + other.voidRequests,
    users: users + other.users,
    devices: devices + other.devices,
    skipped: skipped + other.skipped,
  );

  bool get isEmpty => inserted == 0 && skipped == 0;

  @override
  String toString() =>
      'SyncApplyReport(sales: $sales, items: $saleItems, shifts: $shifts, '
      'cash: $cashMovements, voids: $voidRequests, users: $users, '
      'devices: $devices, skipped: $skipped)';
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
        skipped = 0;

    await db.transaction((txn) async {
      users = await _applyUsers(txn, page.changes['users'] ?? const []);
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
          await _safely(txn, () async {
            await txn.update(
              'users',
              {
                ...credential,
                'is_demo': 1,
                // The ticks are the owner's training plan for this login, so
                // they follow the cloud even though the role cannot.
                'permissions': _permissionsJson(row['permissions']),
              },
              where: 'id = ?',
              whereArgs: [demo],
            );
          });
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
      if (username.isEmpty) username = 'user-$id';
      // `users.username` is UNIQUE and holds the login identifier (a phone
      // number). The same person may already exist on this device under a
      // different id, created here rather than in the cloud. Keep the local
      // account's login intact and make the pulled copy unambiguous.
      if (!await _usernameFree(txn, username)) {
        username = '$username#${_short(id, 6)}';
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
  /// A till never uploads `users`, so for an account that exists in both places
  /// the browser copy is the only one an owner can edit — the one place they
  /// revoke, retick or delete staff. Skipping these fields meant a cashier
  /// switched off in the browser could still sign in on every till that had
  /// already pulled them, forever.
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

  /// The cashier a pulled row names, created on demand. `users` is never
  /// uploaded from a till, so a cashier account created on another register
  /// exists only there — the sale still has to land here, with a row that can
  /// satisfy `sales.cashier_id`.
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
    if (!await _usernameFree(txn, username)) {
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
        'cashier_id': _str(row['cashier_id']) ?? '',
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
      var inserted = await _insert(txn, 'shifts', values);
      if (inserted == 0 && values['status'] == 'OPEN') {
        // This register already has its OWN open drawer (the local trigger
        // allows exactly one). Another till's open shift still has to exist
        // here or every sale it recorded fails its foreign key, so it is kept
        // as a closed historical container. The local drawer state is the
        // register's own business; this row is only a parent for old sales.
        values['status'] = 'CLOSED';
        inserted = await _insert(txn, 'shifts', values);
      }
      created += inserted;
    }
    return created;
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
    await _safely(txn, () async {
      await txn.update(
        'shifts',
        {
          'status': 'CLOSED',
          'closing_cash_minor_units': _nullableInt(
            row['closing_cash_minor_units'],
          ),
          'expected_cash_minor_units': _nullableInt(
            row['expected_cash_minor_units'],
          ),
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
      // Same NOT NULL foreign keys as a sale: the drawer it belongs to and the
      // person who moved the cash.
      final shiftId = await _ensureShift(txn, row['shift_id']);
      final userId = _str(row['user_id']);
      if (userId != null) await _ensureUser(txn, userId);
      created += await _insert(txn, 'cash_movements', {
        'id': id,
        'shift_id': shiftId,
        'type': _str(row['type']) ?? 'CREDIT',
        'amount_minor_units': _int(row['amount_minor_units']),
        'reason': _str(row['reason']),
        'created_at': _localIso(row['created_at']) ?? _nowIso(),
        'user_id': userId,
        'photo': _str(row['photo']),
      });
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

  Future<bool> _usernameFree(Transaction txn, String username) async {
    final rows = await txn.query(
      'users',
      columns: const ['id'],
      where: 'username = ?',
      whereArgs: [username],
      limit: 1,
    );
    return rows.isEmpty;
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
    'shifts',
    'sales',
    'sale_items',
    'cash_movements',
    'void_requests',
  ];

  /// Prefix of the settings key holding one table's last committed cursor.
  static const String cursorSettingKey = 'sync_cursor';

  /// Ceiling per run, per table, so one enormous backlog cannot pin the till on
  /// the network. The next tick continues from the stored cursor.
  static const int maxPagesPerRun = 20;

  final SyncBackend backend;
  final Database db;

  const CloudSyncPuller({required this.backend, required this.db});

  static String cursorKeyFor(String table) => '$cursorSettingKey.$table';

  Future<SyncApplyReport> pullNow({int pageSize = 1000}) async {
    if (!backend.isConfigured) return SyncApplyReport.empty;

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
