import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../auth/features.dart';
import '../models/user.dart';
import '../util/isolate_runner.dart'
    if (dart.library.io) '../util/isolate_runner_native.dart';

/// Data-access contract for user accounts and authentication.
///
/// [SqfliteUserRepository] is the local-first implementation; the cloud
/// implementation added in the PWA milestones honours the same contract.
/// The shared role/password policy lives here as statics so both storage
/// backends and every caller agree on the exact same rules.
abstract class UserRepository {
  factory UserRepository(Database db) = SqfliteUserRepository;

  static const int defaultIterations = 210000;
  static const Set<String> roles = {'OWNER', 'CASHIER'};

  /// Role-aware minimum password length. An owner can reset passwords, read
  /// reports and restore backups, so their secret protects the whole business;
  /// a cashier signs in many times a day, so a very long password is friction.
  static const int ownerPasswordLength = 12;
  static const int cashierPasswordLength = 8;

  /// Backward-compatible floor for callers that don't know the role. Prefer
  /// [minPasswordLengthFor] everywhere the role is available.
  static const int minimumPasswordLength = cashierPasswordLength;

  static int minPasswordLengthFor(String? role) =>
      role != null && role.toUpperCase() == 'OWNER'
      ? ownerPasswordLength
      : cashierPasswordLength;

  /// Login cooldown. After [maxFailedAttempts] failures for a username, block
  /// further attempts for [loginCooldown]. This only deters someone guessing
  /// at the physical keyboard; it cannot stop an attacker who copies the
  /// SQLite file and cracks the PBKDF2 hashes offline.
  static const int maxFailedAttempts = 5;
  static const Duration loginCooldown = Duration(seconds: 30);

  Future<bool> hasUsers();

  Future<User> createFirstOwner(String username, String password);

  Future<User?> authenticate(String username, String password);

  /// Creates an account. OWNER rows ignore [permissions] (they bypass the tick
  /// list and store `[]`); a staff row is granted exactly the feature keys in
  /// [permissions], validated against the registry.
  Future<void> createUser(
    String username,
    String password,
    String role, {
    List<String> permissions = const [],
  });

  /// Seeds (once) the permanent training account. Idempotent: a no-op when a
  /// row already carries the demo flag. Called at startup and right after owner
  /// setup so every install/tenant has a non-deactivatable `demo` login.
  Future<void> ensureDemoUser();

  /// Replaces a staff account's feature ticks. Immediate on the server side
  /// (rows are read live per request) and on the next app open (session
  /// restore reloads the user). Owner rows are rejected — they bypass ticks.
  Future<void> setUserPermissions(String userId, List<String> permissions);

  Future<void> changePassword({
    required String userId,
    required String currentPassword,
    required String newPassword,
  });

  Future<void> resetPassword({
    required String targetUserId,
    required String newPassword,
    required String actingUserId,
  });

  Future<void> setUserActive({
    required String targetUserId,
    required bool active,
    required String actingUserId,
  });

  Future<List<User>> getAllUsers();

  /// Rehydrates a user for a restored session. Returns null when the account
  /// is missing or has been deactivated since sign-in, so a persisted session
  /// can never resurrect a revoked login.
  Future<User?> getById(String id);
}

class SqfliteUserRepository implements UserRepository {
  final Database _db;
  SqfliteUserRepository(this._db);

  final Map<String, _LoginGuard> _loginGuards = {};

  static const String _pbkdf2Prefix = 'pbkdf2-sha256\$v=1\$';
  static const int _legacyIterations = 10000;
  static const int _minimumIterations = 1000;
  static const int _maximumIterations = 2000000;

  /// Fixed password for the auto-created training account. The owner can reset
  /// it from the Users screen; trainees just need something stable to type.
  static const String _demoPassword = 'demo1234';

