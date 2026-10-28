import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thin, testable client over the Supabase Edge Function `pos-api`.
///
/// Mirrors [ActivationClient]'s posture: the only baked value is the function
/// URL (`--dart-define=WHOLESALE_POS_API_URL=...`); no Supabase key ever ships
/// in the bundle. After a successful login the signed session [token] is held
/// here and attached to every subsequent authenticated call as a bearer header,
/// so the repositories stay focused purely on the action/JSON contract.
///
/// Every call returns the server's decoded JSON body on `ok: true`; a refusal
/// or a transport failure throws [CloudApiException] carrying the server's
/// human-readable `error` (never a raw stack or SQL fragment).
class CloudApiClient {
  static const String _defaultUrl = String.fromEnvironment(
    'WHOLESALE_POS_API_URL',
  );

  final String url;
  final http.Client _client;

  /// The shop's activation code — identifies the tenant for `login` /
  /// `setup_owner` / `has_users`. Never used for authenticated actions, which
  /// are scoped by the server from the bearer token. Mutable because the web
  /// activation step captures it at runtime (paste the shop code once).
  String activationCode;

  /// The signed session token from the last successful `login` /
  /// `setup_owner`. Attached as a bearer header to every authenticated call.
  String? token;

  /// Stable per-browser/device id, auto-stamped onto every request body as
  /// `device_id`. The server carves shift/receipt operations from it (audit
  /// D1) so a shared tenant's open drawer and receipt stream are scoped to the
  /// device that owns them. Empty until the backend resolves it (tests, and the
  /// unauthenticated login/setup calls, never need it).
  String deviceId;

  CloudApiClient({
    String? url,
    http.Client? client,
    this.activationCode = '',
    this.deviceId = '',
  }) : url = url ?? _defaultUrl,
       _client = client ?? http.Client();

  bool get isConfigured => url.isNotEmpty;

  bool get isSignedIn => token != null && token!.isNotEmpty;

  /// Performs one `pos-api` action and returns the decoded body on success.
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic>? body,
  ]) async {
    if (!isConfigured) {
      throw CloudApiException(
        'Cloud API not configured. Rebuild with '
        '--dart-define=WHOLESALE_POS_API_URL=<url>.',
      );
    }
    final payload = <String, dynamic>{'action': action, ...?body};
    // Stamp the device id for authenticated actions unless the caller already
    // supplied one (an explicit body device_id always wins). Harmless on the
    // unauthenticated calls, which ignore it.
    if (deviceId.isNotEmpty) payload['device_id'] ??= deviceId;
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null && token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    final http.Response res;
    try {
      res = await _client
          .post(Uri.parse(url), headers: headers, body: jsonEncode(payload))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // A dropped connection looks identical to a server error to the caller;
      // the message tells them to retry, which is the correct next step.
      throw CloudApiException('Could not reach the server.');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (_) {
      throw CloudApiException('Unexpected response from server.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw CloudApiException('Unexpected response from server.');
    }
    if (decoded['ok'] == true) return decoded;
    throw CloudApiException((decoded['error'] as String?) ?? 'Request failed.');
  }
}

/// Raised for a server refusal (`ok: false`) or any transport failure. The
/// message is always safe to surface directly in the UI.
class CloudApiException implements Exception {
  final String message;
  CloudApiException(this.message);
  @override
  String toString() => message;
}
