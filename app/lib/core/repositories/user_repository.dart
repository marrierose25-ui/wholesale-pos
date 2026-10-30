import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../auth/features.dart';
import '../models/user.dart';
import '../sync/sync_outbox.dart';
import '../sync/sync_outbox_entry.dart';
import '../util/isolate_runner.dart'
    if (dart.library.io) '../util/isolate_runner_native.dart';
import '../util/phone_number.dart';

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

  /// Marker stored in `users.password_hash` for an account whose credential
  /// lives only in the cloud. It is not a valid hash, so it can never match a
  /// typed password on its own: the row exists so sales keep their cashier and
  /// reports keep a name, while sign-in goes through the cloud credential pair
  /// the sync pull writes beside it.
  static const String cloudAccountMarker = '!cloud-account';

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

  /// Creates an account. The identifier is the account's phone number: any
  /// accepted spelling is folded to the canonical 0XXXXXXXXX form. OWNER rows
  /// ignore [permissions] (they bypass the tick list and store `[]`); a staff
  /// row is granted exactly the feature keys in [permissions], validated
  /// against the registry.
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

  /// The demo password the backend just minted or rotated, if any. Only a
  /// backend that can vouch for it returns one (the cloud mints a per-tenant
  /// secret and hands it to the owner once); the local seed keeps only a hash,
  /// so it returns null and the owner sets one from the Users screen.
  Future<String?> takeDemoPassword();

  /// Replaces a staff account's feature ticks. Immediate on the server side
  /// (rows are read live per request) and on the next app open (session
  /// restore reloads the user). Owner rows are rejected — they bypass ticks.
  Future<void> setUserPermissions(String userId, List<String> permissions);

  /// Changes an account's login phone number (the identifier it signs in with).
  /// Owner-only, keeps the value unique and canonical, and refuses the demo
  /// account so `demo` stays a stable training login.
  Future<void> setUserPhone({
    required String userId,
    required String phone,
    required String actingUserId,
  });

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

  /// Removes a deactivated account from the app. An active account must be
  /// deactivated first, and the demo account and the owner's own row are
  /// protected.
  ///
  /// An account that never recorded a sale, shift, cash movement, finance entry
  /// or void request is dropped outright, which frees its phone number. One
  /// that did keeps its row (flagged, hidden from lists and login) so past
  /// sales stay attributed and reports keep the cashier's name.
  Future<void> deleteUser({
    required String targetUserId,
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

  /// A credential minted by the web POS (`pos-api`): `<iterations>$<base64>`.
  /// Its PBKDF2 is derived over the DECODED salt bytes, not over the salt text
  /// this app hashes, so the two formats cannot be read with one verifier.
  /// Accounts created or reset in the browser arrive here through sync, so this
  /// format has to be accepted or that phone number can never sign in on a till.
  static final RegExp _cloudHash = RegExp(
    r'^(\d{1,9})\$([A-Za-z0-9+/]+={0,2})$',
  );

  /// Marker for the demo-credential format. Version 2 means the demo login is
  /// no longer the published `demo1234`; it is a per-install secret whose only
  /// stored form is a hash, so nobody can sign into it until the owner sets a
  /// password they know from the Users screen. Existing databases are migrated
  /// the first time [ensureDemoUser] runs.
  static const String _demoPwVersionKey = 'demo_password_version';
  static const String _demoPwVersion = '2';
  static const String _legacyDemoPassword = 'demo1234';
  static const String _demoAlphabet = 'abcdefghijkmnpqrstuvwxyz23456789';

  static String _randomDemoPassword() {
    final random = Random.secure();
    return List<String>.generate(
      14,
      (_) => _demoAlphabet[random.nextInt(_demoAlphabet.length)],
    ).join();
  }

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
    return _deriveBytes(password, utf8.encode(salt), iterations);
  }

  /// The same derivation over raw salt bytes, which is the form the web POS
  /// stores. [Isolate.run] copies the arguments, so only plain values cross.
  static Future<String> _deriveBytes(
    String password,
    List<int> saltBytes,
    int iterations,
  ) {
    return runIsolated(() => _deriveKey(password, saltBytes, iterations));
  }

  static Future<String> _deriveKey(
    String password,
    List<int> saltBytes,
    int iterations,
  ) async {
    final algorithm = cryptography.Pbkdf2(
      macAlgorithm: cryptography.Hmac(cryptography.Sha256()),
      iterations: iterations,
      bits: 256,
    );
    final key = await algorithm.deriveKey(
      secretKey: cryptography.SecretKey(utf8.encode(password)),
      nonce: saltBytes,
    );
    return base64.encode(await key.extractBytes());
  }

  /// Decodes a stored salt, tolerating both base64 alphabets. Null when the
  /// value is empty or not base64 at all (the cloud-account marker).
  static List<int>? _decodeSalt(String salt) {
    if (salt.isEmpty) return null;
    try {
      return base64.decode(base64.normalize(salt));
    } on FormatException {
      try {
        return base64Url.decode(base64Url.normalize(salt));
      } on FormatException {
        return null;
      }
    }
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

  /// Verifies a typed password against one stored credential, dispatching on
  /// the format that credential was written in: this app's PBKDF2 row, the web
  /// POS's `<iterations>$<hash>` row, or a pre-schema-5 bare HMAC.
  Future<bool> _verifyCredential(
    String password,
    String salt,
    String storedHash,
  ) async {
    if (storedHash.isEmpty || storedHash == UserRepository.cloudAccountMarker) {
      return false;
    }
    if (storedHash.startsWith(_pbkdf2Prefix)) {
      return _verifyPassword(password, salt, storedHash);
    }
    final cloud = _cloudHash.firstMatch(storedHash);
    if (cloud != null) {
      final iterations = int.tryParse(cloud.group(1)!);
      final saltBytes = _decodeSalt(salt);
      if (iterations == null ||
          iterations < _minimumIterations ||
          iterations > _maximumIterations ||
          saltBytes == null ||
          saltBytes.isEmpty) {
        return false;
      }
      final derived = await _deriveBytes(password, saltBytes, iterations);
      return _constantTimeEquals(derived, cloud.group(2)!);
    }
    return _constantTimeEquals(_hashPasswordLegacy(password, salt), storedHash);
  }

  /// Every credential a row can be signed in with, in preference order: the one
  /// this device set, then the one the web POS issued. The two are kept apart
  /// so a password reset on either side never silently invalidates the other.
  Future<bool> _verifyRowPassword(
    Map<String, Object?> row,
    String password,
  ) async {
    final localHash = row['password_hash'] as String? ?? '';
    final localSalt = row['salt'] as String? ?? '';
    if (await _verifyCredential(password, localSalt, localHash)) return true;
    final cloudHash = row['cloud_pw_hash'] as String? ?? '';
    if (cloudHash.isEmpty) return false;
    final cloudSalt = row['cloud_pw_salt'] as String? ?? '';
    return _verifyCredential(password, cloudSalt, cloudHash);
  }

  /// Releases before schema 5 stored a bare 10,000-round HMAC and are upgraded
  /// on a successful sign-in. A cloud hash or the cloud-account marker must
  /// never be: the first is re-issued by the web POS, the second means the
  /// credential only lives there.
  static bool _isLegacyCredential(String storedHash) {
    return storedHash.isNotEmpty &&
        storedHash != UserRepository.cloudAccountMarker &&
        !storedHash.startsWith(_pbkdf2Prefix) &&
        !_cloudHash.hasMatch(storedHash);
  }

  Future<void> _upgradePasswordHash(User user, String password) async {
    final salt = _generateSalt();
    final hash = await _hashPassword(password, salt);
    final cloud = await _cloudCredential(password, salt);
    await _db.transaction((txn) async {
      await txn.update(
        'users',
        {'password_hash': hash, 'salt': salt, ...cloud},
        where: 'id = ?',
        whereArgs: [user.id],
      );
      await _enqueueUser(txn, user.id);
    });
  }

  /// The same password expressed in the format the web POS verifies:
  /// `<iterations>$<base64>` derived over the DECODED salt bytes, with the salt
  /// published as standard base64 (`pos-api` calls `atob` on it, which does not
  /// read this app's base64url spelling).
  ///
  /// It is stored beside the local pair rather than instead of it. The two
  /// derivations differ (salt text vs salt bytes), so one hash cannot serve both
  /// surfaces, and the local pair must never be replaced by a value the login
  /// path here cannot read. Publishing the cloud pair is what lets an account
  /// created at the till sign in on the web.
  ///
  /// Returns nulls when the stored salt will not decode, which is the signal to
  /// publish no credential at all rather than an unusable one.
  Future<Map<String, String?>> _cloudCredential(
    String password,
    String salt,
  ) async {
    final saltBytes = _decodeSalt(salt);
    if (saltBytes == null || saltBytes.isEmpty) {
      return const <String, String?>{
        'cloud_pw_hash': null,
        'cloud_pw_salt': null,
      };
    }
    final derived = await _deriveBytes(
      password,
      saltBytes,
      UserRepository.defaultIterations,
    );
    return <String, String?>{
      'cloud_pw_hash': '${UserRepository.defaultIterations}\$$derived',
      'cloud_pw_salt': base64.encode(saltBytes),
    };
  }

  /// Queues an account for the cloud, inside the caller's transaction.
  ///
  /// `password_hash`/`salt` are dropped: they are this app's own PBKDF2 shape,
  /// unreadable by the web and private to the device. `cloud_pw_hash`/
  /// `cloud_pw_salt` are published under the plain `pw_hash`/`pw_salt` names the
  /// cloud schema signs people in with. An account with no cloud credential
  /// rides without one and the server keeps whatever it already holds, so
  /// deactivating a cashier here can never blank their browser password.
  Future<void> _enqueueUser(DatabaseExecutor txn, String userId) async {
    final rows = await txn.query(
      'users',
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await _enqueueUserRow(txn, userId, rows.first);
  }

  /// The body of [_enqueueUser], split out so a row about to be deleted locally
  /// can still be published: the caller hands in the state it is writing.
  Future<void> _enqueueUserRow(
    DatabaseExecutor txn,
    String userId,
    Map<String, Object?> row,
  ) async {
    final out = Map<String, Object?>.from(row);
    final cloudHash = out.remove('cloud_pw_hash');
    final cloudSalt = out.remove('cloud_pw_salt');
    out.remove('password_hash');
    out.remove('salt');
    out['pw_hash'] = cloudHash;
    out['pw_salt'] = cloudSalt;
    // `users` has no updated_at column. Every change that queues the row stamps
    // it here, and the server applies newest-wins on that value — without it two
    // surfaces editing one account would have no agreed order to resolve in.
    out['updated_at'] = DateTime.now().toIso8601String();
    await SyncOutbox.upsertRow(
      txn,
      entityType: SyncEntities.user,
      entityId: userId,
      row: out,
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

  /// Folds a typed identifier to its canonical phone form, rejecting anything
  /// that is not a usable mobile number (and the reserved demo name).
  static String _requirePhone(String raw) {
    if (PhoneNumber.isDemo(raw)) {
      throw Exception('That name is reserved for the demo account.');
    }
    final phone = PhoneNumber.normalize(raw);
    if (phone == null) {
      throw Exception(PhoneNumber.invalidMessage);
    }
    return phone;
  }

  /// Settings row holding one account's failed-attempt state.
  ///
  /// In memory alone the cooldown was a suggestion: quit the app and the five
  /// attempts were five more. A cashier guessing a PIN should not get a fresh
  /// budget from a restart, so the counter and the lockout deadline live in the
  /// same SQLite file as the accounts.
  static const String _guardPrefix = 'login_guard:';

  String _guardSettingsKey(String guardKey) => '$_guardPrefix$guardKey';

  /// The live guard for [guardKey], rehydrated from the database the first time
  /// this process asks about an account.
  Future<_LoginGuard> _guardFor(String guardKey) async {
    final memo = _loginGuards[guardKey];
    if (memo != null) return memo;
    final guard = await _loadGuard(guardKey) ?? _LoginGuard();
    _loginGuards[guardKey] = guard;
    return guard;
  }

  Future<_LoginGuard?> _loadGuard(String guardKey) async {
    try {
      final rows = await _db.query(
        'settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [_guardSettingsKey(guardKey)],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final raw = rows.first['value'];
      if (raw is! String || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final until = map['locked_until'] as String?;
      return _LoginGuard()
        ..failures = (map['failures'] as num?)?.toInt() ?? 0
        ..lockedUntil = until == null ? null : DateTime.tryParse(until);
    } catch (_) {
      // A corrupt or unreadable row must never lock a real owner out.
      return null;
    }
  }

  Future<void> _persistGuard(String guardKey, _LoginGuard guard) async {
    try {
      final until = guard.lockedUntil;
      final lockLive = until != null && DateTime.now().isBefore(until);
      if (guard.failures == 0 && !lockLive) {
        await _db.delete(
          'settings',
          where: 'key = ?',
          whereArgs: [_guardSettingsKey(guardKey)],
        );
        return;
      }
      await _db.insert('settings', {
        'key': _guardSettingsKey(guardKey),
        'value': jsonEncode({
          'failures': guard.failures,
          'locked_until': lockLive ? until.toIso8601String() : null,
        }),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {
      // Failing to remember an attempt must not fail the attempt itself; the
      // in-memory guard still holds for this session.
    }
  }

  /// A successful sign-in wipes the account's history, in memory and on disk.
  Future<void> _clearGuard(String guardKey) async {
    _loginGuards.remove(guardKey);
    try {
      await _db.delete(
        'settings',
        where: 'key = ?',
        whereArgs: [_guardSettingsKey(guardKey)],
      );
    } catch (_) {
      // See _persistGuard.
    }
  }

  Future<void> _recordFailedAttempt(String guardKey) async {
    final guard = _loginGuards.putIfAbsent(guardKey, () => _LoginGuard());
    final until = guard.lockedUntil;
    // A lockout that has already run out is history; start a fresh window
    // rather than carrying the old deadline into the new count.
    if (until != null && !DateTime.now().isBefore(until)) {
      guard.lockedUntil = null;
    }
    guard.failures += 1;
    if (guard.failures >= UserRepository.maxFailedAttempts) {
      guard.lockedUntil = DateTime.now().add(UserRepository.loginCooldown);
      guard.failures = 0;
    }
    await _persistGuard(guardKey, guard);
  }

  @override
  Future<bool> hasUsers() async {
    final result = await _db.rawQuery(
      'SELECT COUNT(*) as count FROM users WHERE deleted_at IS NULL',
    );
    return (result.first['count'] as int) > 0;
  }

  @override
  Future<User> createFirstOwner(String username, String password) async {
    final name = _requirePhone(username);
    _validatePassword(password, 'OWNER');

    final salt = _generateSalt();
    final hash = await _hashPassword(password, salt);
    final cloud = await _cloudCredential(password, salt);
    final user = User(
      id: const Uuid().v4(),
      username: name,
      passwordHash: hash,
      salt: salt,
      role: 'OWNER',
    );

    await _db.transaction((txn) async {
      final existing = await txn.rawQuery(
        'SELECT COUNT(*) AS count FROM users WHERE deleted_at IS NULL',
      );
      if ((existing.first['count'] as int) > 0) {
        throw Exception('An owner account already exists.');
      }
      await txn.insert('users', {...user.toMap(), ...cloud});
      await _enqueueUser(txn, user.id);
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
    // Accept any spelling the cashier types; legacy text identifiers (created
    // before phone-number login) still resolve because they pass through as-is.
    final name = PhoneNumber.loginIdentifier(username);
    final guardKey = name.toLowerCase();
    if (name.isEmpty) return null;

    // Cooldown check first: don't even verify while the account is locked.
    // The guard is rehydrated from the settings table, so the lockout survives
    // an app restart instead of resetting on every launch.
    final guard = await _guardFor(guardKey);
    final now = DateTime.now();
    final lockedUntil = guard.lockedUntil;
    if (lockedUntil != null && now.isBefore(lockedUntil)) {
      final secs = lockedUntil.difference(now).inSeconds + 1;
      throw Exception(
        'Too many failed attempts. Try again in '
        '$secs second${secs == 1 ? '' : 's'}.',
      );
    }

    final maps = await _db.query(
      'users',
      where:
          'LOWER(username) = LOWER(?) AND is_active = 1 AND deleted_at IS NULL',
      whereArgs: [name],
      limit: 1,
    );
    if (maps.isEmpty) {
      await _audit(action: 'LOGIN_FAILED', details: 'Unknown username: $name');
      await _recordFailedAttempt(guardKey);
      return null;
    }

    final user = User.fromMap(maps.first);
    if (await _verifyRowPassword(maps.first, password)) {
      await _clearGuard(guardKey);
      if (_isLegacyCredential(user.passwordHash)) {
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
    await _recordFailedAttempt(guardKey);
    return null;
  }

  @override
  Future<void> createUser(
    String username,
    String password,
    String role, {
    List<String> permissions = const [],
  }) async {
    final name = _requirePhone(username);
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
    final cloud = await _cloudCredential(password, salt);
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
        columns: ['id', 'deleted_at'],
        where: 'LOWER(username) = LOWER(?)',
        whereArgs: [name],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final row = existing.first;
        if (row['deleted_at'] == null) {
          throw Exception('Username is already taken.');
        }
        // A deleted account still holds the number. Reuse that row instead of
        // failing on the UNIQUE index: the sales it recorded keep pointing at
        // the same cashier, and the rehired phone simply signs in again.
        final revived = user.toMap()
          ..remove('id')
          ..remove('created_at')
          ..['deleted_at'] = null
          ..addAll(cloud);
        await txn.update(
          'users',
          revived,
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        await _enqueueUser(txn, row['id'] as String);
        return;
      }
      await txn.insert('users', {...user.toMap(), ...cloud});
      await _enqueueUser(txn, user.id);
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
    // The training login is the row named `demo`, whatever else was seeded or
    // pulled alongside it: a sync pull cannot reuse the name, so a second copy
    // may exist under `demo#<id>` carrying the password the owner set in the
    // browser. Resolving the name first keeps the one password they know
    // attached to the identifier they type.
    final byName = await _db.query(
      'users',
      columns: ['id', 'is_demo'],
      where: 'LOWER(username) = ? AND deleted_at IS NULL',
      whereArgs: ['demo'],
      limit: 1,
    );
    if (byName.isNotEmpty) {
      final id = byName.first['id'] as String;
      // Adopt a pre-existing 'demo' username (e.g. one created before the flag
      // existed) so the UNIQUE index can't reject the seed.
      if (byName.first['is_demo'] != 1) {
        await _db.update(
          'users',
          {'is_demo': 1},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await _adoptCloudDemoCredential(id);
      await _retirePublishedDemoPassword(id);
      return;
    }
    final flagged = await _db.query(
      'users',
      columns: ['id'],
      where: 'is_demo = 1 AND deleted_at IS NULL',
      limit: 1,
    );
    if (flagged.isNotEmpty) {
      final id = flagged.first['id'] as String;
      await _adoptCloudDemoCredential(id);
      await _retirePublishedDemoPassword(id);
      return;
    }
    final salt = _generateSalt();
    final hash = await _hashPassword(_randomDemoPassword(), salt);
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
    await _markDemoPasswordVersion();
    await _audit(
      userId: user.id,
      action: 'DEMO_USER_SEEDED',
      details: 'Training demo account created with a per-install password.',
    );
  }

  /// Repairs installs that pulled the cloud's demo row as a SECOND account
  /// (`demo#<id>`): this till had already seeded its own `demo`, so the pull
  /// could not reuse the name, and the password the owner set in the browser
  /// ended up on the copy nobody types. Copy that credential onto the one login
  /// named `demo` — the point of a training account is one shared password.
  ///
  /// A no-op once the demo carries a cloud credential, and it never touches the
  /// local password pair.
  Future<void> _adoptCloudDemoCredential(String demoId) async {
    final own = await _db.query(
      'users',
      columns: ['cloud_pw_hash'],
      where: 'id = ?',
      whereArgs: [demoId],
      limit: 1,
    );
    if (own.isEmpty) return;
    final current = own.first['cloud_pw_hash'] as String?;
    if (current != null && current.isNotEmpty) return;

    // The donor may still hold the credential in the local pair: builds before
    // schema 15 wrote the pulled hash straight into `password_hash`.
    final donors = await _db.query(
      'users',
      columns: ['cloud_pw_hash', 'cloud_pw_salt', 'password_hash', 'salt'],
      where: 'id <> ? AND deleted_at IS NULL AND is_demo = 1',
      whereArgs: [demoId],
      orderBy: 'created_at DESC',
    );
    Map<String, Object?>? credential;
    for (final row in donors) {
      final cloudHash = (row['cloud_pw_hash'] as String?) ?? '';
      if (cloudHash.isNotEmpty) {
        credential = {
          'cloud_pw_hash': cloudHash,
          'cloud_pw_salt': row['cloud_pw_salt'],
        };
        break;
      }
      final localHash = (row['password_hash'] as String?) ?? '';
      if (_cloudHash.hasMatch(localHash)) {
        credential = {'cloud_pw_hash': localHash, 'cloud_pw_salt': row['salt']};
        break;
      }
    }
    if (credential == null) return;
    await _db.update('users', credential, where: 'id = ?', whereArgs: [demoId]);
  }

  /// Replaces the demo login's published `demo1234` with an unknowable secret,
  /// so a stale install never keeps a credential anyone can look up. Runs once
  /// per database — the marker row makes the PBKDF2 check a startup no-op.
  Future<void> _retirePublishedDemoPassword(String demoId) async {
    final marked = await _db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_demoPwVersionKey],
      limit: 1,
    );
    if (marked.isNotEmpty && marked.first['value'] == _demoPwVersion) return;

    final rows = await _db.query(
      'users',
      where: 'id = ?',
      whereArgs: [demoId],
      limit: 1,
    );
    if (rows.isNotEmpty &&
        await _verifyRowPassword(rows.first, _legacyDemoPassword)) {
      final salt = _generateSalt();
      final hash = await _hashPassword(_randomDemoPassword(), salt);
      await _db.update(
        'users',
        {'password_hash': hash, 'salt': salt},
        where: 'id = ?',
        whereArgs: [demoId],
      );
      await _audit(
        action: 'PASSWORD_RESET',
        details: 'Demo account password replaced: the published default was retired.',
      );
    }
    await _markDemoPasswordVersion();
  }

  Future<void> _markDemoPasswordVersion() async {
    await _db.insert('settings', {
      'key': _demoPwVersionKey,
      'value': _demoPwVersion,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// The local seed keeps only the demo password's hash, so there is never a
  /// value to hand back: an owner sets the training password from Users.
  @override
  Future<String?> takeDemoPassword() async => null;

  @override
  Future<void> setUserPermissions(
    String userId,
    List<String> permissions,
  ) async {
    final rows = await _db.query(
      'users',
      columns: ['username', 'role'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) throw Exception('User not found.');
    if (rows.first['role'] == 'OWNER') {
      throw Exception('Owner accounts bypass feature permissions.');
    }
    final normalized = normalizeFeatureKeys(permissions);
    await _db.transaction((txn) async {
      await txn.update(
        'users',
        {'permissions': jsonEncode(normalized)},
        where: 'id = ?',
        whereArgs: [userId],
      );
      await _enqueueUser(txn, userId);
    });
    await _audit(
      userId: userId,
      action: 'USER_PERMISSIONS_SET',
      details:
          'Permissions for "${rows.first['username']}": '
          '${normalized.isEmpty ? '(none)' : normalized.join(', ')}',
    );
  }

  @override
  Future<void> setUserPhone({
    required String userId,
    required String phone,
    required String actingUserId,
  }) async {
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
      throw Exception('Only an active owner can change a phone number.');
    }
    final canonical = _requirePhone(phone);
    final targets = await _db.query(
      'users',
      columns: ['username', 'is_demo'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [userId],
      limit: 1,
    );
    if (targets.isEmpty) throw Exception('User not found.');
    if (((targets.first['is_demo'] as int?) ?? 0) == 1) {
      throw Exception('The demo account keeps its demo login.');
    }
    final clash = await _db.query(
      'users',
      columns: ['id'],
      where: 'LOWER(username) = LOWER(?) AND id <> ?',
      whereArgs: [canonical, userId],
      limit: 1,
    );
    if (clash.isNotEmpty) {
      throw Exception('That phone number is already in use.');
    }
    await _db.transaction((txn) async {
      await txn.update(
        'users',
        {'username': canonical},
        where: 'id = ?',
        whereArgs: [userId],
      );
      await _enqueueUser(txn, userId);
    });
    await _audit(
      userId: actingUserId,
      action: 'USER_PHONE_CHANGED',
      details:
          'Login phone for "${targets.first['username']}" is now "$canonical".',
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
    if (!await _verifyRowPassword(maps.first, currentPassword)) {
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
      where: 'id = ? AND deleted_at IS NULL',
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
      where: 'id = ? AND deleted_at IS NULL',
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
      await _enqueueUser(txn, targetUserId);
    });
  }

  @override
  Future<void> deleteUser({
    required String targetUserId,
    required String actingUserId,
  }) async {
    if (targetUserId == actingUserId) {
      throw Exception('You cannot delete your own account.');
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
      throw Exception('Only an active owner can delete an account.');
    }
    final targets = await _db.query(
      'users',
      columns: ['username', 'role', 'is_active', 'is_demo'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [targetUserId],
      limit: 1,
    );
    if (targets.isEmpty) throw Exception('User not found.');
    final target = targets.first;
    if (((target['is_demo'] as int?) ?? 0) == 1) {
      throw Exception('The demo account cannot be deleted.');
    }
    if (target['is_active'] == 1) {
      throw Exception('Deactivate the account before deleting it.');
    }

    // Anything this account touched is a financial record: the FK forbids
    // dropping the row, and dropping it would blank the cashier on old sales.
    // The count and the write share one transaction so a sale landing in between
    // can never leave the delete pointing at a newly referenced row.
    await _db.transaction((txn) async {
      final history = await txn.rawQuery(
        '''
      SELECT
        (SELECT COUNT(*) FROM sales WHERE cashier_id = ?) +
        (SELECT COUNT(*) FROM shifts WHERE cashier_id = ?) +
        (SELECT COUNT(*) FROM cash_movements WHERE user_id = ?) +
        (SELECT COUNT(*) FROM finance_entries
          WHERE created_by = ? OR completed_by = ?) +
        (SELECT COUNT(*) FROM void_requests
          WHERE requested_by = ? OR decided_by = ?) AS count
      ''',
        [
          targetUserId,
          targetUserId,
          targetUserId,
          targetUserId,
          targetUserId,
          targetUserId,
          targetUserId,
        ],
      );
      final kept = (history.first['count'] as int) > 0;

      if (kept) {
        await txn.update(
          'users',
          {'deleted_at': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [targetUserId],
        );
        await _enqueueUser(txn, targetUserId);
      } else {
        // The row had no history here, so it is dropped outright. The cloud
        // still gets the bin rather than a DELETE: this device can only prove
        // the account is record-free in its own ledger, and the tenant's other
        // registers may hold sales for it. A binned row hides from every
        // browser list the same way a deleted one does.
        final binned = Map<String, Object?>.from(targets.first)
          ..['deleted_at'] = DateTime.now().toIso8601String();
        await _enqueueUserRow(txn, targetUserId, binned);
        await txn.delete('users', where: 'id = ?', whereArgs: [targetUserId]);
      }
      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': actingUserId,
        'action': 'USER_DELETED',
        'details':
            'Account "${target['username']}" was deleted'
            '${kept ? ' (history retained)' : ''}.',
        'created_at': DateTime.now().toIso8601String(),
      });
    });
  }

  @override
  Future<List<User>> getAllUsers() async {
    final maps = await _db.query(
      'users',
      where: 'deleted_at IS NULL',
      orderBy: 'username ASC',
    );
    return maps.map((m) => User.fromMap(m)).toList();
  }

  /// Rehydrates a user for a restored session. Returns null when the account
  /// is missing or has been deactivated since sign-in, so a persisted session
  /// can never resurrect a revoked login.
  @override
  Future<User?> getById(String id) async {
    final maps = await _db.query(
      'users',
      where: 'id = ? AND is_active = 1 AND deleted_at IS NULL',
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