  String _generateSalt() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(16, (i) => random.nextInt(256)));
  }

  /// Derives a key with standard PBKDF2-HMAC-SHA256. On native this runs on a
  /// background isolate so the UI stays responsive during the 210k rounds; the
  /// web build resolves [runIsolated] to an inline call (browsers have no
  /// isolates, and web login is hashed server-side by `pos-api`, so this local
  /// path never runs there).
  static Future<String> _derive(String password, String salt, int iterations) {
    return runIsolated(() => _deriveKey(password, salt, iterations));
  }

  static Future<String> _deriveKey(
    String password,
    String salt,
    int iterations,
  ) async {
    final algorithm = cryptography.Pbkdf2(
      macAlgorithm: cryptography.Hmac(cryptography.Sha256()),
      iterations: iterations,
      bits: 256,
    );
    final key = await algorithm.deriveKey(
      secretKey: cryptography.SecretKey(utf8.encode(password)),
      nonce: utf8.encode(salt),
    );
    return base64.encode(await key.extractBytes());
  }

  String _formatHash(int iterations, String derived) {
    return 'pbkdf2-sha256\$v=1\$i=$iterations\$$derived';
  }

  Future<String> _hashPassword(String password, String salt) async {
    final derived = await _derive(
      password,
      salt,
      UserRepository.defaultIterations,
    );
    return _formatHash(UserRepository.defaultIterations, derived);
  }

  /// Password format used by releases before schema 5: 10,000 rounds of
  /// HMAC-SHA256 over the salt, stored as base64. Kept only to migrate
  /// existing installations; new passwords always use [_hashPassword].
  String _hashPasswordLegacy(String password, String salt) {
    final key = utf8.encode(password);
    final saltBytes = utf8.encode(salt);
    var bytes = Hmac(sha256, key).convert(saltBytes).bytes;
    for (var i = 0; i < _legacyIterations; i++) {
      bytes = Hmac(sha256, key).convert(bytes).bytes;
    }
    return base64.encode(bytes);
  }

  bool _constantTimeEquals(String left, String right) {
    final leftBytes = utf8.encode(left);
    final rightBytes = utf8.encode(right);
    if (leftBytes.length != rightBytes.length) return false;
    var difference = 0;
    for (var i = 0; i < leftBytes.length; i++) {
      difference |= leftBytes[i] ^ rightBytes[i];
    }
    return difference == 0;
  }

  Future<bool> _verifyPassword(
    String password,
    String salt,
    String storedHash,
  ) async {
    if (!storedHash.startsWith(_pbkdf2Prefix)) return false;
    final parts = storedHash.split(r'$');
    if (parts.length != 4 || parts[1] != 'v=1') return false;
    if (!parts[2].startsWith('i=')) return false;
    final iterations = int.tryParse(parts[2].substring(2));
    if (iterations == null ||
        iterations < _minimumIterations ||
        iterations > _maximumIterations) {
      return false;
    }
    final derived = await _derive(password, salt, iterations);
    return _constantTimeEquals(_formatHash(iterations, derived), storedHash);
  }

  Future<bool> _verifyUserPassword(User user, String password) async {
    if (user.passwordHash.startsWith(_pbkdf2Prefix)) {
      return _verifyPassword(password, user.salt, user.passwordHash);
    }
    return _constantTimeEquals(
      _hashPasswordLegacy(password, user.salt),
      user.passwordHash,
    );
  }

  Future<void> _upgradePasswordHash(User user, String password) async {
    final salt = _generateSalt();
    final hash = await _hashPassword(password, salt);
    await _db.update(
      'users',
      {'password_hash': hash, 'salt': salt},
      where: 'id = ?',
      whereArgs: [user.id],
    );
  }

  Future<void> _audit({
    String? userId,
    required String action,
    required String details,
  }) async {
    try {
      await _db.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': userId,
        'action': action,
        'details': details,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {
      // Auditing must never block authentication or account management.
    }
  }

  static void _validatePassword(String password, String role) {
    final min = UserRepository.minPasswordLengthFor(role);
    if (password.length < min) {
      throw Exception(
        'Password must be at least $min characters for a '
        '${role.toLowerCase()} account.',
      );
    }
  }

  void _recordFailedAttempt(String guardKey) {
    final guard = _loginGuards.putIfAbsent(guardKey, () => _LoginGuard());
    guard.failures += 1;
    if (guard.failures >= UserRepository.maxFailedAttempts) {
      guard.lockedUntil = DateTime.now().add(UserRepository.loginCooldown);
      guard.failures = 0;
    }
  }

  @override
  Future<bool> hasUsers() async {
    final result = await _db.rawQuery('SELECT COUNT(*) as count FROM users');
    return (result.first['count'] as int) > 0;
  }

  @override
  Future<User> createFirstOwner(String username, String password) async {
    final name = username.trim();
    if (name.isEmpty) {
      throw Exception('Username cannot be empty.');
    }
    _validatePassword(password, 'OWNER');

    final salt = _generateSalt();
    final hash = await _hashPassword(password, salt);
    final user = User(
      id: const Uuid().v4(),
      username: name,
      passwordHash: hash,
      salt: salt,
      role: 'OWNER',
    );

    await _db.transaction((txn) async {
      final existing = await txn.rawQuery(
        'SELECT COUNT(*) AS count FROM users',
      );
      if ((existing.first['count'] as int) > 0) {
        throw Exception('An owner account already exists.');
      }
      await txn.insert('users', user.toMap());
    });

    await _audit(
      userId: user.id,
      action: 'OWNER_CREATED',
      details: 'First owner account "$name" created.',
    );
    return user;
  }

  @override
  Future<User?> authenticate(String username, String password) async {
    final name = username.trim();
    final guardKey = name.toLowerCase();

    // Cooldown check first: don't even verify while the account is locked.
    final guard = _loginGuards[guardKey];
    final now = DateTime.now();
    if (guard != null &&
        guard.lockedUntil != null &&
        now.isBefore(guard.lockedUntil!)) {
      final secs = guard.lockedUntil!.difference(now).inSeconds + 1;
      throw Exception(
        'Too many failed attempts. Try again in '
        '$secs second${secs == 1 ? '' : 's'}.',
      );
    }

    final maps = await _db.query(
      'users',
      where: 'LOWER(username) = LOWER(?) AND is_active = 1',
      whereArgs: [name],
      limit: 1,
    );
    if (maps.isEmpty) {
      await _audit(action: 'LOGIN_FAILED', details: 'Unknown username: $name');
      _recordFailedAttempt(guardKey);
      return null;
    }

    final user = User.fromMap(maps.first);
    if (await _verifyUserPassword(user, password)) {
      _loginGuards.remove(guardKey);
      if (!user.passwordHash.startsWith(_pbkdf2Prefix)) {
        await _upgradePasswordHash(user, password);
        await _audit(
          userId: user.id,
          action: 'PASSWORD_UPGRADED',
          details: 'Legacy password hash upgraded for "${user.username}".',
        );
      }
      await _audit(
        userId: user.id,
        action: 'LOGIN_SUCCEEDED',
        details: 'User "${user.username}" signed in.',
      );
      return user;
    }

    await _audit(
      action: 'LOGIN_FAILED',
      details: 'Wrong password for username: $name',
    );
    _recordFailedAttempt(guardKey);
    return null;
  }

  @override
  Future<void> createUser(
    String username,
    String password,
    String role, {
    List<String> permissions = const [],
  }) async {
    final name = username.trim();
    if (name.isEmpty) {
      throw Exception('Username cannot be empty.');
    }
    if (name.toLowerCase() == 'demo') {
      throw Exception('That username is reserved for the demo account.');
    }
    if (!UserRepository.roles.contains(role)) {
      throw Exception('Invalid role.');
    }
    _validatePassword(password, role);

    // Owners bypass the tick list; a staff account is granted exactly the
    // validated subset it was given (unknown keys dropped, registry order).
    final perms = role == 'OWNER'
        ? kOwnerPermissions
        : normalizeFeatureKeys(permissions);

    final salt = _generateSalt();
    final hash = await _hashPassword(password, salt);
    final user = User(
      id: const Uuid().v4(),
      username: name,
      passwordHash: hash,
      salt: salt,
      role: role,
      permissions: perms,
    );

    await _db.transaction((txn) async {
      final existing = await txn.query(
        'users',
        where: 'LOWER(username) = LOWER(?)',
        whereArgs: [name],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw Exception('Username is already taken.');
      }
      await txn.insert('users', user.toMap());
    });

    await _audit(
      userId: user.id,
      action: 'USER_CREATED',
      details:
          'User "$name" created with role $role'
          '${role == 'OWNER' ? '' : ' (${perms.isEmpty ? 'no features' : perms.join(', ')})'}',
    );
  }

  @override
  Future<void> ensureDemoUser() async {
    final flagged = await _db.query(
      'users',
      columns: ['id'],
      where: 'is_demo = 1',
      limit: 1,
    );
    if (flagged.isNotEmpty) return;
    // Adopt a pre-existing 'demo' username (e.g. one created before the flag
    // existed) so the UNIQUE index can't reject the seed, else insert fresh.
    final byName = await _db.query(
      'users',
      columns: ['id'],
      where: 'LOWER(username) = ?',
      whereArgs: ['demo'],
      limit: 1,
    );
    if (byName.isNotEmpty) {
      await _db.update(
        'users',
        {'is_demo': 1},
        where: 'id = ?',
        whereArgs: [byName.first['id']],
      );
      return;
    }
    final salt = _generateSalt();
    final hash = await _hashPassword(_demoPassword, salt);
    final user = User(
      id: const Uuid().v4(),
      username: 'demo',
      passwordHash: hash,
      salt: salt,
      role: 'CASHIER',
      permissions: kDefaultStaffPermissions,
      isDemo: true,
    );
    await _db.insert('users', user.toMap());
    await _audit(
      userId: user.id,
      action: 'DEMO_USER_SEEDED',
      details: 'Training demo account created.',
    );
  }

  @override
  Future<void> setUserPermissions(
    String userId,
    List<String> permissions,
  ) async {
    final rows = await _db.query(
      'users',
      columns: ['username', 'role'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) throw Exception('User not found.');
    if (rows.first['role'] == 'OWNER') {
      throw Exception('Owner accounts bypass feature permissions.');
    }
    final normalized = normalizeFeatureKeys(permissions);
    await _db.update(
      'users',
      {'permissions': jsonEncode(normalized)},
      where: 'id = ?',
      whereArgs: [userId],
    );
    await _audit(
      userId: userId,
      action: 'USER_PERMISSIONS_SET',
      details:
          'Permissions for "${rows.first['username']}": '
          '${normalized.isEmpty ? '(none)' : normalized.join(', ')}',
    );
  }

  @override
  Future<void> changePassword({
    required String userId,
    required String currentPassword,
    required String newPassword,
  }) async {
    final maps = await _db.query(
      'users',
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (maps.isEmpty) throw Exception('User not found.');
    final user = User.fromMap(maps.first);
    _validatePassword(newPassword, user.role);
    if (!await _verifyUserPassword(user, currentPassword)) {
      throw Exception('Current password is incorrect.');
    }
    await _upgradePasswordHash(user, newPassword);
    await _audit(
      userId: user.id,
      action: 'PASSWORD_CHANGED',
      details: 'User "${user.username}" changed their password.',
    );
  }

  @override
  Future<void> resetPassword({
    required String targetUserId,
    required String newPassword,
    required String actingUserId,
  }) async {
    final actors = await _db.query(
      'users',
      columns: ['role', 'is_active', 'username'],
      where: 'id = ?',
      whereArgs: [actingUserId],
      limit: 1,
    );
    if (actors.isEmpty ||
        actors.first['role'] != 'OWNER' ||
        actors.first['is_active'] != 1) {
      throw Exception('Only an active owner can reset a password.');
    }
    final targets = await _db.query(
      'users',
      where: 'id = ?',
      whereArgs: [targetUserId],
      limit: 1,
    );
    if (targets.isEmpty) throw Exception('User not found.');
    final target = User.fromMap(targets.first);
    _validatePassword(newPassword, target.role);
    await _upgradePasswordHash(target, newPassword);
    await _audit(
      userId: actingUserId,
      action: 'PASSWORD_RESET',
      details: 'Password reset for "${target.username}".',
    );
  }

  @override
  Future<void> setUserActive({
    required String targetUserId,
    required bool active,
    required String actingUserId,
  }) async {
    if (targetUserId == actingUserId && !active) {
      throw Exception('You cannot deactivate your own account.');
    }
    final actors = await _db.query(
      'users',
      columns: ['role', 'is_active'],
      where: 'id = ?',
      whereArgs: [actingUserId],
      limit: 1,
    );
    if (actors.isEmpty ||
        actors.first['role'] != 'OWNER' ||
        actors.first['is_active'] != 1) {
      throw Exception('Only an active owner can change user status.');
    }
    final targets = await _db.query(
      'users',
      columns: ['username', 'role', 'is_active', 'is_demo'],
      where: 'id = ?',
      whereArgs: [targetUserId],
      limit: 1,
    );
    if (targets.isEmpty) throw Exception('User not found.');
    final target = targets.first;
    if (!active && ((target['is_demo'] as int?) ?? 0) == 1) {
      throw Exception('The demo account cannot be deactivated.');
    }

    await _db.transaction((txn) async {
      if (!active && target['role'] == 'OWNER') {
        final owners = await txn.rawQuery(
          "SELECT COUNT(*) AS count FROM users WHERE role = 'OWNER' AND is_active = 1",
        );
        if ((owners.first['count'] as int) <= 1) {
          throw Exception('At least one active owner is required.');
        }
      }
      await txn.update(
        'users',
        {'is_active': active ? 1 : 0},
        where: 'id = ?',
        whereArgs: [targetUserId],
      );
      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': actingUserId,
        'action': active ? 'USER_ACTIVATED' : 'USER_DEACTIVATED',
        'details':
            'Account "${target['username']}" was '
            '${active ? 'activated' : 'deactivated'}.',
        'created_at': DateTime.now().toIso8601String(),
      });
    });
  }

  @override
  Future<List<User>> getAllUsers() async {
    final maps = await _db.query('users', orderBy: 'username ASC');
    return maps.map((m) => User.fromMap(m)).toList();
  }

  /// Rehydrates a user for a restored session. Returns null when the account
  /// is missing or has been deactivated since sign-in, so a persisted session
  /// can never resurrect a revoked login.
  @override
  Future<User?> getById(String id) async {
    final maps = await _db.query(
      'users',
      where: 'id = ? AND is_active = 1',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return User.fromMap(maps.first);
  }
}

class _LoginGuard {
  int failures = 0;
  DateTime? lockedUntil;
}
