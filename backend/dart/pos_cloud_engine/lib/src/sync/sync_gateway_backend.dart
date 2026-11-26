import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:pos_contracts/pos_contracts.dart';
import 'supabase_sync_backend.dart';

/// Pushes the local outbox through the `sync` Edge Function gateway
/// (Phase 18) instead of talking to PostgREST with a secret key.
///
/// Why this exists: an APK or a buyer's desktop build can never contain a
/// key that bypasses row-level security — anything shipped inside a
/// distributable is extractable. So the client carries only its **signed
/// license** (the same Ed25519 payload activation already stores under the
/// `license_code` setting). The gateway verifies that license server-side and
/// stamps every mirrored row with the customer_id carved inside it. The
/// client cannot address another shop's partition even maliciously, and the
/// anon key has no privileges on the mirror tables at all.
///
/// The license is read lazily on every [push] via [licenseProvider]:
///   * a device activated AFTER app start begins syncing without a restart;
///   * an un-activated device keeps rows queued (push throws, SyncService
///     swallows and retries) — nothing is ever lost or sent unauthenticated.
class SyncGatewayBackend implements SyncBackend {
  /// Settings key holding the signed license — must match `_licenseCodeKey`
  /// in main.dart's LicenseWrapper (the activation flow writes it there).
  static const String licenseSettingKey = 'license_code';

  final String _fnUrl;
  final Future<String?> Function() _licenseProvider;

  /// Supplies the per-entry actor grants. The licence authenticates the device;
  /// these delegated credentials say which signed-in users are responsible for
  /// a queued row — one primary grant plus one per actor the payload names
  /// (a finance entry's creator and completer can differ). Looked up per entry
  /// so an owner's queued edit still resolves after a cashier logs in, and
  /// never stored in the outbox payload itself.
  final SyncGrantProvider? _grantProvider;

  final http.Client _client;

  SyncGatewayBackend({
    required String fnUrl,
    required this._licenseProvider,
    this._grantProvider,
    http.Client? client,
  }) : _fnUrl = fnUrl.endsWith('/')
           ? fnUrl.substring(0, fnUrl.length - 1)
           : fnUrl,
       _client = client ?? http.Client();

  static String gatewayUrlFromEnvironment() => deriveGatewayUrl(
    explicit: const String.fromEnvironment('WHOLESALE_POS_SYNC_FN_URL'),
    licenseFnUrl: const String.fromEnvironment('WHOLESALE_POS_LICENSE_FN_URL'),
  );

  /// Pure derivation, split out so tests can cover it without dart-defines.
  static String deriveGatewayUrl({
    required String explicit,
    required String licenseFnUrl,
  }) {
    if (explicit.isNotEmpty) return explicit;
    const suffix = '/licensing';
    if (licenseFnUrl.endsWith(suffix)) {
      return '${licenseFnUrl.substring(0, licenseFnUrl.length - suffix.length)}/sync';
    }
    return '';
  }

  /// Pure selection logic, unit-testable without [Platform] or DB access.
  ///
  /// Priority:
  ///  1. The gateway whenever its URL is configured. It is the only path that
  ///     ships no key, and it stages rather than writes — a build that also
  ///     carried a legacy baked secret used to prefer the secret, keeping a
  ///     distributable key in use for no benefit (audit 2 #24).
  ///  2. Desktop with the legacy baked secret (the owner's own shop PCs, keys
  ///     in a locked back-office exe) keeps the direct PostgREST path.
  ///  3. The legacy mobile private-use opt-in (unsafe flag + keys), kept only
  ///     so pre-gateway shop-phone builds still work if rebuilt without a
  ///     gateway URL.
  ///  4. Otherwise Noop.
  static SyncBackend selectBackend({
    required String gatewayUrl,
    required String secretUrl,
    required String secretKey,
    required bool unsafeAllowEmbed,
    required bool isMobile,
    required Future<String?> Function() licenseProvider,
    SyncGrantProvider? grantProvider,
  }) {
    if (gatewayUrl.isNotEmpty) {
      return SyncGatewayBackend(
        fnUrl: gatewayUrl,
        licenseProvider: licenseProvider,
        grantProvider: grantProvider,
      );
    }
    final hasSecret = secretUrl.isNotEmpty && secretKey.isNotEmpty;
    if (!isMobile && hasSecret) {
      return SupabaseSyncBackend(url: secretUrl, key: secretKey);
    }
    if (isMobile && unsafeAllowEmbed && hasSecret) {
      return SupabaseSyncBackend(url: secretUrl, key: secretKey);
    }
    return const NoopSyncBackend();
  }

