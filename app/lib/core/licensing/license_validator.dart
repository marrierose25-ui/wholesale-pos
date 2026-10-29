import 'package:flutter/foundation.dart';

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

class LicenseValidator {
  /// Injected at build time, e.g.
  /// `flutter build windows --dart-define=WHOLESALE_POS_LICENSE_PUBLIC_KEY=<hex>`.
  static const String _publicKeyHex = String.fromEnvironment(
    'WHOLESALE_POS_LICENSE_PUBLIC_KEY',
  );

  /// Explicit, build-time escape hatch for development machines that do not
  /// have a signing key yet. Never enable this in a shipped build.
  static const bool _allowUnlicensedDev = bool.fromEnvironment(
    'WHOLESALE_POS_DEV_UNLICENSED',
  );

  /// Resolves the stable motherboard UUID, or returns null if it could not be
  /// read this run (CIM timed out, was blocked by AV, or a non-Windows host).
  /// Callers that must never see null use [getHardwareId]; callers that need to
  /// distinguish "real UUID" from "unavailable" (e.g. to avoid caching a junk
  /// value into the device fingerprint) use this directly.
  static Future<String?> tryGetHardwareId() async {
    try {
      if (!kIsWeb && Platform.isWindows) {
        final result = await Process.run('powershell', [
          '-Command',
          '(Get-CimInstance Win32_ComputerSystemProduct).UUID',
        ]).timeout(const Duration(seconds: 5));
        final uuid = result.stdout.toString().trim();
        if (result.exitCode == 0 && uuid.isNotEmpty) {
          return uuid;
        }
      }
    } catch (_) {
      // Treated the same as a non-zero exit: unavailable.
    }
    return null;
  }

  static Future<String> getHardwareId() async {
    return await tryGetHardwareId() ??
        (kIsWeb ? 'Web Browser' : Platform.localHostname);
  }

  static Future<Map<String, dynamic>?> validateLicense({
    String? hardwareId,
    String? deviceFingerprint,
    DateTime? now,
    String? verificationKeyHex,
    String? licenseText,
  }) async {
    if (verificationKeyHex == null &&
        _allowUnlicensedDev &&
        _publicKeyHex.isEmpty) {
      return {
        'format': 'wholesale-pos-license',
        'version': 1,
        'product': 'wholesale_pos',
        'entitlements': const ['pos'],
        'issued_at': DateTime.now().toIso8601String(),
        'expires_at': DateTime.now()
            .add(const Duration(days: 30))
            .toIso8601String(),
        'dev_license': true,
      };
    }

    try {
      // Desktop resolves the license from a `license.key` file. Mobile has no
      // such file, so the caller passes the entered/persisted code via
      // [licenseText] and the exact same signature verification runs below.
      final String licenseContents;
      if (licenseText != null && licenseText.trim().isNotEmpty) {
        licenseContents = licenseText.trim();
      } else {
        var file = File('license.key');
        if (!await file.exists()) {
          final exeDir = File(Platform.resolvedExecutable).parent.path;
          file = File('$exeDir/license.key');
          if (!await file.exists()) {
            return {'error': 'license.key not found.'};
          }
        }
        licenseContents = await file.readAsString();
      }

      final parts = licenseContents.trim().split('.');
      if (parts.length != 2) {
        return {'error': 'Invalid license format.'};
      }
      final payloadBytes = base64Url.decode(base64Url.normalize(parts[0]));
      final signatureBytes = base64Url.decode(base64Url.normalize(parts[1]));
      if (signatureBytes.length != 64) {
        return {'error': 'Invalid license format.'};
      }

      final decoded = jsonDecode(utf8.decode(payloadBytes));
      if (decoded is! Map<String, dynamic>) {
        return {'error': 'Invalid license format.'};
      }
      final payload = decoded;

      final required = [
        'format',
        'version',
        'product',
        'entitlements',
        'issued_at',
        'expires_at',
      ];
      if (required.any((key) => !payload.containsKey(key)) ||
          payload['format'] != 'wholesale-pos-license' ||
          (payload['version'] != 1 && payload['version'] != 2) ||
          payload['product'] != 'wholesale_pos' ||
          payload['entitlements'] is! List ||
          (payload['entitlements'] as List).any((item) => item is! String) ||
          payload['issued_at'] is! String ||
          payload['expires_at'] is! String ||
          (payload.containsKey('hardware_id') &&
              payload['hardware_id'] is! String)) {
        return {'error': 'License is missing required fields.'};
      }

      final issuedAt = DateTime.tryParse(payload['issued_at'] as String);
      final expiresAt = DateTime.tryParse(payload['expires_at'] as String);
      if (issuedAt == null ||
          expiresAt == null ||
          !expiresAt.isAfter(issuedAt)) {
        return {'error': 'Invalid license dates.'};
      }

      final canonicalBytes = utf8.encode(jsonEncode(_canonicalize(payload)));
      if (!_sameBytes(payloadBytes, canonicalBytes)) {
        return {'error': 'Invalid license format.'};
      }

      final keyHex = verificationKeyHex ?? _publicKeyHex;
      if (keyHex.length != 64 ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(keyHex)) {
        return {
          'error':
              'License verification key is not configured. Build with '
              '--dart-define=WHOLESALE_POS_LICENSE_PUBLIC_KEY=<hex>.',
        };
      }

      final publicKey = SimplePublicKey(
        _hexToBytes(keyHex),
        type: KeyPairType.ed25519,
      );
      final validSignature = await Ed25519().verify(
        payloadBytes,
        signature: Signature(signatureBytes, publicKey: publicKey),
      );
      if (!validSignature) {
        return {'error': 'Invalid license signature.'};
      }

      final expectedHardwareId = hardwareId ?? await getHardwareId();
      if (payload['hardware_id'] != null &&
          payload['hardware_id'] != expectedHardwareId) {
        return {'error': 'License is for a different device.'};
      }
      // Version 2 (issued by the licensing Edge Function) binds the seat to a
      // SHA-256 device fingerprint instead of a raw hardware id. All v2 fields
      // are mandatory; a missing / mismatched fingerprint is a hard reject.
      if (payload['version'] == 2) {
        for (final field in const [
          'customer_id',
          'activation_code',
          'device_fingerprint',
        ]) {
          final v = payload[field];
          if (v is! String || v.isEmpty) {
            return {'error': 'License is missing required fields.'};
          }
        }
        // Fail closed. A v2 seat license is bound to exactly one device; if we
        // could not compute THIS device's fingerprint we must reject rather
        // than silently skip the comparison (otherwise a copied license.key
        // would validate on any machine that failed fingerprint detection).
        if (deviceFingerprint == null ||
            payload['device_fingerprint'] != deviceFingerprint) {
          return {'error': 'License is for a different device.'};
        }
      }
      final nowValue = now ?? DateTime.now();
      if (issuedAt.isAfter(nowValue.add(const Duration(days: 1)))) {
        return {'error': 'System clock is set before the license issue date.'};
      }
      if (!nowValue.isBefore(expiresAt)) {
        return {'error': 'License has expired.'};
      }
      return payload;
    } catch (_) {
      return {'error': 'Invalid license format.'};
    }
  }

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonicalize(value[key])};
    }
    if (value is List) return value.map(_canonicalize).toList();
    return value;
  }

  static List<int> _hexToBytes(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];

  static bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var i = 0; i < left.length; i++) {
      difference |= left[i] ^ right[i];
    }
    return difference == 0;
  }
}
