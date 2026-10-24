import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wholesale_pos_app/core/licensing/activation_client.dart';

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

    test('activateDevice surfaces the seat-limit refusal', () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'ok': false,
            'error': 'Seat limit reached.',
            'seat_limit': 3,
            'seats_used': 3,
          }),
          409,
        ),
      );
      final r = await ActivationClient(url: url, client: mock).activateDevice(
        activationCode: 'MERCA-ABCD',
        deviceFingerprint: 'fp-xyz',
        deviceName: 'Pixel',
      );
      expect(r.ok, isFalse);
      expect(r.error, 'Seat limit reached.');
      expect(r.seatLimit, 3);
      expect(r.seatsUsed, 3);
    });

    test('listDevices parses the returned array', () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'ok': true,
            'seat_limit': 3,
            'seats_used': 2,
            'devices': [
              {
                'fingerprint_masked': 'aaaa-bbbb',
                'device_name': 'PC',
                'is_self': false,
              },
              {
                'fingerprint_masked': 'cccc-dddd',
                'device_name': 'Pixel',
                'is_self': true,
                'device_fingerprint': 'full-fp-for-self',
              },
            ],
          }),
          200,
        ),
      );
      final r = await ActivationClient(
        url: url,
        client: mock,
      ).listDevices(activationCode: 'MERCA-ABCD', deviceFingerprint: 'fp-xyz');
      expect(r.error, isNull, reason: 'client should parse ok:true');
      expect(r.ok, isTrue);
      expect(r.devices, hasLength(2));
      expect(r.seatLimit, 3);
    });

    test('deactivateDevice posts target + requesting fingerprints', () async {
      late Map<String, dynamic> captured;
      final mock = MockClient((req) async {
        captured = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'ok': true}), 200);
      });
      final r = await ActivationClient(url: url, client: mock).deactivateDevice(
        activationCode: 'MERCA-ABCD',
        requestingFingerprint: 'self-fp',
        targetFingerprint: 'other-fp',
      );
      expect(r.ok, isTrue);
      expect(captured['action'], 'deactivate_device');
      expect(captured['requesting_fingerprint'], 'self-fp');
      expect(captured['target_fingerprint'], 'other-fp');
    });

    test('redeemVoucher parses seats_added and new_seat_limit', () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({'ok': true, 'seats_added': 2, 'new_seat_limit': 5}),
          200,
        ),
      );
      final r = await ActivationClient(url: url, client: mock).redeemVoucher(
        activationCode: 'MERCA-ABCD',
        deviceFingerprint: 'fp-xyz',
        voucherCode: 'V-ABCDEFGH',
      );
      expect(r.ok, isTrue);
      expect(r.seatsAdded, 2);
      expect(r.newSeatLimit, 5);
    });

    test('a network throw is wrapped, never rethrown', () async {
      final mock = MockClient((_) async => throw Exception('socket closed'));
      final r = await ActivationClient(
        url: url,
        client: mock,
      ).listDevices(activationCode: 'MERCA-ABCD', deviceFingerprint: 'fp-xyz');
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
