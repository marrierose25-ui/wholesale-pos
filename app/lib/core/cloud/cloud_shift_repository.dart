import '../../features/sales/shift.dart';
import '../repositories/shift_repository.dart';
import '../utils/date_range.dart';
import 'cloud_api_client.dart';

/// Web/PWA [ShiftRepository] over the `pos-api` Edge Function.
///
/// Backs the register open/close ("close the drawer") flow the PWA needs. The
/// active shift's cashier is taken from the session token server-side, so the
/// `cashierId`/`userId` arguments exist only to keep the native/cloud call
/// sites interchangeable; the server ignores the client's claim of who it is.
class CloudShiftRepository implements ShiftRepository {
  final CloudApiClient _api;

  CloudShiftRepository(this._api);

  @override
  Future<Shift?> getActiveShift() async {
    final json = await _api.call('get_shift');
    final shift = json['shift'];
    if (shift is! Map<String, dynamic>) return null;
    return Shift.fromMap(shift);
  }

  @override
  Future<Shift> ensureActiveShift(String cashierId) async {
    final json = await _api.call('ensure_shift');
    final shift = json['shift'];
    if (shift is! Map<String, dynamic>) {
      throw Exception('Server returned no shift.');
    }
    return Shift.fromMap(shift);
  }

  @override
  Future<Map<String, int>> getRegisterSnapshot(DateRange day) async {
    final json = await _api.call('register_snapshot', {
      'period_start': day.start.toIso8601String(),
      'period_end': day.end.toIso8601String(),
    });
    final snapshot = json['snapshot'];
    if (snapshot is! Map<String, dynamic>) return const {};
    return {
      for (final e in snapshot.entries) e.key: (e.value as num?)?.toInt() ?? 0,
    };
  }

  @override
  Future<List<Shift>> getShiftHistory({
    DateRange? period,
    String? status,
  }) async {
    final json = await _api.call('shift_history', {
      if (period != null) 'period_start': period.start.toIso8601String(),
      if (period != null) 'period_end': period.end.toIso8601String(),
      'status': ?status,
    });
    final rows = json['shifts'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().map(Shift.fromMap).toList();
  }

  @override
  Future<void> openShift(String cashierId, int openingCash) async {
    await _api.call('open_shift', {'opening_cash_minor_units': openingCash});
  }

  @override
  Future<void> addCashMovement(
    String shiftId,
    String type,
    int amount,
    String reason, {
    String? userId,
  }) async {
    await _api.call('add_cash_movement', {
      'shift_id': shiftId,
      'type': type,
      'amount_minor_units': amount,
      'reason': reason,
    });
  }

  @override
  Future<List<CashMovement>> getCashMovements({String? shiftId}) async {
    final json = await _api.call('list_cash_movements', {'shift_id': ?shiftId});
    final rows = json['movements'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(CashMovement.fromMap)
        .toList();
  }

  @override
  Future<Map<String, int>> getShiftSummary(Shift shift) async {
    final json = await _api.call('shift_summary', {'shift_id': shift.id});
    final summary = json['summary'];
    if (summary is! Map<String, dynamic>) return const {};
    return {
      for (final e in summary.entries) e.key: (e.value as num?)?.toInt() ?? 0,
    };
  }

  @override
  Future<void> closeShift(
    Shift shift,
    int closingCash, {
    String? userId,
  }) async {
    await _api.call('close_shift', {
      'shift_id': shift.id,
      'closing_cash_minor_units': closingCash,
    });
  }
}
