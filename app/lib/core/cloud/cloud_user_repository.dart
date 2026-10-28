import '../models/user.dart';
import '../repositories/user_repository.dart';
import 'cloud_api_client.dart';

/// Web/PWA [UserRepository] over the `pos-api` Edge Function.
///
/// Password verification never happens here — the browser cannot hold a hash
/// and check it locally. [authenticate] hands the activation code + credentials
/// to the server, which returns a signed session token that [CloudApiClient]
/// then attaches to every authenticated call. The returned [User] carries only
/// display fields (no hash/salt are ever sent to the client, which is why the
/// [User] instances are built manually instead of via [User.fromMap]).
class CloudUserRepository implements UserRepository {
  final CloudApiClient _api;

  CloudUserRepository(this._api);

  @override
  Future<bool> hasUsers() async {
    final json = await _api.call('has_users', {
      'activation_code': _api.activationCode,
    });
    return json['has_users'] == true;
  }

  @override
  Future<User> createFirstOwner(String username, String password) async {
    final json = await _api.call('setup_owner', {
      'activation_code': _api.activationCode,
      'username': username,
      'password': password,
    });
    _captureToken(json);
    return _userFromAuthResponse(json);
  }

  @override
  Future<User?> authenticate(String username, String password) async {
    try {
      final json = await _api.call('login', {
        'activation_code': _api.activationCode,
        'username': username,
        'password': password,
      });
      _captureToken(json);
      return _userFromAuthResponse(json);
    } on CloudApiException {
      // A wrong password and an invalid activation code both surface as a
      // refusal; login returns null so the caller shows a generic error,
      // matching the native contract exactly.
      return null;
    }
  }

  @override
  Future<void> createUser(
    String username,
    String password,
    String role, {
    List<String> permissions = const [],
  }) async {
    await _api.call('create_user', {
      'username': username,
      'password': password,
      'role': role,
      'permissions': permissions,
    });
  }

  @override
  Future<void> ensureDemoUser() async {
    // The cloud demo account is seeded server-side by `pos-api` inside the
    // login / setup_owner handlers, so it already exists for any tenant whose
    // owner has signed in. Nothing to do from the browser.
  }

  @override
  Future<void> setUserPermissions(
    String userId,
    List<String> permissions,
  ) async {
    await _api.call('set_user_permissions', {
      'target_user_id': userId,
      'permissions': permissions,
    });
  }

  @override
  Future<void> changePassword({
    required String userId,
    required String currentPassword,
    required String newPassword,
  }) async {
    // The server acts on the token's own user id; `userId` is kept in the
    // signature so the native and cloud callers stay interchangeable.
    await _api.call('change_password', {
      'current_password': currentPassword,
      'new_password': newPassword,
    });
  }

  @override
  Future<void> resetPassword({
    required String targetUserId,
    required String newPassword,
    required String actingUserId,
  }) async {
    await _api.call('reset_password', {
      'target_user_id': targetUserId,
      'new_password': newPassword,
    });
  }

  @override
  Future<void> setUserActive({
    required String targetUserId,
    required bool active,
    required String actingUserId,
  }) async {
    await _api.call('set_user_active', {
      'target_user_id': targetUserId,
      'active': active,
    });
  }

  @override
  Future<List<User>> getAllUsers() async {
    final json = await _api.call('list_users');
    final rows = json['users'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().map(_userFromRow).toList();
  }

  @override
  Future<User?> getById(String id) async {
    for (final user in await getAllUsers()) {
      if (user.id == id) return user;
    }
    return null;
  }

  // ---- mapping helpers --------------------------------------------------

  void _captureToken(Map<String, dynamic> json) {
    final token = json['token'];
    if (token is String && token.isNotEmpty) _api.token = token;
  }

  User _userFromAuthResponse(Map<String, dynamic> json) => User(
    id: json['user_id'] as String,
    username: json['username'] as String,
    passwordHash: '',
    salt: '',
    role: json['role'] as String,
    permissions: User.decodePermissions(json['permissions']),
  );

  User _userFromRow(Map<String, dynamic> row) => User(
    id: row['id'] as String,
    username: row['username'] as String,
    passwordHash: '',
    salt: '',
    role: row['role'] as String,
    isActive: row['active'] == true,
    permissions: User.decodePermissions(row['permissions']),
    isDemo: row['is_demo'] == true,
  );
}
