import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'package:pos_contracts/pos_contracts.dart';

/// Default [SessionStore] backed by the existing `settings` table. It adds no
/// native plugin dependency, so the offline Windows build stays reproducible.
/// The stored blob holds only an opaque nonce plus the user id and expiry —
/// never the password or the PBKDF2 hash.
class SettingsSessionStore implements SessionStore {
  static const String _sessionKey = 'auth_session';
  final Database _db;

  SettingsSessionStore(this._db);

  @override
  Future<void> save(SessionData session) async {
    await _db.insert('settings', {
      'key': _sessionKey,
      'value': jsonEncode(session.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<SessionData?> load() async {
    final rows = await _db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_sessionKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['value'] as String?;
    if (raw == null) return null;
    try {
      final session = SessionData.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (session.isExpired()) {
        // Expired: drop it so it cannot be resurrected and require a re-login.
        await clear();
        return null;
      }
      return session;
    } catch (_) {
      // Malformed or tampered record: treat as no session.
      await clear();
      return null;
    }
  }

  @override
  Future<void> clear() async {
    await _db.delete('settings', where: 'key = ?', whereArgs: [_sessionKey]);
  }
}