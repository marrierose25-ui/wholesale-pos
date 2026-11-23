import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_cloud_engine/pos_cloud_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';

SyncOutboxEntry _entry({
  required String entityType,
  required String entityId,
  required Map<String, Object?> payload,
  String operation = SyncOperations.upsert,
}) {
  return SyncOutboxEntry(
    id: 'outbox-${uniqueId()}',
    entityType: entityType,
    entityId: entityId,
    operation: operation,
    payloadJson: jsonEncode(payload),
    createdAt: DateTime.now(),
  );
}

// Avoids the leading-underscore lint for a local helper used inside tests.
int _counter = 0;
String uniqueId() => '${_counter++}';

void main() {
  final salePayload = <String, Object?>{
    'sale': {
      'id': 'sale-1',
      'receipt_number': 'REC-1',
      'total_minor_units': 5000,
      'status': 'COMPLETED',
      'created_at': '2026-10-22T09:00:00.000',
    },
    'items': [
      {
        'id': 'item-1',
        'sale_id': 'sale-1',
        'product_id': 'prod-1',
        'product_name_snapshot': 'Sugar',
        'unit_price_snapshot_minor_units': 5000,
        'quantity_text': '1',
        'line_total_minor_units': 5000,
      },
    ],
  };

  test('isConfigured is false when url or key is missing', () {
    expect(SupabaseSyncBackend(url: '', key: 'k').isConfigured, isFalse);
    expect(
      SupabaseSyncBackend(url: 'https://x.supabase.co', key: '').isConfigured,
      isFalse,
    );
  });

  test(
    'a sale pushes its header row then its items to the right tables',
    () async {
      final calls = <http.Request>[];
      final client = MockClient((req) async {
        calls.add(req);
        return http.Response('[]', 201);
      });
      final backend = SupabaseSyncBackend(
        url: 'https://proj.supabase.co',
        key: 'sb_test',
        client: client,
      );

      await backend.push([
        _entry(
          entityType: SyncEntities.sale,
          entityId: 'sale-1',
          payload: salePayload,
        ),
      ]);

      expect(calls, hasLength(2));
      expect(calls[0].method, 'POST');
      expect(calls[0].url.path, '/rest/v1/sales');
      expect(calls[0].url.queryParameters['on_conflict'], 'id');
      final saleBody = jsonDecode(calls[0].body) as List;
      expect((saleBody.single as Map)['id'], 'sale-1');

      expect(calls[1].url.path, '/rest/v1/sale_items');
      final itemsBody = jsonDecode(calls[1].body) as List;
      expect(itemsBody, hasLength(1));
    },
  );

  test(
    'upserts send the merge-duplicates preference and a server user-agent',
    () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response('[]', 201);
      });
      final backend = SupabaseSyncBackend(
        url: 'https://proj.supabase.co',
        key: 'sb_test',
        client: client,
      );

      await backend.push([
        _entry(
          entityType: SyncEntities.shift,
          entityId: 'shift-1',
          payload: {
            'shift': {
              'id': 'shift-1',
              'status': 'OPEN',
              'opened_at': '2026-10-22T08:00:00.000',
            },
          },
        ),
      ]);

      expect(captured.url.path, '/rest/v1/shifts');
      expect(captured.headers['Prefer'], 'resolution=merge-duplicates');
      // Must NOT look like a browser, or Supabase blocks the secret key.
      expect(captured.headers['User-Agent'], 'WholesalePOS-Sync/1.0');
      expect(captured.headers['Authorization'], 'Bearer sb_test');
    },
  );

  test('a void_request pushes to void_requests only', () async {
    final paths = <String>[];
    final client = MockClient((req) async {
      paths.add(req.url.path);
      return http.Response('{}', 201);
    });
    final backend = SupabaseSyncBackend(
      url: 'https://proj.supabase.co/', // trailing slash must be tolerated
      key: 'sb_test',
      client: client,
    );

    await backend.push([
      _entry(
        entityType: SyncEntities.voidRequest,
        entityId: 'vr-1',
        payload: {
          'void_request': {
            'id': 'vr-1',
            'sale_id': 'sale-1',
            'status': 'PENDING',
          },
        },
      ),
    ]);

    expect(paths, ['/rest/v1/void_requests']);
  });

  test('a non-2xx response throws so the rows stay queued', () async {
    final client = MockClient((req) async => http.Response('boom', 500));
    final backend = SupabaseSyncBackend(
      url: 'https://proj.supabase.co',
      key: 'sb_test',
      client: client,
    );

    expect(
      () => backend.push([
        _entry(
          entityType: SyncEntities.cashMovement,
          entityId: 'cm-1',
          payload: {
            'cash_movement': {'id': 'cm-1', 'amount_minor_units': 500},
          },
        ),
      ]),
      throwsException,
    );
  });

  test('deleting a sale also deletes its line items', () async {
    final reqs = <http.Request>[];
    final client = MockClient((req) async {
      reqs.add(req);
      return http.Response('', 204);
    });
    final backend = SupabaseSyncBackend(
      url: 'https://proj.supabase.co',
      key: 'sb_test',
      client: client,
    );

    await backend.push([
      _entry(
        entityType: SyncEntities.sale,
        entityId: 'sale-1',
        operation: SyncOperations.delete,
        payload: {},
      ),
    ]);

    expect(reqs.map((r) => r.method), ['DELETE', 'DELETE']);
    expect(reqs[0].url.path, '/rest/v1/sales');
    expect(reqs[0].url.queryParameters['id'], 'eq.sale-1');
    expect(reqs[1].url.path, '/rest/v1/sale_items');
    expect(reqs[1].url.queryParameters['sale_id'], 'eq.sale-1');
  });
}
