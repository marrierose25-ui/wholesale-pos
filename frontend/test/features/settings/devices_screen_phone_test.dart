import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_cloud_engine/pos_cloud_engine.dart';
import 'package:wholesale_pos_app/features/settings/devices_screen.dart';

// Device management screen: owner-gated via pos-api. Exercises the owner
// sign-in gate, the device list (masked fingerprints only), the "This
// device" chip, and the Deactivate action keyed by registration id.
// Kept at real phone width (390x844) so overflow regressions surface.
void main() {
  const apiUrl = 'https://example.supabase.co/functions/v1/pos-api';
  const selfFp =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  CloudApiClient apiClient(List<Map<String, dynamic>> devices) {
    return CloudApiClient(
      url: apiUrl,
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        switch (body['action']) {
          case 'login':
            return http.Response(
              jsonEncode({'ok': true, 'token': 'test-jwt'}),
              200,
            );
          case 'list_devices':
            return http.Response(
              jsonEncode({
                'ok': true,
                'active_devices': devices.length,
                'devices': devices,
              }),
              200,
            );
          case 'deactivate_device':
            return http.Response(jsonEncode({'ok': true}), 200);
        }
        return http.Response(
          jsonEncode({'ok': false, 'error': 'unknown'}),
          400,
        );
      }),
    );
  }

  List<Map<String, dynamic>> sampleDevices() => [
    {
      'id': 'reg-self',
      'device_name': 'Pixel 8',
      'fingerprint_masked': 'aaaa...aaaa',
      'activation_code_masked': 'MERCA...4D8M',
      'is_self': true,
      'last_heartbeat': '2026-11-24T09:00:00Z',
    },
    {
      'id': 'reg-other',
      'device_name': 'Lost phone',
      'fingerprint_masked': 'bbbb...bbbb',
      'activation_code_masked': 'MERCA...4D8M',
      'is_self': false,
      'last_heartbeat': '2026-11-24T08:00:00Z',
    },
  ];

  Future<void> pump(
    WidgetTester tester, {
    required CloudApiClient api,
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
          api: api,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(
      find.widgetWithText(TextField, 'Owner phone number'),
      '0912345678',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'owner-password-1',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
  }

  testWidgets('requires owner sign-in before listing devices', (
    WidgetTester tester,
  ) async {
    await pump(tester, api: apiClient(sampleDevices()));
    expect(find.text('Owner sign-in required'), findsOneWidget);
    expect(find.text('Pixel 8'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'after sign-in lists devices, marks self, hides full fingerprints',
    (WidgetTester tester) async {
      await pump(tester, api: apiClient(sampleDevices()));
      await signIn(tester);

      expect(find.text('Pixel 8'), findsOneWidget);
      expect(find.text('Lost phone'), findsOneWidget);
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('Active devices (2)'), findsOneWidget);
      expect(find.textContaining('unlimited devices'), findsOneWidget);
      // Masked fingerprints only — the full 64-char fingerprint must never
      // appear in the management UI.
      expect(find.textContaining(selfFp), findsNothing);
      expect(find.widgetWithText(TextButton, 'Deactivate'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('deactivating a non-self device posts the registration id', (
    WidgetTester tester,
  ) async {
    late Map<String, dynamic> captured;
    final api = CloudApiClient(
      url: apiUrl,
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (body['action'] == 'login') {
          return http.Response(
            jsonEncode({'ok': true, 'token': 'test-jwt'}),
            200,
          );
        }
        if (body['action'] == 'list_devices') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'active_devices': 2,
              'devices': sampleDevices(),
            }),
            200,
          );
        }
        if (body['action'] == 'deactivate_device') {
          captured = body;
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        return http.Response(jsonEncode({'ok': false}), 400);
      }),
    );
    await pump(tester, api: api);
    await signIn(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Deactivate'));
    await tester.pumpAndSettle();
    expect(find.text('Deactivate device?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Deactivate'));
    await tester.pumpAndSettle();

    expect(captured['action'], 'deactivate_device');
    expect(captured['registration_id'], 'reg-other');
    expect(captured['device_fingerprint'], selfFp);
    expect(find.text('Device deactivated.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('file-based license path shows the guidance message', (
    WidgetTester tester,
  ) async {
    await pump(tester, api: apiClient(const []), activationCode: null);
    expect(
      find.textContaining('activated with a license file'),
      findsOneWidget,
    );
    expect(find.text('Owner sign-in required'), findsNothing);
  });

  testWidgets('unconfigured api surfaces the build-flag hint', (
    WidgetTester tester,
  ) async {
    await pump(tester, api: CloudApiClient(url: ''));
    expect(find.textContaining('Cloud API is not configured'), findsOneWidget);
  });
}
