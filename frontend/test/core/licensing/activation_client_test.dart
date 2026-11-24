import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_local_engine/pos_local_engine.dart';

void main() {
  const url = 'https://example.supabase.co/functions/v1/licensing';

  group('ActivationClient', () {
    test('is not configured when the URL is empty', () {
      final c = ActivationClient(url: '');
      expect(c.isConfigured, isFalse);
    });

    test('activateDevice posts the right body and parses success', () async {
      late Map<String, dynamic> captured;
      final mock = MockClient((req) async {
        captured = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'ok': true,
            'license_code': 'payload.signature',
            'expires_at': '2031-01-01T00:00:00Z',
            'seat_limit': 3,
            'seats_used': 2,
          }),
          200,
        );
      });
      final client = ActivationClient(url: url, client: mock);

      final r = await client.activateDevice(
        activationCode: 'MERCA-ABCD',
        deviceFingerprint: 'fp-xyz',
        deviceName: 'Pixel 8',
      );

      expect(captured['action'], 'activate_device');
      expect(captured['activation_code'], 'MERCA-ABCD');
      expect(captured['device_fingerprint'], 'fp-xyz');
      expect(captured['device_name'], 'Pixel 8');
      expect(r.ok, isTrue);
      expect(r.licenseCode, 'payload.signature');
      expect(r.seatLimit, 3);
      expect(r.seatsUsed, 2);
      expect(r.expiresAt, DateTime.utc(2031));
    });

    test('activateDevice surfaces a server refusal', () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'ok': false,
            'error': 'License revoked.',
            'seat_limit': 3,
            'seats_used': 3,
          }),
          403,
        ),
      );
      final r = await ActivationClient(url: url, client: mock).activateDevice(
        activationCode: 'MERCA-ABCD',
        deviceFingerprint: 'fp-xyz',
        deviceName: 'Pixel',
      );
      expect(r.ok, isFalse);
      expect(r.error, 'License revoked.');
      expect(r.seatLimit, 3);
      expect(r.seatsUsed, 3);
    });

    test('activateDevice surfaces the rate-limit refusal', () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'ok': false,
            'error': 'Too many attempts. Retry in 600s.',
            'retry_after_seconds': 600,
          }),
          429,
        ),
      );
      final r = await ActivationClient(url: url, client: mock).activateDevice(
        activationCode: 'MERCA-ABCD',
        deviceFingerprint: 'fp-xyz',
        deviceName: 'Pixel',
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('Too many attempts'));
    });

    test('a network throw is wrapped, never rethrown', () async {
      final mock = MockClient((_) async => throw Exception('socket closed'));
      final r = await ActivationClient(url: url, client: mock).activateDevice(
        activationCode: 'MERCA-ABCD',
        deviceFingerprint: 'fp-xyz',
        deviceName: 'Pixel',
      );
      expect(r.ok, isFalse);
      expect(r.error, 'Could not reach the licensing server.');
    });

    test('unconfigured client refuses without throwing', () async {
      final r = await ActivationClient(url: '').activateDevice(
        activationCode: 'MERCA-ABCD',
        deviceFingerprint: 'fp',
        deviceName: 'x',
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('not configured'));
    });
  });
}
