import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../features/sales/sale.dart';
import '../../features/sales/sale_item.dart';
import '../../features/sales/shift.dart';
import '../../features/sales/void_request.dart';
import '../sync/sync_outbox.dart';
import '../sync/sync_outbox_entry.dart';
import '../utils/date_range.dart';
import '../utils/money_utils.dart';
import '../utils/report_filters.dart';
import '../models/user.dart';
import 'shift_repository.dart';

/// Data-access contract for sales, voids, receipts, dashboards, reports and
/// audit history.
///
/// [SqfliteSaleRepository] is the local-first implementation; the cloud
/// implementation added in the PWA milestones honours the same contract so the
/// sales, dashboard and report screens stay storage-agnostic.
abstract class SaleRepository {
  factory SaleRepository(Database db) = SqfliteSaleRepository;

  /// Escapes LIKE wildcards so user search text matches literally.
  static String escapeLike(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
  }

  Future<void> saveSale(Sale sale);

  Future<String> nextReceiptNumber({String? userId});

  Future<void> voidSale(String saleId, String userId, String reason);

  Future<List<Sale>> getSales({
    String? userId,
    String? searchQuery,
    DateRange? period,
    String? status,
    int? limit,
  });

  Future<List<Sale>> getRecentSales({String? userId, int limit = 5});

  Future<List<Sale>> getVoidedSalesForShift(String shiftId, {String? userId});

  Future<void> requestVoid(String saleId, String userId, String reason);

  Future<List<VoidRequest>> getPendingVoidRequests({String? userId});

  Future<void> approveVoidRequest(String requestId, String ownerId);

  Future<void> rejectVoidRequest(String requestId, String ownerId);

  Future<List<Map<String, dynamic>>> getRevenueTrend(
    DateRange period, {
    String? userId,
  });

  Future<Map<String, int>> getDashboardStats({
    String? userId,
    DateRange? period,
  });

  Future<List<Map<String, dynamic>>> getAuditLogs({
    String? userId,
    int limit = 500,
  });

  Future<int> getTodayRevenue({String? userId});

  Future<List<Map<String, dynamic>>> getProductSalesSummary({
    String? userId,
    DateRange? period,
  });

  Future<List<Map<String, dynamic>>> getCashierPerformance({
    String? userId,
    DateRange? period,
  });
}

class SqfliteSaleRepository implements SaleRepository {
  final Database _db;

  SqfliteSaleRepository(this._db);

