import 'package:flutter/foundation.dart';

import 'dart:io' show Platform;

import 'package:sqflite/sqflite.dart';

import '../database/local_database.dart';
import 'activation_client.dart';
import 'device_fingerprint.dart';
import 'license_validator.dart';

/// Result of redeeming a code on this device.
class DeviceActivationResult {
  final bool ok;
  final String? error;

  const DeviceActivationResult._(this.ok, this.error);

  const DeviceActivationResult.success() : this._(true, null);

  const DeviceActivationResult.failed(String error) : this._(false, error);
}

/// Turns a pasted code into a stored, device-bound licence.
///
/// One implementation for both entry points: the first-run activation screen
/// and the "not activated for cloud sync" action in Settings. The second one
/// matters because a PC carrying a pre-Phase-17 `license.key` validates locally
/// (no tenant inside it) and is refused by the sync gateway, so it can only
/// join the cloud by redeeming the shop's activation code — without losing its
/// local ledger.
///
/// Two code shapes are accepted:
///  * a short opaque code (e.g. "MERCA-7Q2F-…") — redeemed against the
///    licensing Edge Function, which returns a v2 licence bound to this
///    device's fingerprint;
///  * a full signed payload (`base64url.base64url`) — verified locally, as the
///    device-unbound licences issued before Phase 17 require.
class DeviceActivation {
  /// Signed payload validated offline on every startup.
  static const String licenseCodeKey = 'license_code';

  /// Short code kept so Settings → My devices can call the seat endpoints.
  static const String activationCodeKey = 'activation_code';

  static Future<DeviceActivationResult> redeem(
    Database db,
    String input, {
    ActivationClient? client,
    String? deviceName,
  }) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return const DeviceActivationResult.failed('Enter the activation code.');
    }

    final String fingerprint;
    try {
      fingerprint = await DeviceFingerprint.get(db);
    } catch (_) {
      return const DeviceActivationResult.failed(
        'Could not compute a device fingerprint; restart the app.',
      );
    }

    final String licenseToStore;
    if (trimmed.contains('.')) {
      final result = await LicenseValidator.validateLicense(
        licenseText: trimmed,
        deviceFingerprint: fingerprint,
      );
      if (result == null || result['error'] != null) {
        return DeviceActivationResult.failed(
          result?['error'] as String? ?? 'Invalid license code.',
        );
      }
      licenseToStore = trimmed;
    } else {
      final activationClient = client ?? ActivationClient();
      if (!activationClient.isConfigured) {
        return const DeviceActivationResult.failed(
          'Activation server is not configured on this build. Ask your '
          'provider to rebuild with '
          '--dart-define=WHOLESALE_POS_LICENSE_FN_URL=<url>.',
        );
      }
      final response = await activationClient.activateDevice(
        activationCode: trimmed,
        deviceFingerprint: fingerprint,
        deviceName:
            deviceName ?? (kIsWeb ? 'Web Browser' : Platform.localHostname),
      );
      if (!response.ok) {
        return DeviceActivationResult.failed(
          response.error ?? 'Activation failed.',
        );
      }
      final returned = response.licenseCode!;
      // Defense-in-depth: never trust the server's word — verify the signed
      // payload with the baked Ed25519 public key before accepting it.
      final verify = await LicenseValidator.validateLicense(
        licenseText: returned,
        deviceFingerprint: fingerprint,
      );
      if (verify == null || verify['error'] != null) {
        // Surface the validator's own wording. The most common cause is a
        // release built without --dart-define=WHOLESALE_POS_LICENSE_PUBLIC_KEY:
        // the server signs correctly and the client then fails closed, which
        // used to be reported as a bare "invalid license".
        final detail = verify?['error'] as String?;
        return DeviceActivationResult.failed(
          detail == null
              ? 'Server returned an invalid license.'
              : 'Server returned an invalid license: $detail',
        );
      }
      licenseToStore = returned;
      await LocalDatabase.setSetting(db, activationCodeKey, trimmed);
    }

    await LocalDatabase.setSetting(db, licenseCodeKey, licenseToStore);
    return const DeviceActivationResult.success();
  }
}
