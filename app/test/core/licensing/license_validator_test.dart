import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/licensing/license_validator.dart';

Object? canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: canonical(value[key])};
  }
  if (value is List) return value.map(canonical).toList();
  return value;
}

void main() {
  late Directory directory;
  late SimpleKeyPairData pair;
  late String publicHex;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('license-test-');
    final generated = await Ed25519().newKeyPair();
    pair = await generated.extract();
    publicHex = pair.publicKey.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<Map<String, dynamic>?> validate(Map<String, Object?> payload) async {
    final bytes = utf8.encode(jsonEncode(canonical(payload)));
    final signature = await Ed25519().sign(bytes, keyPair: pair);
    final path = '${directory.path}${Platform.pathSeparator}license.key';
    await File(path).writeAsString(
      '${base64Url.encode(bytes)}.${base64Url.encode(signature.bytes)}',
    );
    final previous = Directory.current;
    Directory.current = directory;
    try {
      return await LicenseValidator.validateLicense(
        hardwareId: 'test-device',
        now: DateTime.utc(2030),
        verificationKeyHex: publicHex,
      );
    } finally {
      Directory.current = previous;
    }
  }

  Future<Map<String, dynamic>?> validateTamperedPayload(
    Map<String, Object?> payload,
  ) async {
    final originalBytes = utf8.encode(jsonEncode(canonical(payload)));
    final signature = await Ed25519().sign(originalBytes, keyPair: pair);
    final changed = Map<String, Object?>.from(payload)
      ..['entitlements'] = ['pos', 'admin'];
    final changedBytes = utf8.encode(jsonEncode(canonical(changed)));
    final path = '${directory.path}${Platform.pathSeparator}license.key';
    await File(path).writeAsString(
      '${base64Url.encode(changedBytes)}.${base64Url.encode(signature.bytes)}',
    );
    final previous = Directory.current;
    Directory.current = directory;
    try {
      return await LicenseValidator.validateLicense(
        hardwareId: 'test-device',
        now: DateTime.utc(2030),
        verificationKeyHex: publicHex,
      );
    } finally {
      Directory.current = previous;
    }
  }

  Map<String, Object?> payload() => {
    'format': 'wholesale-pos-license',
    'version': 1,
    'product': 'wholesale_pos',
    'entitlements': ['pos'],
    'hardware_id': 'test-device',
    'issued_at': '2029-01-01T00:00:00Z',
    'expires_at': '2031-01-01T00:00:00Z',
  };

  test('accepts a valid Ed25519 license', () async {
    expect(await validate(payload()), containsPair('product', 'wholesale_pos'));
  });

  test('rejects a modified payload and wrong hardware ID', () async {
    expect(
      (await validateTamperedPayload(payload()))?['error'],
      'Invalid license signature.',
    );
    expect(
      (await validate(payload()..['hardware_id'] = 'other-device'))?['error'],
      'License is for a different device.',
    );
  });

  test('rejects expired, malformed, and incomplete licenses', () async {
    expect(
      (await validate(
        payload()..['expires_at'] = '2029-02-01T00:00:00Z',
      ))?['error'],
      'License has expired.',
    );
    expect(
      (await validate(payload()..remove('product')))?['error'],
      'License is missing required fields.',
    );
    final path = '${directory.path}${Platform.pathSeparator}license.key';
    await File(path).writeAsString('not-a-license');
    final previous = Directory.current;
    Directory.current = directory;
    try {
      expect(
        (await LicenseValidator.validateLicense(
          verificationKeyHex: publicHex,
        ))?['error'],
        'Invalid license format.',
      );
    } finally {
      Directory.current = previous;
    }
  });

  test('validates a license code supplied as text (mobile path, no file)', () async {
    // Mobile has no license.key file: the signed code is pasted into the app
    // and passed via licenseText, so the same signature verification must apply.
    // The payload carries no hardware_id, i.e. a device-unbound mobile license.
    final mobile = Map<String, Object?>.from(payload())..remove('hardware_id');
    final bytes = utf8.encode(jsonEncode(canonical(mobile)));
    final signature = await Ed25519().sign(bytes, keyPair: pair);
    final code =
        '${base64Url.encode(bytes)}.${base64Url.encode(signature.bytes)}';

    final ok = await LicenseValidator.validateLicense(
      licenseText: code,
      now: DateTime.utc(2030),
      verificationKeyHex: publicHex,
    );
    expect(ok, containsPair('product', 'wholesale_pos'));

    // A tampered code (with no file present) is still rejected.
    final bad = await LicenseValidator.validateLicense(
      licenseText: '$code-tampered',
      now: DateTime.utc(2030),
      verificationKeyHex: publicHex,
    );
    expect(bad?['error'], 'Invalid license format.');
  });

  // ----- Version 2: seat-based licenses issued by the licensing Edge Function.

  Map<String, Object?> v2Payload({String fp = 'aaaa'}) => {
    'format': 'wholesale-pos-license',
    'version': 2,
    'product': 'wholesale_pos',
    'entitlements': ['pos'],
    'activation_code': 'TEST-A',
    'customer_id': 'cust-uuid',
    'device_fingerprint': fp,
    'issued_at': '2029-01-01T00:00:00Z',
    'expires_at': '2031-01-01T00:00:00Z',
  };

  Future<String> signV2(Map<String, Object?> payload) async {
    final bytes = utf8.encode(jsonEncode(canonical(payload)));
    final signature = await Ed25519().sign(bytes, keyPair: pair);
    return '${base64Url.encode(bytes)}.${base64Url.encode(signature.bytes)}';
  }

  test('accepts a v2 license whose fingerprint matches', () async {
    final code = await signV2(v2Payload(fp: 'bbbb'));
    final ok = await LicenseValidator.validateLicense(
      licenseText: code,
      deviceFingerprint: 'bbbb',
      now: DateTime.utc(2030),
      verificationKeyHex: publicHex,
    );
    expect(ok, containsPair('version', 2));
    expect(ok, containsPair('device_fingerprint', 'bbbb'));
  });

  test('rejects a v2 license bound to a different device', () async {
    final code = await signV2(v2Payload(fp: 'bbbb'));
    final bad = await LicenseValidator.validateLicense(
      licenseText: code,
      deviceFingerprint: 'cccc',
      now: DateTime.utc(2030),
      verificationKeyHex: publicHex,
    );
    expect(bad?['error'], 'License is for a different device.');
  });

  test('fails closed when a v2 license cannot verify this device fingerprint', () async {
    // A v2 seat license must never validate when the caller could not compute
    // this device's fingerprint (null) - that path used to be silently skipped.
    final code = await signV2(v2Payload(fp: 'bbbb'));
    final noFp = await LicenseValidator.validateLicense(
      licenseText: code,
      now: DateTime.utc(2030),
      verificationKeyHex: publicHex,
    );
    expect(noFp?['error'], 'License is for a different device.');
  });

  test(
    'rejects a v2 license missing customer_id / activation_code / fingerprint',
    () async {
      for (final field in [
        'customer_id',
        'activation_code',
        'device_fingerprint',
      ]) {
        final stripped = Map<String, Object?>.from(v2Payload())..remove(field);
        final code = await signV2(stripped);
        final bad = await LicenseValidator.validateLicense(
          licenseText: code,
          deviceFingerprint: 'aaaa',
          now: DateTime.utc(2030),
          verificationKeyHex: publicHex,
        );
        expect(
          bad?['error'],
          'License is missing required fields.',
          reason: 'v2 payload missing $field must be rejected',
        );
      }
    },
  );
}
