import 'package:http/http.dart' as http;
import 'package:pos_cloud_engine/pos_cloud_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';

import 'actor_grant_store.dart';

/// Asks `pos-api` to mint an opaque actor grant for a signed-in user.
///
/// A device licence proves the DEVICE. It does not prove which person is at
/// the till, so the sync gateway will not trust a `cashier_id`/`created_by`
/// carried inside an outbox payload. Instead, right after a password login the
/// native client calls the public `issue_actor_grant` action with the signed
/// licence plus the same username/password it just verified locally. The
/// server re-verifies both and returns a short-lived token bound to
/// (tenant, user, device); only its hash is stored server-side.
///
/// This is strictly best-effort:
///   * offline (the normal state of a shop till) the call simply fails and the
///     outbox keeps its rows queued — selling is never blocked;
///   * a wrong password, a revoked device, or an expired licence all fail
///     closed and leave the row deferred server-side;
///   * nothing here is required for a cashier to complete a sale.
class ActorGrantService {
  final ActorGrantStore store;
  final String apiUrl;
  final Future<String?> Function() licenseProvider;

  /// Injected only so tests can avoid a real socket. Production builds use the
  /// client's default HTTP transport.
  final http.Client? client;

  const ActorGrantService({
    required this.store,
    required this.apiUrl,
    required this.licenseProvider,
    this.client,
  });

  bool get isConfigured => apiUrl.isNotEmpty;

  /// Mints and stores a grant for [user]. Returns true when a grant was saved.
  ///
  /// Never throws: a failure here must not turn a successful local login into
  /// an error dialog, and every queued row survives to retry later.
  Future<bool> acquire({
    required User user,
    required String username,
    required String password,
  }) async {
    if (!isConfigured) return false;
    if (username.isEmpty || password.isEmpty) return false;
    final license = await _license();
    if (license == null) return false;

    try {
      final api = CloudApiClient(url: apiUrl, client: client);
      final response = await api.call('issue_actor_grant', {
        'license': license,
        'username': username,
        'password': password,
      });
      final grant = response['grant'];
      if (grant is! String || grant.isEmpty) return false;
      final expiresAt = DateTime.tryParse('${response['expires_at'] ?? ''}');
      await store.save(user.id, grant: grant, expiresAt: expiresAt);
      return true;
    } catch (_) {
      // Offline, server refusal, malformed response: all leave the local
      // session usable and the outbox intact.
      return false;
    }
  }

  Future<String?> _license() async {
    try {
      final raw = await licenseProvider();
      final trimmed = raw?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } catch (_) {
      return null;
    }
  }
}
