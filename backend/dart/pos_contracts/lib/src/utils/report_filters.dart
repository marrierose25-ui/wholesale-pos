/// Report filters shared by native and cloud implementations.
import 'date_range.dart';

class ReportFilters {
  /// Returns the WHERE clause and arguments for the given filters.
  ///
  /// [table] is the table alias or name (e.g., 'sales', 's').
  /// [userId] optionally restricts to a cashier.
  /// [period] optionally restricts to a date range.
  /// [status] optionally restricts to a sale status.
  static ({String where, List<Object?> args}) build({
    required String table,
    String? userId,
    DateRange? period,
    String? status,
  }) {
    final conditions = <String>[];
    final args = <Object?>[];

    if (userId != null) {
      conditions.add('${table}.cashier_id = ?');
      args.add(userId);
    }

    if (period != null) {
      conditions.add('${table}.created_at BETWEEN ? AND ?');
      args.add(period.start.toIso8601String());
      args.add(period.end.toIso8601String());
    }

    if (status != null && status.isNotEmpty) {
      conditions.add('${table}.status = ?');
      args.add(status);
    }

    return (
      where: conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}',
      args: args,
    );
  }
}