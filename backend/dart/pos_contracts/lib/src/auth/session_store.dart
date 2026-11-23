import 'dart:convert';
import 'dart:math';

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
  /// device. Persistent sign-in is ON by default so a till that is closed and
  /// reopened does not demand the password again; only an explicit '0' opts out.
  static const String rememberKey = 'remember_login';

  /// How long a persisted session stays valid once the app is closed.
  ///
  /// Sign-in is persistent: an operator stays logged in until they explicitly
  /// tap Logout (or the account is deactivated, which revokes the saved
  /// session via `UserRepository.getById`). The window is effectively "never"
  /// rather than a rolling timeout, so simply closing the till — or the
  /// browser — does not demand the password again. Every successful resume
  /// slides this far-future window forward, so an actively used device can
  /// never drift into an expiry mid-shift.
  static const Duration defaultLifetime = Duration(days: 3650);

  Future<void> save(SessionData session);

  /// Returns the stored session, or null if there is none or it has expired.
  Future<SessionData?> load();

  Future<void> clear();
}