  /// Owner always passes; staff must hold [feature] (or one of [aliases]).
  static Future<void> _requireFeature(
    DatabaseExecutor executor,
    String? userId, {
    required String feature,
    List<String> aliases = const [],
  }) async {
    // No user identified (e.g. tests that predate this gate): skip the check.
    if (userId == null || userId.isEmpty) return;
    final rows = await executor.query(
      'users',
      columns: ['role', 'permissions'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw Exception('User not found.');
    }
    if (rows.first['role'] == 'OWNER') return;
    final held = User.decodePermissions(rows.first['permissions']);
    final allowed = <String>{...held, ...aliases};
    if (!allowed.contains(feature)) {
      throw Exception('This account does not have access to $feature.');
    }
  }

  @override
  Future<void> saveSale(Sale sale) async {
    await _db.transaction((txn) async {
      final shifts = await txn.query(
        'shifts',
        columns: ['id'],
        where: "id = ? AND status = 'OPEN'",
        whereArgs: [sale.shiftId],
        limit: 1,
      );
      if (shifts.isEmpty) {
        throw Exception('Sale requires an open register shift.');
      }
      if (sale.receiptNumber.trim().isEmpty ||
          sale.items.isEmpty ||
          sale.totalMinorUnits < 0 ||
          sale.subtotalMinorUnits < 0 ||
          sale.discountMinorUnits < 0 ||
          sale.totalMinorUnits !=
              sale.subtotalMinorUnits - sale.discountMinorUnits ||
          !{'CASH', 'BANK', 'LOAN'}.contains(sale.paymentMethod)) {
        throw Exception('Sale contains invalid totals or payment method.');
      }
      var itemSubtotal = 0;
      for (final item in sale.items) {
        _validateLineItem(item);
        itemSubtotal += item.lineTotalMinorUnits;
      }
      if (itemSubtotal != sale.subtotalMinorUnits ||
          (sale.paymentMethod == 'CASH' &&
              (sale.amountPaidMinorUnits < sale.totalMinorUnits ||
                  sale.changeMinorUnits !=
                      sale.amountPaidMinorUnits - sale.totalMinorUnits)) ||
          // BANK and LOAN both settle for exactly the total: no cash was
          // tendered at the till (a loan is money owed, not money collected).
          (sale.paymentMethod != 'CASH' &&
              (sale.amountPaidMinorUnits != sale.totalMinorUnits ||
                  sale.changeMinorUnits != 0))) {
        throw Exception('Sale totals do not match the line items or payment.');
      }
      await txn.insert('sales', sale.toMap());

      for (final item in sale.items) {
        await txn.insert('sale_items', item.toMap());
      }

      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': sale.cashierId,
        'action': 'SALE_COMPLETED',
        'details':
            'Total: ${MoneyUtils.formatBr(sale.totalMinorUnits)}, '
            'Lines: ${sale.items.length}',
        'created_at': DateTime.now().toIso8601String(),
      });
      await _enqueueSale(txn, sale.id);
    });
  }

  /// A line item is valid when either
  /// (a) it has a numeric billing quantity and its total is exactly
  ///     price x quantity minus the line discount, or
  /// (b) it has no billing quantity and the total was entered manually,
  ///     in which case the quantity is only a description.
  /// Descriptive quantities are never interpreted as numbers.
  static void _validateLineItem(SaleItem item) {
    if (item.productNameSnapshot.trim().isEmpty ||
        item.quantityText.trim().isEmpty ||
        item.unitPriceSnapshotMinorUnits < 0 ||
        item.lineDiscountMinorUnits < 0 ||
        item.lineTotalMinorUnits < 0) {
      throw Exception('Sale contains an invalid line item.');
    }

    final milliunits = item.billingQuantityMilliunits;
    if (milliunits != null) {
      if (milliunits < 0) {
        throw Exception('Sale contains an invalid line item.');
      }
      final base = MoneyUtils.tryLineTotalMinorUnits(
        item.unitPriceSnapshotMinorUnits,
        milliunits,
      );
      if (base == null) {
        throw Exception('A line item total is too large.');
      }
      if (item.lineDiscountMinorUnits > base ||
          item.lineTotalMinorUnits != base - item.lineDiscountMinorUnits) {
        throw Exception(
          'A line total does not match its unit price and quantity.',
        );
      }
    } else if (item.lineTotalMinorUnits == 0) {
      // Manual totals must be positive; a zero line adds nothing and is
      // almost certainly a mistake.
      throw Exception('A manually entered line amount is required.');
    }
  }

  /// Reserves the next sequential receipt number for today, e.g.
  /// `REC-20261021-0007`. Numbers are allocated in a transaction so a retail
  /// audit can follow them in order. They are internal identifiers only and
  /// are never shown in the sales-history interface.
  ///
  /// The day's counter alone is not enough: `sales.receipt_number` is UNIQUE
  /// locally, and a register that has pulled the shop's history already holds
  /// other tills' numbers for today (the pull namespaces only the ones that
  /// clash on the way in, never the first). The counter only remembers what
  /// THIS till handed out, so a second device joining the shop would be told
  /// `0001` — a number already in the book — and `saveSale` would fail on the
  /// unique index. The till could not take a single payment until it was
  /// restarted with a bumped counter. Allocation therefore starts above the
  /// highest receipt present locally for the day.
  @override
  Future<String> nextReceiptNumber({String? userId}) async {
    await _requireFeature(_db, userId, feature: 'pos');
    final now = DateTime.now();
    final day =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final key = 'receipt-$day';
    final prefix = 'REC-$day-';

    final next = await _db.transaction((txn) async {
      final rows = await txn.query(
        'counters',
        columns: ['value'],
        where: 'name = ?',
        whereArgs: [key],
        limit: 1,
      );
      var value = rows.isEmpty ? 1 : (rows.first['value'] as int) + 1;
      // `substr(...,n,4)` reads the padded run of digits only, so a receipt the
      // pull tagged (`REC-…-0004#bf4aca21`) still counts as used.
      final used = await txn.rawQuery(
        'SELECT MAX(CAST(substr(receipt_number, ?, 4) AS INTEGER)) AS top '
        'FROM sales WHERE receipt_number LIKE ?',
        [prefix.length + 1, '$prefix%'],
      );
      final highest = (used.first['top'] as int?) ?? 0;
      if (value <= highest) value = highest + 1;
      await txn.insert('counters', {
        'name': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return value;
    });

    return '$prefix${next.toString().padLeft(4, '0')}';
  }

  @override
  Future<void> voidSale(String saleId, String userId, String reason) async {
    if (reason.trim().isEmpty || reason.trim().length > 240) {
      throw Exception('A void reason of 1 to 240 characters is required.');
    }
    await _db.transaction((txn) async {
      final saleMaps = await txn.query(
        'sales',
        where: 'id = ?',
        whereArgs: [saleId],
      );
      if (saleMaps.isEmpty) {
        throw Exception('Sale not found');
      }
      if (saleMaps.first['status'] == 'VOIDED') {
        throw Exception('Sale is already voided');
      }

      final users = await txn.query(
        'users',
        columns: ['role', 'is_active'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (users.isEmpty ||
          users.first['role'] != 'OWNER' ||
          users.first['is_active'] != 1) {
        throw Exception('Only an active owner can void a sale.');
      }
      final activeShifts = await txn.query(
        'shifts',
        columns: ['id'],
        where: "status = 'OPEN'",
        limit: 1,
      );

      final updated = await txn.update(
        'sales',
        {
          'status': 'VOIDED',
          'void_reason': reason.trim(),
          'voided_at': DateTime.now().toIso8601String(),
          'voided_by': userId,
          'voided_shift_id': activeShifts.isEmpty
              ? null
              : activeShifts.first['id'],
        },
        where: "id = ? AND status != 'VOIDED'",
        whereArgs: [saleId],
      );
      if (updated != 1) {
        throw Exception('Sale is no longer voidable');
      }

      // A direct owner void also settles any pending cashier request for the
      // same sale so it stops showing up in the approval queue.
      await txn.update(
        'void_requests',
        {
          'status': VoidRequest.statusApproved,
          'decided_by': userId,
          'decided_at': DateTime.now().toIso8601String(),
        },
        where: "sale_id = ? AND status = ?",
        whereArgs: [saleId, VoidRequest.statusPending],
      );

      final voidedTotal = saleMaps.first['total_minor_units'] as int? ?? 0;
      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': userId,
        'action': 'SALE_VOIDED',
        'details':
            'Sale of ${MoneyUtils.formatBr(voidedTotal)} voided. '
            'Reason: ${reason.trim()}',
        'created_at': DateTime.now().toIso8601String(),
      });
      await _enqueueSale(txn, saleId);
    });
  }

  /// Queries historical sales. Search matches product names, quantity
  /// descriptions, notes, customer name, cashier username, and void reason —
  /// never receipt numbers. [period] and [status] are optional filters.
  @override
  Future<List<Sale>> getSales({
    String? userId,
    String? searchQuery,
    DateRange? period,
    String? status,
    int? limit,
  }) async {
    await _requireFeature(
      _db,
      userId,
      feature: 'history',
      aliases: const ['register_history'],
    );
    final where = <String>[];
    final args = <dynamic>[];

    // Training-account sales stay inside the demo login. They can still be in
    // this database (written before the outbox guard, or pulled from a cloud
    // that an un-updated till kept feeding), and a history list the dashboard
    // totals disagree with is worse than either being wrong.
    where.add(notDemoOperator('sales.cashier_id'));

    if (period != null) {
      where.add('sales.created_at >= ? AND sales.created_at < ?');
      args.add(period.start.toIso8601String());
      args.add(period.end.toIso8601String());
    }
    if (status != null && status.isNotEmpty && status != 'ALL') {
      where.add('sales.status = ?');
      args.add(status);
    }

    final query = searchQuery?.trim();
    if (query != null && query.isNotEmpty) {
      final pattern = '%${SaleRepository.escapeLike(query.toLowerCase())}%';
      const escape = r" ESCAPE '\'";
      where.add('''
        (LOWER(COALESCE(sales.customer_name, '')) LIKE ?$escape
         OR LOWER(COALESCE(sales.void_reason, '')) LIKE ?$escape
         OR LOWER(users.username) LIKE ?$escape
         OR EXISTS (
              SELECT 1 FROM sale_items si
              WHERE si.sale_id = sales.id
                AND (LOWER(si.product_name_snapshot) LIKE ?$escape
                 OR LOWER(si.quantity_text) LIKE ?$escape
                 OR LOWER(COALESCE(si.notes, '')) LIKE ?$escape)))
      ''');
      args.addAll(List.filled(6, pattern));
    }

    final sql = StringBuffer('''
      SELECT sales.*, users.username AS cashier_name,
        EXISTS (
          SELECT 1 FROM void_requests vr
          WHERE vr.sale_id = sales.id AND vr.status = 'PENDING'
        ) AS has_pending_void_request
      FROM sales
      LEFT JOIN users ON sales.cashier_id = users.id
    ''');
    if (where.isNotEmpty) sql.write(' WHERE ${where.join(' AND ')}');
    sql.write(' ORDER BY sales.created_at DESC');
    if (limit != null) {
      sql.write(' LIMIT ?');
      args.add(limit);
    }

    final saleMaps = await _db.rawQuery(sql.toString(), args);
    return _hydrate(saleMaps);
  }

  @override
  Future<List<Sale>> getRecentSales({String? userId, int limit = 5}) {
    return getSales(userId: userId, limit: limit);
  }

  /// Voids that must be reviewed at shift close. Mirrors the cash calculation
  /// in [ShiftRepository.getShiftSummary] exactly.
  @override
  Future<List<Sale>> getVoidedSalesForShift(
    String shiftId, {
    String? userId,
  }) async {
    await _requireFeature(
      _db,
      userId,
      feature: 'history',
      aliases: const ['register_history'],
    );
    final saleMaps = await _db.query(
      'sales',
      where:
          "status = 'VOIDED' AND "
          '${notDemoOperator('cashier_id')} AND '
          '(voided_shift_id = ? OR (voided_shift_id IS NULL AND shift_id = ?))',
      whereArgs: [shiftId, shiftId],
      orderBy: 'created_at DESC',
    );
    return _hydrate(saleMaps);
  }

  /// A cashier (or owner) flags a completed sale for voiding. The sale is left
  /// `COMPLETED` until an owner approves the request, so revenue and the drawer
  /// are unchanged in the meantime.
  @override
  Future<void> requestVoid(String saleId, String userId, String reason) async {
    if (reason.trim().isEmpty || reason.trim().length > 240) {
      throw Exception('A void reason of 1 to 240 characters is required.');
    }
    await _db.transaction((txn) async {
      final saleMaps = await txn.query(
        'sales',
        columns: ['status'],
        where: 'id = ?',
        whereArgs: [saleId],
        limit: 1,
      );
      if (saleMaps.isEmpty) throw Exception('Sale not found');
      if (saleMaps.first['status'] != 'COMPLETED') {
        throw Exception('Only a completed sale can be flagged for voiding.');
      }
      final users = await txn.query(
        'users',
        columns: ['is_active'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (users.isEmpty || users.first['is_active'] != 1) {
        throw Exception('An active user is required.');
      }
      final pending = await txn.query(
        'void_requests',
        columns: ['id'],
        where: "sale_id = ? AND status = 'PENDING'",
        whereArgs: [saleId],
        limit: 1,
      );
      if (pending.isNotEmpty) {
        throw Exception('A void request is already pending for this sale.');
      }
      final requestId = const Uuid().v4();
      await txn.insert('void_requests', {
        'id': requestId,
        'sale_id': saleId,
        'requested_by': userId,
        'reason': reason.trim(),
        'status': VoidRequest.statusPending,
        'created_at': DateTime.now().toIso8601String(),
      });
      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': userId,
        'action': 'VOID_REQUESTED',
        'details': 'Void requested for sale $saleId. Reason: ${reason.trim()}',
        'created_at': DateTime.now().toIso8601String(),
      });
      await _enqueueVoidRequest(txn, requestId);
    });
  }

  /// Pending void requests, newest first, each with the targeted sale hydrated
  /// for display. Owner-only surface, but readable by any caller.
  @override
  Future<List<VoidRequest>> getPendingVoidRequests({String? userId}) async {
    if (userId != null) {
      final actors = await _db.query(
        'users',
        columns: ['role'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [userId],
        limit: 1,
      );
      if (actors.isEmpty || actors.first['role'] != 'OWNER') {
        throw Exception('Only an owner can view pending void requests.');
      }
    }
    final rows = await _db.rawQuery(
      '''
      SELECT vr.*, users.username AS requester_name
      FROM void_requests vr
      LEFT JOIN users ON vr.requested_by = users.id
      WHERE vr.status = ?
        AND ${notDemoOperator('vr.requested_by')}
      ORDER BY vr.created_at DESC
    ''',
      [VoidRequest.statusPending],
    );
    if (rows.isEmpty) return [];
    final sales = await _salesByIds(
      rows.map((row) => row['sale_id'] as String).toList(),
    );
    final byId = {for (final sale in sales) sale.id: sale};
    return rows
        .map(
          (row) => VoidRequest(
            id: row['id'] as String,
            saleId: row['sale_id'] as String,
            requestedBy: row['requested_by'] as String,
            requesterName: row['requester_name'] as String?,
            reason: row['reason'] as String,
            status: row['status'] as String,
            createdAt: DateTime.parse(row['created_at'] as String),
            decidedBy: row['decided_by'] as String?,
            decidedAt: row['decided_at'] == null
                ? null
                : DateTime.parse(row['decided_at'] as String),
            sale: byId[row['sale_id'] as String],
          ),
        )
        .toList();
  }

  /// Owner approves a pending request: the sale is voided exactly as a direct
  /// owner void would be, then the request is closed out.
  @override
  Future<void> approveVoidRequest(String requestId, String ownerId) async {
    await _db.transaction((txn) async {
      final owner = await txn.query(
        'users',
        columns: ['role', 'is_active'],
        where: 'id = ?',
        whereArgs: [ownerId],
        limit: 1,
      );
      if (owner.isEmpty ||
          owner.first['role'] != 'OWNER' ||
          owner.first['is_active'] != 1) {
        throw Exception('Only an active owner can approve a void request.');
      }
      final requests = await txn.query(
        'void_requests',
        where: 'id = ?',
        whereArgs: [requestId],
        limit: 1,
      );
      if (requests.isEmpty) throw Exception('Void request not found');
      if (requests.first['status'] != VoidRequest.statusPending) {
        throw Exception('This void request has already been decided.');
      }
      final saleId = requests.first['sale_id'] as String;
      final reason = requests.first['reason'] as String;

      final saleMaps = await txn.query(
        'sales',
        where: 'id = ?',
        whereArgs: [saleId],
      );
      if (saleMaps.isEmpty) throw Exception('Sale not found');
      if (saleMaps.first['status'] == 'VOIDED') {
        throw Exception('Sale is already voided');
      }
      final activeShifts = await txn.query(
        'shifts',
        columns: ['id'],
        where: "status = 'OPEN'",
        limit: 1,
      );
      final now = DateTime.now().toIso8601String();
      final updated = await txn.update(
        'sales',
        {
          'status': 'VOIDED',
          'void_reason': reason,
          'voided_at': now,
          'voided_by': ownerId,
          'voided_shift_id': activeShifts.isEmpty
              ? null
              : activeShifts.first['id'],
        },
        where: "id = ? AND status != 'VOIDED'",
        whereArgs: [saleId],
      );
      if (updated != 1) throw Exception('Sale is no longer voidable');

      await txn.update(
        'void_requests',
        {
          'status': VoidRequest.statusApproved,
          'decided_by': ownerId,
          'decided_at': now,
        },
        where: 'id = ?',
        whereArgs: [requestId],
      );

      final voidedTotal = saleMaps.first['total_minor_units'] as int? ?? 0;
      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': ownerId,
        'action': 'SALE_VOIDED',
        'details':
            'Sale of ${MoneyUtils.formatBr(voidedTotal)} voided via request. '
            'Reason: $reason',
        'created_at': now,
      });
      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': ownerId,
        'action': 'VOID_REQUEST_APPROVED',
        'details': 'Void request $requestId approved for sale $saleId.',
        'created_at': now,
      });
      await _enqueueSale(txn, saleId);
      await _enqueueVoidRequest(txn, requestId);
    });
  }

  /// Owner rejects a pending request; the sale is left untouched.
  @override
  Future<void> rejectVoidRequest(String requestId, String ownerId) async {
    await _db.transaction((txn) async {
      final owner = await txn.query(
        'users',
        columns: ['role', 'is_active'],
        where: 'id = ?',
        whereArgs: [ownerId],
        limit: 1,
      );
      if (owner.isEmpty ||
          owner.first['role'] != 'OWNER' ||
          owner.first['is_active'] != 1) {
        throw Exception('Only an active owner can reject a void request.');
      }
      final requests = await txn.query(
        'void_requests',
        where: 'id = ?',
        whereArgs: [requestId],
        limit: 1,
      );
      if (requests.isEmpty) throw Exception('Void request not found');
      if (requests.first['status'] != VoidRequest.statusPending) {
        throw Exception('This void request has already been decided.');
      }
      await txn.update(
        'void_requests',
        {
          'status': VoidRequest.statusRejected,
          'decided_by': ownerId,
          'decided_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [requestId],
      );
      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': ownerId,
        'action': 'VOID_REQUEST_REJECTED',
        'details':
            'Void request $requestId rejected. '
            'Reason given: ${requests.first['reason']}',
        'created_at': DateTime.now().toIso8601String(),
      });
      await _enqueueVoidRequest(txn, requestId);
    });
  }

  /// Loads sales by id (with cashier name and pending-request flag hydrated).
  Future<List<Sale>> _salesByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final placeholders = List.filled(ids.length, '?').join(',');
    final maps = await _db.rawQuery('''
      SELECT sales.*, users.username AS cashier_name,
        EXISTS (
          SELECT 1 FROM void_requests vr
          WHERE vr.sale_id = sales.id AND vr.status = 'PENDING'
        ) AS has_pending_void_request
      FROM sales
      LEFT JOIN users ON sales.cashier_id = users.id
      WHERE sales.id IN ($placeholders)
    ''', ids);
    return _hydrate(maps);
  }

  /// Completed revenue and sale count per calendar day across [period],
  /// ordered oldest to newest, for the dashboard trend chart. Loan sales are
  /// money owed rather than collected, so they are left out of the trend.
  @override
  Future<List<Map<String, dynamic>>> getRevenueTrend(
    DateRange period, {
    String? userId,
  }) async {
    await _requireFeature(_db, userId, feature: 'dashboard');
    return _db.rawQuery(
      '''
      SELECT substr(created_at, 1, 10) AS day,
        COUNT(*) AS count,
        COALESCE(SUM(total_minor_units), 0) AS total
      FROM sales
      WHERE status = 'COMPLETED'
        AND payment_method IN ('CASH', 'BANK')
        AND ${notDemoOperator('cashier_id')}
        AND created_at >= ? AND created_at < ?
      GROUP BY day
      ORDER BY day ASC
    ''',
      [period.start.toIso8601String(), period.end.toIso8601String()],
    );
  }

  /// Appends the current state of a sale (row + its items) to the outbox, in
  /// the caller's transaction. The cloud receives the whole aggregate so it can
  /// reconstruct the sale; re-enqueueing on void simply sends the newer state.
  Future<void> _enqueueSale(Transaction txn, String saleId) async {
    final saleRow = await txn.query(
      'sales',
      where: 'id = ?',
      whereArgs: [saleId],
      limit: 1,
    );
    if (saleRow.isEmpty) return;
    final items = await txn.query(
      'sale_items',
      where: 'sale_id = ?',
      whereArgs: [saleId],
      orderBy: 'rowid ASC',
    );
    await SyncOutbox.upsert(
      txn,
      entityType: SyncEntities.sale,
      entityId: saleId,
      payload: {'sale': saleRow.first, 'items': items},
    );
  }

  Future<void> _enqueueVoidRequest(Transaction txn, String requestId) async {
    final rows = await txn.query(
      'void_requests',
      where: 'id = ?',
      whereArgs: [requestId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await SyncOutbox.upsert(
      txn,
      entityType: SyncEntities.voidRequest,
      entityId: requestId,
      payload: {'void_request': rows.first},
    );
  }

  Future<List<Sale>> _hydrate(List<Map<String, Object?>> saleMaps) async {
    if (saleMaps.isEmpty) return [];

    final ids = saleMaps.map((map) => map['id'] as String).toList();
    final itemsBySale = <String, List<SaleItem>>{};
    const chunkSize = 400;
    for (var start = 0; start < ids.length; start += chunkSize) {
      final end = start + chunkSize > ids.length
          ? ids.length
          : start + chunkSize;
      final chunk = ids.sublist(start, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final itemMaps = await _db.query(
        'sale_items',
        where: 'sale_id IN ($placeholders)',
        whereArgs: chunk,
        orderBy: 'rowid ASC',
      );
      for (final row in itemMaps) {
        final item = SaleItem.fromMap(row);
        itemsBySale.putIfAbsent(item.saleId, () => []).add(item);
      }
    }

    return saleMaps.map((map) {
      final saleId = map['id'] as String;
      return Sale(
        id: saleId,
        receiptNumber: map['receipt_number'] as String,
        cashierId: map['cashier_id'] as String,
        deviceId: map['device_id'] as String,
        shiftId: map['shift_id'] as String? ?? '',
        customerName: map['customer_name'] as String?,
        paymentMethod: map['payment_method'] as String,
        subtotalMinorUnits: map['subtotal_minor_units'] as int,
        discountMinorUnits: map['discount_minor_units'] as int,
        totalMinorUnits: map['total_minor_units'] as int,
        amountPaidMinorUnits: map['amount_paid_minor_units'] as int,
        changeMinorUnits: map['change_minor_units'] as int,
        status: map['status'] as String,
        voidReason: map['void_reason'] as String?,
        voidedAt: map['voided_at'] == null
            ? null
            : DateTime.parse(map['voided_at'] as String),
        voidedBy: map['voided_by'] as String?,
        voidedShiftId: map['voided_shift_id'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
        syncedAt: map['synced_at'] != null
            ? DateTime.parse(map['synced_at'] as String)
            : null,
        cashierName: map['cashier_name'] as String?,
        hasPendingVoidRequest:
            (map['has_pending_void_request'] as int? ?? 0) == 1,
        items: itemsBySale[saleId] ?? const [],
      );
    }).toList();
  }

  /// Revenue figures for the dashboard. Voided sales are always excluded.
  /// Loan sales are recorded but collected no money, so they never count
  /// toward the revenue figures. Defaults to today so the dashboard resets at
  /// local midnight purely by date filtering — records are never deleted.
  @override
  Future<Map<String, int>> getDashboardStats({
    String? userId,
    DateRange? period,
  }) async {
    await _requireFeature(_db, userId, feature: 'dashboard');
    final range = period ?? DateRange.today();
    final rangeArgs = [
      range.start.toIso8601String(),
      range.end.toIso8601String(),
    ];
    // Every figure below shares one filter, so the dashboard, its void count and
    // its pending approvals all speak about the real shop only.
    final completed =
        "created_at >= ? AND created_at < ? AND status = 'COMPLETED' "
        'AND ${notDemoOperator('cashier_id')}';

    final revenueRow = await _db.rawQuery('''
      SELECT COUNT(*) AS count, COALESCE(SUM(total_minor_units), 0) AS total
      FROM sales
      WHERE $completed AND payment_method IN ('CASH', 'BANK')
    ''', rangeArgs);

    final cashRow = await _db.rawQuery('''
      SELECT COALESCE(SUM(total_minor_units), 0) AS total
      FROM sales WHERE $completed AND payment_method = 'CASH'
    ''', rangeArgs);

    final bankRow = await _db.rawQuery('''
      SELECT COALESCE(SUM(total_minor_units), 0) AS total
      FROM sales WHERE $completed AND payment_method = 'BANK'
    ''', rangeArgs);

    // Sales rung up in the period that were later voided.
    final voidRow = await _db.rawQuery('''
      SELECT COUNT(*) AS count FROM sales
      WHERE status = 'VOIDED' AND ${notDemoOperator('cashier_id')}
        AND created_at >= ? AND created_at < ?
    ''', rangeArgs);

    // Cashier void requests still awaiting an owner's decision.
    final pendingRow = await _db.rawQuery('''
      SELECT COUNT(*) AS count
      FROM void_requests vr
      JOIN sales s ON vr.sale_id = s.id
      WHERE vr.status = 'PENDING'
        AND ${notDemoOperator('s.cashier_id')}
        AND s.created_at >= ? AND s.created_at < ?
    ''', rangeArgs);

    final shiftResult = await _db.query(
      'shifts',
      where: 'status = ?',
      whereArgs: ['OPEN'],
      limit: 1,
    );
    int expectedCash = 0;
    if (shiftResult.isNotEmpty) {
      final shift = Shift.fromMap(shiftResult.first);
      try {
        final summary = await ShiftRepository(_db)
            .getShiftSummary(shift, userId: userId);
        expectedCash = summary['expected_cash']!;
      } catch (_) {
        // Shift summary requires the register tick. A staff account with only
        // dashboard access still gets revenue stats; expected cash stays 0.
      }
    }

    final salesCount = revenueRow.first['count'] as int;
    final revenue = revenueRow.first['total'] as int;

    return {
      'revenue': revenue,
      'sales_count': salesCount,
      'cash_revenue': cashRow.first['total'] as int,
      'bank_revenue': bankRow.first['total'] as int,
      'average_sale': salesCount == 0 ? 0 : revenue ~/ salesCount,
      'expected_cash': expectedCash,
      'is_shift_open': shiftResult.isEmpty ? 0 : 1,
      'void_count': voidRow.first['count'] as int,
      'pending_void_requests': pendingRow.first['count'] as int,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getAuditLogs({
    String? userId,
    int limit = 500,
  }) async {
    await _requireFeature(_db, userId, feature: 'audit');
    return _db.rawQuery(
      '''
      SELECT audit_logs.action, audit_logs.details, audit_logs.created_at, users.username
      FROM audit_logs
      LEFT JOIN users ON audit_logs.user_id = users.id
      ORDER BY audit_logs.created_at DESC
      LIMIT ?
      ''',
      [limit],
    );
  }

  @override
  Future<int> getTodayRevenue({String? userId}) async {
    final stats = await getDashboardStats(userId: userId);
    return stats['revenue']!;
  }

  /// Revenue by entered product name for the reports screen. Quantities are
  /// summed in milliunits; lines with manual totals contribute revenue but no
  /// numeric quantity. Loan sales are excluded — their money was never
  /// collected.
  @override
  Future<List<Map<String, dynamic>>> getProductSalesSummary({
    String? userId,
    DateRange? period,
  }) async {
    await _requireFeature(_db, userId, feature: 'reports');
    final rangeArgs = period == null
        ? <dynamic>[]
        : [period.start.toIso8601String(), period.end.toIso8601String()];
    final rangeClause = period == null
        ? ''
        : ' AND sales.created_at >= ? AND sales.created_at < ?';
    return _db.rawQuery('''
      SELECT si.product_name_snapshot,
        COALESCE(SUM(si.billing_quantity_milliunits), 0) AS total_qty_milliunits,
        COUNT(*) AS line_count,
        SUM(si.line_total_minor_units) AS total_revenue
      FROM sale_items si
      JOIN sales ON si.sale_id = sales.id
      WHERE sales.status = 'COMPLETED'
        AND ${notDemoOperator('sales.cashier_id')}
        AND sales.payment_method IN ('CASH', 'BANK')$rangeClause
      GROUP BY si.product_name_snapshot
      ORDER BY total_revenue DESC
    ''', rangeArgs);
  }

  @override
  Future<List<Map<String, dynamic>>> getCashierPerformance({
    String? userId,
    DateRange? period,
  }) async {
    await _requireFeature(_db, userId, feature: 'reports');
    final rangeArgs = period == null
        ? <dynamic>[]
        : [period.start.toIso8601String(), period.end.toIso8601String()];
    final rangeClause = period == null
        ? ''
        : ' AND sales.created_at >= ? AND sales.created_at < ?';
    return _db.rawQuery('''
      SELECT users.username, COUNT(sales.id) AS total_sales, COALESCE(SUM(sales.total_minor_units), 0) AS total_revenue
      FROM sales
      JOIN users ON sales.cashier_id = users.id
      WHERE sales.status = 'COMPLETED'
        AND ${notDemoOperator('sales.cashier_id')}
        AND sales.payment_method IN ('CASH', 'BANK')$rangeClause
      GROUP BY users.id, users.username
      ORDER BY total_revenue DESC
    ''', rangeArgs);
  }
}
