import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wholesale_pos_app/core/sync/supabase_sync_backend.dart';
import 'package:wholesale_pos_app/core/sync/sync_backend.dart';
import 'package:wholesale_pos_app/core/sync/sync_gateway_backend.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox_entry.dart';

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
  const gateway = 'https://example.supabase.co/functions/v1/sync';
  const license = 'payload.signature';

  Future<String?> Function() licenseProviding(String? value) =>
      () async => value;

  group('deriveGatewayUrl', () {
    test('explicit define wins', () {
      expect(
        SyncGatewayBackend.deriveGatewayUrl(
          explicit: 'https://custom/sync',
          licenseFnUrl: 'https://x/functions/v1/licensing',
        ),
        'https://custom/sync',
      );
    });

    test('derived from the licensing URL by swapping the last segment', () {
      expect(
        SyncGatewayBackend.deriveGatewayUrl(
          explicit: '',
          licenseFnUrl: 'https://x.supabase.co/functions/v1/licensing',
        ),
        'https://x.supabase.co/functions/v1/sync',
      );
    });

    test('no URL at all stays empty (Noop path)', () {
      expect(
        SyncGatewayBackend.deriveGatewayUrl(explicit: '', licenseFnUrl: ''),
        '',
      );
      // A licensing URL that is not the canonical /licensing endpoint must
      // not be guessed at — sync stays off rather than aiming at junk.
      expect(
        SyncGatewayBackend.deriveGatewayUrl(
          explicit: '',
          licenseFnUrl: 'https://x/api/other',
        ),
        '',
      );
    });
  });

  group('selectBackend priority', () {
    test(
      'desktop with a gateway URL prefers the gateway over a baked secret',
      () {
        // Audit 2 #24: a build carrying both used to take the secret path,
        // keeping a distributable key in use for no benefit.
        final backend = SyncGatewayBackend.selectBackend(
          gatewayUrl: gateway,
          secretUrl: 'https://example.supabase.co',
          secretKey: 'sb_secret_test',
          unsafeAllowEmbed: false,
          isMobile: false,
          licenseProvider: licenseProviding(license),
        );
        expect(backend, isA<SyncGatewayBackend>());
      },
    );

    test('desktop without a gateway URL keeps the legacy secret path', () {
      final backend = SyncGatewayBackend.selectBackend(
        gatewayUrl: '',
        secretUrl: 'https://example.supabase.co',
        secretKey: 'sb_secret_test',
        unsafeAllowEmbed: false,
        isMobile: false,
        licenseProvider: licenseProviding(license),
      );
      expect(backend, isA<SupabaseSyncBackend>());
    });

    test('phone prefers the gateway even when a secret is baked in', () {
      // The whole point of Phase 18: no distributable uses the secret path.
      final backend = SyncGatewayBackend.selectBackend(
        gatewayUrl: gateway,
        secretUrl: 'https://example.supabase.co',
        secretKey: 'sb_secret_test',
        unsafeAllowEmbed: true, // even with the legacy opt-in flag on
        isMobile: true,
        licenseProvider: licenseProviding(license),
      );
      expect(backend, isA<SyncGatewayBackend>());
      expect(backend.isConfigured, isTrue);
    });

    test('desktop without secret but with gateway uses the gateway', () {
      final backend = SyncGatewayBackend.selectBackend(
        gatewayUrl: gateway,
        secretUrl: '',
        secretKey: '',
        unsafeAllowEmbed: false,
        isMobile: false,
        licenseProvider: licenseProviding(license),
      );
      expect(backend, isA<SyncGatewayBackend>());
    });

    test('no gateway and no secret -> Noop', () {
      final backend = SyncGatewayBackend.selectBackend(
        gatewayUrl: '',
        secretUrl: '',
        secretKey: '',
        unsafeAllowEmbed: true,
        isMobile: true,
        licenseProvider: licenseProviding(license),
      );
      expect(backend, isA<NoopSyncBackend>());
    });

    test(
      'legacy mobile private-use path survives only WITHOUT a gateway URL',
      () {
        final backend = SyncGatewayBackend.selectBackend(
          gatewayUrl: '',
          secretUrl: 'https://example.supabase.co',
          secretKey: 'sb_secret_test',
          unsafeAllowEmbed: true,
          isMobile: true,
          licenseProvider: licenseProviding(license),
        );
        expect(backend, isA<SupabaseSyncBackend>());
      },
    );
  });

  group('push', () {
    test('missing license throws before any HTTP call (rows stay queued)', () {
      var called = false;
      final backend = SyncGatewayBackend(
        fnUrl: gateway,
        licenseProvider: licenseProviding(null),
        client: MockClient((request) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );
      expect(
        backend.push([
          _entry(entityType: SyncEntities.sale, entityId: 's1', payload: {}),
        ]),
        throwsA(isA<StateError>()),
      );
      // Give the future a tick so if the guard were missing, `called` flips.
      return Future<void>(() => Future.delayed(Duration.zero)).then((_) {
        expect(called, isFalse);
      });
    });

    test(
      'sends action=push with the license and LOCAL entity vocabulary',
      () async {
        late http.Request captured;
        final backend = SyncGatewayBackend(
          fnUrl: gateway,
          licenseProvider: licenseProviding(license),
          client: MockClient((request) async {
            captured = request;
            return http.Response('{"ok":true,"applied":1}', 200);
          }),
        );
        await backend.push([
          _entry(
            entityType: SyncEntities.sale,
            entityId: 'sale-1',
            payload: {
              'sale': {'id': 'sale-1', 'total_minor_units': 5000},
              'items': [
                {'id': 'item-1', 'sale_id': 'sale-1'},
              ],
            },
          ),
        ]);

        expect(captured.method, 'POST');
        expect(captured.url.toString(), gateway);
        expect(captured.headers['Content-Type'], 'application/json');
        // No apikey/secret anywhere: the license IS the credential.
        expect(captured.headers['apikey'], isNull);

        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body['action'], 'push');
        expect(body['license'], license);
        final entries = body['entries'] as List;
        expect(entries, hasLength(1));
        final e = entries.first as Map<String, dynamic>;
        expect(e['entityType'], 'sale'); // local vocabulary, folded server-side
        expect(e['entityId'], 'sale-1');
        expect(e['operation'], SyncOperations.upsert);
        // The outbox id travels with the entry so the ack can be exact.
        expect(e['entryId'], isNotEmpty);
        expect((e['payload'] as Map)['sale'], isNotNull);
      },
    );

    test('non-2xx throws so SyncService leaves rows queued', () {
      final backend = SyncGatewayBackend(
        fnUrl: gateway,
        licenseProvider: licenseProviding(license),
        client: MockClient((_) async => http.Response('BOOT_ERROR', 503)),
      );
      expect(
        backend.push([
          _entry(entityType: SyncEntities.shift, entityId: 'x', payload: {}),
        ]),
        throwsA(isA<Exception>()),
      );
    });

    test(
      'HTTP 200 with ok:false also throws (never mark-synced on refusal)',
      () async {
        final backend = SyncGatewayBackend(
          fnUrl: gateway,
          licenseProvider: licenseProviding('expired.license'),
          client: MockClient(
            (_) async =>
                http.Response('{"ok":false,"error":"License expired."}', 200),
          ),
        );
        expect(
          backend.push([
            _entry(
              entityType: SyncEntities.cashMovement,
              entityId: 'x',
              payload: {},
            ),
          ]),
          throwsA(isA<Exception>()),
        );
      },
    );

    test('ok:true completes without throwing', () async {
      final backend = SyncGatewayBackend(
        fnUrl: gateway,
        licenseProvider: licenseProviding(license),
        client: MockClient(
          (_) async => http.Response('{"ok":true,"applied":2}', 200),
        ),
      );
      await backend.push([
        _entry(
          entityType: SyncEntities.sale,
          entityId: 's',
          payload: {
            'sale': {'id': 's'},
          },
        ),
        _entry(
          entityType: SyncEntities.voidRequest,
          entityId: 'v',
          payload: {
            'void_request': {'id': 'v'},
          },
        ),
      ]);
    });

    test(
      'acks only server-confirmed entries; a failed one stays queued (#20)',
      () async {
        final applied = _entry(
          entityType: SyncEntities.sale,
          entityId: 'sale-ok',
          payload: {
            'sale': {'id': 'sale-ok'},
          },
        );
        final rejected = _entry(
          entityType: 'nonsense',
          entityId: 'unknown-1',
          payload: {},
        );
        final failed = _entry(
          entityType: SyncEntities.shift,
          entityId: 'shift-bad',
          payload: {
            'shift': {'id': 'shift-bad'},
          },
        );
        final backend = SyncGatewayBackend(
          fnUrl: gateway,
          licenseProvider: licenseProviding(license),
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'ok': true,
                'applied': 1,
                'results': [
                  {'entityId': 'sale-ok', 'status': 'applied'},
                  {
                    'entityId': 'unknown-1',
                    'status': 'rejected',
                    'error': 'unknown entity type',
                  },
                  {
                    'entityId': 'shift-bad',
                    'status': 'failed',
                    'error': 'upsert shifts: boom',
                  },
                ],
              }),
              200,
            ),
          ),
        );

        final acked = await backend.push([applied, rejected, failed]);

        // applied + rejected are acked (never retry a permanent rejection);
        // the transiently-failed entry is left queued for the next drain.
        expect(acked, {applied.id, rejected.id});
        expect(acked.contains(failed.id), isFalse);
      },
    );

    test('no results list falls back to acking the whole batch', () async {
      final a = _entry(
        entityType: SyncEntities.sale,
        entityId: 's1',
        payload: {
          'sale': {'id': 's1'},
        },
      );
      final backend = SyncGatewayBackend(
        fnUrl: gateway,
        licenseProvider: licenseProviding(license),
        client: MockClient(
          (_) async => http.Response('{"ok":true,"stored":1}', 200),
        ),
      );
      expect(await backend.push([a]), {a.id});
    });

    test(
      'the echoed entryId acks that row alone, not its whole entity',
      () async {
        // Two queued edits to one sale: only the row the server names is acked
        // (audit 2 #21). The second stays queued for the next drain.
        final first = _entry(
          entityType: SyncEntities.sale,
          entityId: 'sale-shared',
          payload: {
            'sale': {'id': 'sale-shared'},
          },
        );
        final second = _entry(
          entityType: SyncEntities.sale,
          entityId: 'sale-shared',
          payload: {
            'sale': {'id': 'sale-shared'},
          },
        );
        final backend = SyncGatewayBackend(
          fnUrl: gateway,
          licenseProvider: licenseProviding(license),
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'ok': true,
                'stored': 2,
                'results': [
                  {
                    'entryId': first.id,
                    'entityId': 'sale-shared',
                    'status': 'applied',
                  },
                  {
                    'entryId': second.id,
                    'entityId': 'sale-shared',
                    'status': 'failed',
                    'error': 'boom',
                  },
                ],
              }),
              200,
            ),
          ),
        );

        expect(await backend.push([first, second]), {first.id});
      },
    );

    test('a stored-but-not-yet-applied entry is acked', () async {
      final e = _entry(
        entityType: SyncEntities.sale,
        entityId: 's-staged',
        payload: {
          'sale': {'id': 's-staged'},
        },
      );
      final backend = SyncGatewayBackend(
        fnUrl: gateway,
        licenseProvider: licenseProviding(license),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'ok': true,
              'stored': 1,
              'results': [
                {'entryId': e.id, 'entityId': 's-staged', 'status': 'stored'},
              ],
            }),
            200,
          ),
        ),
      );
      expect(await backend.push([e]), {e.id});
    });
  });
}
