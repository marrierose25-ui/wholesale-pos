import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sync_backend.dart';
import 'sync_outbox_entry.dart';
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
  final http.Client _client;

  SyncGatewayBackend({
    required String fnUrl,
    required this._licenseProvider,
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
  ///  1. Desktop with the legacy baked secret (owner's own shop PCs, keys in
  ///     a locked back-office exe) keeps the direct PostgREST path unchanged.
  ///  2. Otherwise the gateway whenever its URL is configured — every mobile
  ///     build and every buyer desktop.
  ///  3. Otherwise the legacy mobile private-use opt-in (unsafe flag + keys),
  ///     kept only so pre-gateway shop-phone builds still work if rebuilt
  ///     without a gateway URL.
  ///  4. Otherwise Noop.
  static SyncBackend selectBackend({
    required String gatewayUrl,
    required String secretUrl,
    required String secretKey,
    required bool unsafeAllowEmbed,
    required bool isMobile,
    required Future<String?> Function() licenseProvider,
  }) {
    final hasSecret = secretUrl.isNotEmpty && secretKey.isNotEmpty;
    if (!isMobile && hasSecret) {
      return SupabaseSyncBackend(url: secretUrl, key: secretKey);
    }
    if (gatewayUrl.isNotEmpty) {
      return SyncGatewayBackend(
        fnUrl: gatewayUrl,
        licenseProvider: licenseProvider,
      );
    }
    if (isMobile && unsafeAllowEmbed && hasSecret) {
      return SupabaseSyncBackend(url: secretUrl, key: secretKey);
    }
    return const NoopSyncBackend();
  }

  @override
  bool get isConfigured => _fnUrl.isNotEmpty;

  @override
  Future<Set<String>> push(List<SyncOutboxEntry> entries) async {
    final license = await _licenseProvider();
    if (license == null || license.trim().isEmpty) {
      // Not activated yet: throw so SyncService leaves rows queued. Selling
      // is unaffected; the next drain after activation will get through.
      throw StateError('Sync gateway: no activated license on this device.');
    }

    final body = jsonEncode({
      'action': 'push',
      'license': license.trim(),
      'entries': [
        for (final e in entries)
          {
            // Send the LOCAL vocabulary ('sale' etc.); the gateway maps it
            // to cloud table names, mirroring SupabaseSyncBackend._tableFor.
            'entityType': e.entityType,
            'entityId': e.entityId,
            'operation': e.operation,
            'payload': e.payload,
          },
      ],
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

    // Per-entry ack (audit #20): only mark outbox rows the server actually
    // processed. 'applied' and 'rejected' (a permanent unknown-type refusal,
    // never worth retrying) are both acked; 'failed' entries stay queued for
    // the next drain. If the server sent no results list (older function),
    // fall back to acking the whole batch like the pre-per-entry contract.
    final results = decoded is Map ? decoded['results'] : null;
    if (results is! List || results.isEmpty) {
      return entries.map((e) => e.id).toSet();
    }
    // One entity can back several queued rows (e.g. two edits to one sale);
    // map its verdict onto every outbox id sharing that entityId.
    final idsByEntity = <String, List<String>>{};
    for (final e in entries) {
      (idsByEntity[e.entityId] ??= <String>[]).add(e.id);
    }
    final acked = <String>{};
    for (final r in results.whereType<Map>()) {
      final status = r['status'];
      if (status == 'applied' || status == 'rejected') {
        acked.addAll(idsByEntity['${r['entityId']}'] ?? const <String>[]);
      }
    }
    return acked;
  }
}
