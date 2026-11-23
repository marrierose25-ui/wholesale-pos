import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:wholesale_pos_app/features/settings/devices_screen.dart';

// Phase 17b: buyer-facing "My devices" screen.
// Exercises the seat list, the "This device" chip on the caller's own row,
// the Deactivate action on other rows, and the voucher redeem UI. Kept at
// real phone width (390x844) so overflow regressions surface immediately.
void main() {
  const fnUrl = 'https://example.supabase.co/functions/v1/licensing';
  const selfFp =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const otherFp =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  ActivationClient clientReturning(List<Map<String, dynamic>> devices) {
    return ActivationClient(
      url: fnUrl,
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        switch (body['action']) {
          case 'list_devices':
            return http.Response(
              jsonEncode({
                'ok': true,
                'seat_limit': 3,
                'seats_used': devices.length,
                'devices': devices,
              }),
              200,
            );
          case 'deactivate_device':
            return http.Response(jsonEncode({'ok': true}), 200);
          case 'redeem_voucher':
            return http.Response(
              jsonEncode({'ok': true, 'seats_added': 2, 'new_seat_limit': 5}),
              200,
            );
        }
        return http.Response(
          jsonEncode({'ok': false, 'error': 'unknown'}),
          400,
        );
      }),
    );
  }

  Future<void> pump(
    WidgetTester tester, {
    required ActivationClient client,
    String? activationCode = 'MERCA-7Q2F-9K3X-4D8M-BN',
    String fingerprint = selfFp,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: DevicesScreen(
          activationCodeProvider: () async => activationCode,
          fingerprintProvider: () async => fingerprint,
          client: client,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists active seats and marks the current device', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      client: clientReturning([
        {
          'device_fingerprint': selfFp,
          'fingerprint_masked': 'aaaaaaaa----aaaa',
          'device_name': 'Pixel 8',
          'is_self': true,
          'last_seen_at': '2026-10-24T09:00:00Z',
        },
        {
          'device_fingerprint': otherFp,
          'fingerprint_masked': 'bbbbbbbb----bbbb',
          'device_name': 'Shop PC',
          'is_self': false,
          'last_seen_at': '2026-10-24T08:00:00Z',
        },
      ]),
    );

    expect(find.text('My devices'), findsOneWidget);
    expect(find.text('Pixel 8'), findsOneWidget);
    expect(find.text('Shop PC'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Deactivate'), findsOneWidget);
    expect(find.text('2 of 3 seats in use'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deactivating a non-self device calls the server and refreshes', (
    WidgetTester tester,
  ) async {
    final devices = <Map<String, dynamic>>[
      {
        'device_fingerprint': selfFp,
        'fingerprint_masked': 'aaaaaaaa----aaaa',
        'device_name': 'Pixel 8',
        'is_self': true,
      },
      {
        'device_fingerprint': otherFp,
        'fingerprint_masked': 'bbbbbbbb----bbbb',
        'device_name': 'Lost phone',
        'is_self': false,
      },
    ];
    await pump(tester, client: clientReturning(devices));

    await tester.tap(find.widgetWithText(TextButton, 'Deactivate'));
    await tester.pumpAndSettle();
    expect(find.text('Deactivate device?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Deactivate'));
    await tester.pumpAndSettle();

    // Confirm the mock's deactivate path fired and the list reloaded
    // without the row (we returned the same list from the mock, so the
    // Deactivate button is still present — what we assert is that the
    // flow completed without throwing and a snack was shown).
    expect(find.text('Device deactivated. Seat is now free.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('voucher redeem path shows the new seat limit', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      client: clientReturning([
        {
          'device_fingerprint': selfFp,
          'fingerprint_masked': 'aaaaaaaa----aaaa',
          'device_name': 'Pixel 8',
          'is_self': true,
        },
      ]),
    );

    await tester.enterText(find.byType(TextField), 'V-ABC12345');
    await tester.tap(find.widgetWithText(FilledButton, 'Redeem'));
    await tester.pumpAndSettle();

    expect(
      find.text('Voucher applied: 2 seat(s) added. New limit: 5.'),
      findsOneWidget,
    );
  });

  testWidgets('file-based license path shows the guidance message', (
    WidgetTester tester,
  ) async {
    await pump(tester, client: clientReturning(const []), activationCode: null);
    expect(
      find.textContaining('activated with a license file'),
      findsOneWidget,
    );
    // Voucher UI hidden in this state — nothing to redeem against.
    expect(find.widgetWithText(FilledButton, 'Redeem'), findsNothing);
  });

  testWidgets('unconfigured client surfaces the build-flag hint', (
    WidgetTester tester,
  ) async {
    await pump(tester, client: ActivationClient(url: ''));
    expect(
      find.textContaining('Licensing server is not configured'),
      findsOneWidget,
    );
  });
}