  @override
  bool get isConfigured => _fnUrl.isNotEmpty;

  @override
  Future<SyncPushOutcome> push(List<SyncOutboxEntry> entries) async {
    final license = await _licenseProvider();
    if (license == null || license.trim().isEmpty) {
      // Not activated yet: throw so SyncService leaves rows queued. Selling
      // is unaffected; the next drain after activation will get through.
      throw const SyncAuthException(
        'This device has no activation code yet, so it cannot reach the cloud.',
      );
    }

    // Build the wire entries first: the per-entry actor grant is an async
    // lookup, and a grant failure must only drop that one grant (leaving the
    // row deferred server-side), never the whole batch.
    final wireEntries = <Map<String, dynamic>>[];
    for (final e in entries) {
      SyncActorGrantSet? grants;
      final provider = _grantProvider;
      if (provider != null) {
        try {
          grants = await provider(e);
        } catch (_) {
          grants = null;
        }
      }
      final primary = grants?.primary?.trim() ?? '';
      final byActor = grants?.byActor ?? const <String, String>{};
      wireEntries.add({
        // The outbox row id, echoed back per entry so the ack marks exactly
        // the rows the server processed — two edits to one entity no longer
        // share one verdict (audit 2 #21).
        'entryId': e.id,
        // Send the LOCAL vocabulary ('sale' etc.); the gateway folds it
        // onto a staging entity and never writes a cloud table directly.
        'entityType': e.entityType,
        'entityId': e.entityId,
        'operation': e.operation,
        'payload': e.payload,
        // The opaque, server-issued delegated credential for the person who
        // queued this row. The gateway hashes it and never stores the raw
        // token; the server resolves it to a live user for every actor column.
        if (primary.isNotEmpty) 'actorGrant': primary,
        // Every actor the payload names gets its own grant slot, so the
        // server resolves creator/completer/deleter independently (a forged
        // payload id can only select WHICH grant to use, never who it is).
        if (byActor.isNotEmpty)
          'actorGrants': {
            for (final a in byActor.entries)
              if (a.value.trim().isNotEmpty) a.key: a.value.trim(),
          },
      });
    }

    final body = jsonEncode({
      'action': 'push',
      'license': license.trim(),
      'entries': wireEntries,
    });

    final res = await _client.post(
      Uri.parse(_fnUrl),
      headers: const {
        'Content-Type': 'application/json',
        // Same server-style UA the PostgREST path uses; the license — not a
        // key — authenticates this call.
        'User-Agent': 'WholesalePOS-Sync/1.0',
      },
      body: body,
    );
    if (res.statusCode == 401 || res.statusCode == 403) {
      // The licence itself was refused (expired, revoked, wrong tenant, or a
      // legacy v1 file with no tenant in it). Retrying cannot fix that, so it
      // is reported as an auth failure the operator has to act on.
      throw SyncAuthException(
        _errorOf(res.body) ??
            'The cloud refused this device (HTTP ${res.statusCode}).',
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
        'Sync gateway push failed (HTTP ${res.statusCode}): ${res.body}',
      );
    }
    // A 200 with ok:false must also throw — the client only marks rows synced
    // when the server confirms they landed.
    final decoded = jsonDecode(res.body);
    if (decoded is Map && decoded['ok'] == false) {
      throw Exception('Sync gateway rejected push: ${decoded['error']}');
    }

    // Per-entry ack (audit #20 / #21): only outbox rows the server actually
    // applied or permanently refused are marked synced. `applied` landed
    // through the till RPC and `rejected` is a permanent refusal. `stored`
    // (safe in staging but not yet applied) and `deferred` (waiting for a
    // valid actor grant) stay QUEUED: acknowledging them would drop a sale the
    // cloud has not booked, and re-pushing a staged row is idempotent. The
    // server echoes the outbox id it saw, so two queued edits to one sale no
    // longer share a single verdict; a server that predates entryId falls back
    // to the entityId mapping, and one that sends no results list leaves every
    // row queued for the next retry.
    final results = decoded is Map ? decoded['results'] : null;
    if (results is! List || results.isEmpty) {
      // No per-entry verdict means nothing is confirmed; leave every row
      // queued and retry. Returning empty (vs ack-all) is fail-safe:
      // retries are cheap, losing a sale is not.
      return SyncPushOutcome.empty;
    }
    final idsByEntity = <String, List<String>>{};
    for (final e in entries) {
      (idsByEntity[e.entityId] ??= <String>[]).add(e.id);
    }
    final known = entries.map((e) => e.id).toSet();
    final entityOf = {for (final e in entries) e.id: e.entityId};
    final acked = <String>{};
    final rejected = <SyncPushRejection>[];
    var deferred = 0;
    for (final r in results.whereType<Map>()) {
      final status = '${r['status']}';
      final entryId = '${r['entryId'] ?? ''}';
      final resolvedId = entryId.isNotEmpty && known.contains(entryId)
          ? entryId
          : (idsByEntity['${r['entityId']}'] ?? const <String>[]).firstOrNull;
      if (status == 'deferred') deferred++;
      if (resolvedId == null) continue;
      if (status == 'applied') {
        // Only a confirmed application is acked — 'stored'/'retryable'/
        // 'deferred' rows stay queued until the server actually books them.
        acked.add(resolvedId);
      } else if (status == 'rejected') {
        // A permanent refusal is quarantined by the caller with the payload
        // intact — never acked, never pruned.
        rejected.add(SyncPushRejection(
          entryId: resolvedId,
          entityId: entityOf[resolvedId] ?? '${r['entityId'] ?? ''}',
          error: '${r['error'] ?? 'rejected by server'}',
        ));
      }
    }
    return SyncPushOutcome(acked: acked, rejected: rejected, deferred: deferred);
  }

