import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

/// An opaque, local sign-in session that lets the app reopen straight to the
/// register after a restart, without re-typing a password.
///
/// Today this only proves "the same person who signed out last time is back on
/// the same machine within the validity window". When the cloud backend lands,
/// [token] becomes a real access token issued by the server and this object is
/// what [flutter_secure_storage] will persist instead of the settings table —
/// see docs/CLOUD_SYNC.md. Nothing else in the app needs to change.
class SessionData {
  final String userId;
  final String token;
  final DateTime issuedAt;
  final DateTime expiresAt;

  const SessionData({
    required this.userId,
    required this.token,
    required this.issuedAt,
    required this.expiresAt,
  });

  bool isExpired([DateTime? now]) => (now ?? DateTime.now()).isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'token': token,
    'issuedAt': issuedAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
  };

  factory SessionData.fromJson(Map<String, dynamic> json) => SessionData(
    userId: json['userId'] as String,
    token: json['token'] as String,
    issuedAt: DateTime.parse(json['issuedAt'] as String),
    expiresAt: DateTime.parse(json['expiresAt'] as String),
  );

  /// Builds a session for [userId] that stays valid for [lifetime]. The token
  /// is a random nonce; it is not derived from the password and carries no
  /// secret material.
  factory SessionData.create(String userId, {required Duration lifetime}) {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final now = DateTime.now();
    return SessionData(
      userId: userId,
      token: base64Url.encode(bytes),
      issuedAt: now,
      expiresAt: now.add(lifetime),
    );
  }
}

/// Stores and retrieves the persisted sign-in session. Kept abstract so the
/// settings-table implementation used today can be swapped for a secure-storage
/// implementation without touching any callers.
abstract class SessionStore {
  /// Setting key that records whether "stay signed in" is enabled on this
  /// device. Opt-in and OFF by default so a shared till never auto-resumes an
  /// owner session.
  static const String rememberKey = 'remember_login';

  /// How long a persisted session stays valid once the app is closed.
  static const Duration defaultLifetime = Duration(hours: 12);

  Future<void> save(SessionData session);

  /// Returns the stored session, or null if there is none or it has expired.
  Future<SessionData?> load();

  Future<void> clear();
}

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
