// Extracted verbatim from the pre-Stage-6 application implementation.
// Signatures and documentation are unchanged; only the SQLite factory
// line (which belongs to the implementation package) was removed.
import 'package:pos_core/users.dart';

abstract class UserRepository {

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
