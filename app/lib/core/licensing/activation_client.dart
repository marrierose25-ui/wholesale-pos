import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thin client over the Supabase Edge Function `licensing`.
///
/// The Edge Function is deployed with "Verify JWT" OFF, so callers authenticate
/// by presenting a valid (activation_code, device_fingerprint) pair that the
/// server has already registered — the shared secret IS the seat binding. The
/// anon Supabase key is not required and is deliberately not baked into the
/// app; only the function URL is (via
/// `--dart-define=WHOLESALE_POS_LICENSE_FN_URL=...`).
///
/// Every method returns a [_Result]-shaped map from the server's JSON body.
/// Callers check `ok` and either apply the change or surface the `error`
/// string to the user. Network exceptions are wrapped, never thrown raw, so
/// the UI stays responsive when the shop's connection drops.
class ActivationClient {
  /// Baked at build time. Empty string means "no licensing server configured"
  /// and every call returns a not-configured error — this is what a plain
  /// `flutter build` without the flag produces, keeping behaviour identical
  /// to today's file-based licensing for the developer's own shop PC.
  static const String _defaultUrl = String.fromEnvironment(
    'WHOLESALE_POS_LICENSE_FN_URL',
  );

  final String _url;
  final http.Client _client;

  ActivationClient({String? url, http.Client? client})
    : _url = url ?? _defaultUrl,
      _client = client ?? http.Client();

  bool get isConfigured => _url.isNotEmpty;

  /// Redeems an activation code on this device. On success returns the
  /// server-signed `license_code` (paste-ready string of the form
  /// `base64url(payload).base64url(signature)`) which the caller stores in
  /// `settings.license_code` and re-verifies offline on every startup.
  Future<ActivationResponse> activateDevice({
    required String activationCode,
    required String deviceFingerprint,
    required String deviceName,
  }) async {
    final json = await _post({
      'action': 'activate_device',
      'activation_code': activationCode,
      'device_fingerprint': deviceFingerprint,
      'device_name': deviceName,
    });
    if (json['ok'] == true) {
      return ActivationResponse.success(
        licenseCode: json['license_code'] as String,
        expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
        seatLimit: (json['seat_limit'] as num?)?.toInt(),
        seatsUsed: (json['seats_used'] as num?)?.toInt(),
      );
    }
    return ActivationResponse.failure(
      error: (json['error'] as String?) ?? 'Activation failed.',
      seatLimit: (json['seat_limit'] as num?)?.toInt(),
      seatsUsed: (json['seats_used'] as num?)?.toInt(),
    );
  }

  /// Returns the buyer's own list of active seats. Only works from a device
  /// that already holds an active registration (enforced server-side).
  Future<ActivationResponse> listDevices({
    required String activationCode,
    required String deviceFingerprint,
  }) async {
    final json = await _post({
      'action': 'list_devices',
      'activation_code': activationCode,
      'device_fingerprint': deviceFingerprint,
    });
    if (json['ok'] == true) {
      final raw = json['devices'];
      final list = raw is List
          ? raw.whereType<Map<String, dynamic>>().toList()
          : <Map<String, dynamic>>[];
      return ActivationResponse.success(
        devices: list,
        seatLimit: (json['seat_limit'] as num?)?.toInt(),
        seatsUsed: (json['seats_used'] as num?)?.toInt(),
      );
    }
    return ActivationResponse.failure(
      error: (json['error'] as String?) ?? 'Could not list devices.',
    );
  }

  /// Removes one of the caller's own devices to free a seat. Refuses
  /// self-deactivation server-side so the caller cannot lock themselves out.
  Future<ActivationResponse> deactivateDevice({
    required String activationCode,
    required String requestingFingerprint,
    required String targetFingerprint,
  }) async {
    final json = await _post({
      'action': 'deactivate_device',
      'activation_code': activationCode,
      'requesting_fingerprint': requestingFingerprint,
      'target_fingerprint': targetFingerprint,
    });
    if (json['ok'] == true) return ActivationResponse.success();
    return ActivationResponse.failure(
      error: (json['error'] as String?) ?? 'Deactivation failed.',
    );
  }

  /// Applies a seat voucher (bought from Umer out-of-band) to the current
  /// license, raising `seat_limit` by the voucher's `seats_added`.
  Future<ActivationResponse> redeemVoucher({
    required String activationCode,
    required String deviceFingerprint,
    required String voucherCode,
  }) async {
    final json = await _post({
      'action': 'redeem_voucher',
      'activation_code': activationCode,
      'device_fingerprint': deviceFingerprint,
      'voucher_code': voucherCode,
    });
    if (json['ok'] == true) {
      return ActivationResponse.success(
        seatsAdded: (json['seats_added'] as num?)?.toInt(),
        newSeatLimit: (json['new_seat_limit'] as num?)?.toInt(),
      );
    }
    return ActivationResponse.failure(
      error: (json['error'] as String?) ?? 'Voucher redemption failed.',
    );
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    if (!isConfigured) {
      return {
        'ok': false,
        'error':
            'Licensing server not configured. Rebuild with '
            '--dart-define=WHOLESALE_POS_LICENSE_FN_URL=<url>.',
      };
    }
    try {
      final res = await _client
          .post(
            Uri.parse(_url),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) return decoded;
      return {'ok': false, 'error': 'Unexpected response from server.'};
    } catch (_) {
      // Never leak exception details; a network drop looks the same as an
      // internal server error to the caller. The message tells them to retry
      // or check connectivity, which is the correct next step either way.
      return {'ok': false, 'error': 'Could not reach the licensing server.'};
    }
  }
}

/// Uniform result shape for all ActivationClient methods. Optional fields
/// are populated depending on which action ran.
class ActivationResponse {
  final bool ok;
  final String? error;
  final String? licenseCode;
  final DateTime? expiresAt;
  final int? seatLimit;
  final int? seatsUsed;
  final int? seatsAdded;
  final int? newSeatLimit;
  final List<Map<String, dynamic>>? devices;

  ActivationResponse.success({
    this.licenseCode,
    this.expiresAt,
    this.seatLimit,
    this.seatsUsed,
    this.seatsAdded,
    this.newSeatLimit,
    this.devices,
  }) : ok = true,
       error = null;

  ActivationResponse.failure({
    required this.error,
    this.seatLimit,
    this.seatsUsed,
  }) : ok = false,
       licenseCode = null,
       expiresAt = null,
       seatsAdded = null,
       newSeatLimit = null,
       devices = null;
}
