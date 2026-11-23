import 'dart:convert';

class User {
  final String id;

  /// The account's login identifier: a phone number in canonical local form
  /// (`0912345678`) for owners and staff, or the literal `demo` for the seeded
  /// training account. Kept in the `username` column so existing installs and
  /// the cloud schema stay compatible.
  final String username;
  final String passwordHash;
  final String salt;
  final String role;
  final bool isActive;

  /// Feature-tab keys this account is allowed to open. Always empty for an
  /// OWNER (who bypasses the tick list via [can]); the authoritative source for
  /// every other account. Persisted as a JSON array natively and as a native
  /// list over the cloud `pos-api`.
  final List<String> permissions;

  /// True for the permanent training account that is seeded on every install
  /// and cloud tenant. It behaves like a normal CASHIER (its [permissions]
  /// apply) except that it can never be deactivated.
  final bool isDemo;

  User({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.salt,
    required this.role,
    this.isActive = true,
    this.permissions = const [],
    this.isDemo = false,
  });

  /// True when the account may open the feature registered under [feature].
  /// OWNER returns true for everything; every other account is limited to the
  /// exact set it was ticked at creation / last edit.
  bool can(String feature) => role == 'OWNER' || permissions.contains(feature);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'password_hash': passwordHash,
      'salt': salt,
      'role': role,
      'is_active': isActive ? 1 : 0,
      'permissions': jsonEncode(permissions),
      'is_demo': isDemo ? 1 : 0,
      'created_at': DateTime.now().toIso8601String(),
    };
  }

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['id'] as String,
      username: map['username'] as String,
      passwordHash: map['password_hash'] as String,
      salt: map['salt'] as String,
      role: map['role'] as String,
      isActive: (map['is_active'] as int) == 1,
      permissions: decodePermissions(map['permissions']),
      isDemo: ((map['is_demo'] as int?) ?? 0) == 1,
    );
  }

  /// Tolerates every shape a permission list can arrive in: a decoded cloud
  /// list, a native JSON TEXT column, or a missing value (legacy rows and
  /// hash-free backups predating the column) which yields the empty list.
  static List<String> decodePermissions(Object? raw) {
    if (raw == null) return const [];
    if (raw is List) return raw.map((e) => e.toString()).toList();
    if (raw is String) {
      final text = raw.trim();
      if (text.isEmpty) return const [];
      try {
        final decoded = jsonDecode(text);
        if (decoded is List) return decoded.map((e) => e.toString()).toList();
      } catch (_) {
        // Not valid JSON: treat as no permissions rather than guessing.
      }
    }
    return const [];
  }
}
