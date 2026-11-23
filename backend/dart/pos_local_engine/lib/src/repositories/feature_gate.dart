import 'package:sqflite/sqflite.dart';

import 'package:pos_core/users.dart';

/// Owner always passes; staff must hold [feature] (or one of [aliases]).
///
/// Shared by the operational repositories and the reporting repository so the
/// permission gate has exactly one implementation per storage engine.
Future<void> requireFeature(
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
  final required = <String>{feature, ...aliases};
  if (!held.any(required.contains)) {
    throw Exception('This account does not have access to $feature.');
  }
}