  /// Fetches every transaction recorded after [cursor] — including the ones
  /// other devices of the same tenant wrote — so a fresh login can show the
  /// whole shop's history.
  ///
  /// The first call passes no cursor and the server starts from the tenant's
  /// beginning, one page at a time ([SyncPullResult.hasMore]); the caller
  /// persists `nextCursor` after each page so a crash resumes instead of
  /// restarting. [tables] restricts a page to one table, because a keyset
  /// cursor is only ordered within a single table.
  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async {
    final license = await _licenseProvider();
    if (license == null || license.trim().isEmpty) {
      throw const SyncAuthException(
        'This device has no activation code yet, so it cannot reach the cloud.',
      );
    }

    final res = await _client.post(
      Uri.parse(_fnUrl),
      headers: const {
        'Content-Type': 'application/json',
        'User-Agent': 'WholesalePOS-Sync/1.0',
      },
      body: jsonEncode({
        'action': 'pull',
        'license': license.trim(),
        'limit': limit,
        if (tables != null && tables.isNotEmpty) 'tables': tables,
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      }),
    );
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw SyncAuthException(
        _errorOf(res.body) ??
            'The cloud refused this device (HTTP ${res.statusCode}).',
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
        'Sync gateway pull failed (HTTP ${res.statusCode}): ${res.body}',
      );
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) throw Exception('Sync gateway pull: unexpected body.');
    if (decoded['ok'] == false) {
      throw Exception('Sync gateway rejected pull: ${decoded['error']}');
    }

    final changes = <String, List<Map<String, dynamic>>>{};
    final raw = decoded['changes'];
    if (raw is Map) {
      raw.forEach((table, rows) {
        if (rows is List) {
          changes['$table'] = [
            for (final row in rows)
              if (row is Map) row.cast<String, dynamic>(),
          ];
        }
      });
    }

    final nc = decoded['next_cursor'];
    Map<String, String>? nextCursor;
    if (nc is Map && nc['received_at'] != null && nc['id'] != null) {
      nextCursor = {'received_at': '${nc['received_at']}', 'id': '${nc['id']}'};
    }

    return SyncPullResult(
      changes: changes,
      nextCursor: nextCursor,
      hasMore: decoded['has_more'] == true,
    );
  }

  /// The gateway's own wording for a refusal, so the operator sees
  /// *License format not supported by sync.* instead of a bare 401.
  static String? _errorOf(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is String && error.trim().isNotEmpty) return error.trim();
      }
    } catch (_) {
      // Not JSON (a proxy error page): fall back to the status code.
    }
    return null;
  }
}
