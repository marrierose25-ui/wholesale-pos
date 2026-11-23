import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:pos_contracts/pos_contracts.dart';

/// Pushes the local outbox to a Supabase (PostgREST) project.
///
/// Every entry is applied as an idempotent UPSERT keyed on `id`, so a retry
/// after a dropped connection can never double-count a sale. SQLite stays the
/// source of truth; this only mirrors the data upward for remote reporting.
///
/// It is a "sink" for exactly the entities the till enqueues: sale (plus its
/// items), shift, cash movement and void request. Reference rows (users,
/// devices, products) are deliberately NOT synced — no credentials ever leave
/// the PC — which is why the cloud mirror has no foreign keys.
class SupabaseSyncBackend implements SyncBackend {
  /// Supabase rejects its secret API keys when the request looks like it came
  /// from a browser (User-Agent heuristic). A plain server-style UA avoids the
  /// "Forbidden use of secret API key in browser" 401.
  static const String _userAgent = 'WholesalePOS-Sync/1.0';

  final String _baseUrl;
  final String _apiKey;
  final http.Client _client;

  SupabaseSyncBackend({
    required String url,
    required String key,
    http.Client? client,
  }) : _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url,
       _apiKey = key,
       _client = client ?? http.Client();

  /// Pure selection logic, unit-testable without [Platform] or DB access.
  ///
  /// Priority:
  ///  1. Return [SupabaseSyncBackend] whenever both [url] and [key] are present
  ///     AND the caller permits embedded secrets ([unsafeAllowEmbed]).
  ///  2. Fall back to [NoopSyncBackend] otherwise.
  ///
  /// The caller (in the app layer) is responsible for enforcing the mobile
  /// rule ("never embed a Supabase key in a distributable APK") — this class
  /// stays platform-agnostic.
  static SyncBackend selectBackend({
    required String url,
    required String key,
    required bool unsafeAllowEmbed,
    required bool isMobile,
  }) {
    if (url.isEmpty || key.isEmpty) return const NoopSyncBackend();
    if (isMobile && !unsafeAllowEmbed) return const NoopSyncBackend();
    return SupabaseSyncBackend(url: url, key: key);
  }

  @override
  bool get isConfigured => _baseUrl.isNotEmpty && _apiKey.isNotEmpty;

  @override
  Future<Set<String>> push(List<SyncOutboxEntry> entries) async {
    // Acked incrementally, per entry (audit 2 #25). It used to `continue` past
    // an unknown entity type and then ack the whole batch at the end, so a row
    // that was never sent looked synced. An unknown type is terminal here (this
    // legacy sink has no way to store it) and is acked with a notice; every
    // other entry is acked only after its write returned 2xx.
    final acked = <String>{};
    for (final entry in entries) {
      final table = _tableFor(entry.entityType);
      if (table == null) {
        // Unknown entity type: acknowledge but do not attempt a write.
        acked.add(entry.id);
        continue;
      }

      if (entry.operation == SyncOperations.delete) {
        await _delete(table, entry);
        acked.add(entry.id);
        continue;
      }

      final payload = entry.payload;
      switch (entry.entityType) {
        case SyncEntities.sale:
          // A sale is an aggregate: push the header row, then its line items.
          final sale = payload['sale'];
          if (sale != null) {
            await _upsert('sales', [sale as Map<String, dynamic>]);
          }
          final items = payload['items'];
          if (items is List && items.isNotEmpty) {
            await _upsert('sale_items', items.cast<Map<String, dynamic>>());
          }
        case SyncEntities.shift:
          await _upsert(table, [
            (payload['shift'] as Map).cast<String, dynamic>(),
          ]);
        case SyncEntities.cashMovement:
          await _upsert(table, [
            (payload['cash_movement'] as Map).cast<String, dynamic>(),
          ]);
        case SyncEntities.voidRequest:
          await _upsert(table, [
            (payload['void_request'] as Map).cast<String, dynamic>(),
          ]);
        default:
          break;
      }
      acked.add(entry.id);
    }
    // Every write above throws on the first failure, so reaching here means the
    // acked rows landed. Rows not in this set stay queued.
    return acked;
  }

  static String? _tableFor(String entityType) => switch (entityType) {
    SyncEntities.sale => 'sales',
    SyncEntities.shift => 'shifts',
    SyncEntities.cashMovement => 'cash_movements',
    SyncEntities.voidRequest => 'void_requests',
    _ => null,
  };

  Future<void> _upsert(String table, List<Map<String, dynamic>> rows) async {
    final uri = Uri.parse('$_baseUrl/rest/v1/$table')
        .replace(queryParameters: {'on_conflict': 'id'});
    final res = await _client.post(
      uri,
      headers: _headers(withPrefer: true),
      body: jsonEncode(rows),
    );
    _ensureOk(res, 'upsert $table');
  }

  Future<void> _delete(String table, SyncOutboxEntry entry) async {
    final uri = Uri.parse(
      '$_baseUrl/rest/v1/$table?id=eq.${Uri.encodeComponent(entry.entityId)}',
    );
    final res = await _client.delete(uri, headers: _headers());
    _ensureOk(res, 'delete $table');

    // A deleted sale must also drop its now-orphaned line items.
    if (entry.entityType == SyncEntities.sale) {
      final itemsUri = Uri.parse(
        '$_baseUrl/rest/v1/sale_items?sale_id=eq.'
        '${Uri.encodeComponent(entry.entityId)}',
      );
      final itemsRes = await _client.delete(itemsUri, headers: _headers());
      _ensureOk(itemsRes, 'delete sale_items');
    }
  }

  Map<String, String> _headers({bool withPrefer = false}) => {
    'apikey': _apiKey,
    'Authorization': 'Bearer $_apiKey',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'User-Agent': _userAgent,
    if (withPrefer) 'Prefer': 'resolution=merge-duplicates',
  };

  void _ensureOk(http.Response res, String what) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // Throwing leaves the rows queued; the next drain retries them.
      throw Exception(
        'Supabase sync failed on $what (HTTP ${res.statusCode}): ${res.body}',
      );
    }
  }

  /// This path stays one-way, by design.
  ///
  /// It writes into a mirror shaped for reporting: no foreign keys, and — as
  /// the class doc says — no users or devices, because no credentials may
  /// leave the PC. Pulling those mirror rows back into SQLite would therefore
  /// violate the local foreign keys on every sale whose cashier or device is
  /// not enrolled on this machine. Cross-device reads need the licence-gated
  /// `sync` gateway, which serves a complete, tenant-scoped page (see
  /// [SyncGatewayBackend.pull]).
  ///
  /// Returning empty rather than throwing keeps an older desktop build that
  /// still embeds a secret usable for writing: it sends but never receives,
  /// exactly as before.
  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async => const SyncPullResult.empty();
}
