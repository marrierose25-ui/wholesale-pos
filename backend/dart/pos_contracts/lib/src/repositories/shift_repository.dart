// Extracted verbatim from the pre-Stage-6 application implementation.
// Signatures and documentation are unchanged; only the SQLite factory
// line (which belongs to the implementation package) was removed.
import 'package:pos_core/register.dart';
import 'package:pos_contracts/src/utils/date_range.dart';

abstract class ShiftRepository {

  Future<Shift?> getActiveShift({String? userId});

  /// Returns the currently open shift, creating a perpetual one (opening cash
  /// `0`) when none exists. Idempotent and safe against the one-open-shift
  /// trigger: concurrent callers converge on a single OPEN row.
  Future<Shift> ensureActiveShift(String cashierId, {String? userId});

  /// Past and present register sessions, newest first, each carrying the
  /// cashier username for display. Filter by the day the shift was *opened*
  /// ([period], a half-open local range) and/or [status] (`OPEN`/`CLOSED`).
  Future<List<Shift>> getShiftHistory({
    String? userId,
    DateRange? period,
    String? status,
  });

  Future<void> openShift(String cashierId, int openingCash);

  Future<void> addCashMovement(
    String shiftId,
    String type,
    int amount,
    String reason, {
    String? userId,
    String? photo,
  });

  /// The cash-register ledger, newest first, each carrying the username of
  /// whoever recorded it. Pass [shiftId] to restrict the list to one session,
  /// or omit it for every movement across all shifts.
  Future<List<CashMovement>> getCashMovements({
    String? userId,
    String? shiftId,
  });

  Future<Map<String, int>> getShiftSummary(Shift shift, {String? userId});

  /// Register figures for the perpetual open shift: `balance` is the all-time
  /// expected cash in the drawer, while the `today_*` counters are the same
  /// sums restricted to [day] (a half-open local range) so they reset each
  /// calendar day. Returns all zeros when no shift is open.
  Future<Map<String, int>> getRegisterSnapshot(DateRange day, {String? userId});

  Future<void> closeShift(Shift shift, int closingCash, {String? userId});
}
