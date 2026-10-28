// Umer's tool: create a new paying customer + issue an activation code.
//
// Talks to Supabase directly via the service-role secret key (never baked
// into the app). Reads credentials from environment variables so they never
// hit disk or shell history:
//
//   $env:SUPABASE_URL    = "https://<your-ref>.supabase.co"
//   $env:SUPABASE_SECRET = "sb_secret_..."           # service-role key
//   dart run tools/create_customer.dart `
//     --name "Mercato Textiles" `
//     --seats 3 `
//     --expires 2027-10-24 `
//     --contact "textiles@example.com"
//
// Prints the activation code to paste into the buyer's app. Nothing is
// written to disk. Use --expires never (default) for a perpetual license.
//
// See docs/SELLING_THE_APP.md for the commercial workflow around this tool.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I/L

Future<void> main(List<String> args) async {
  final flags = _parseArgs(args);
  final name = flags['name'];
  if (name == null || name.isEmpty) {
    stderr.writeln(
      'Usage: dart run tools/create_customer.dart '
      '--name "Customer Shop Name" [--seats N] [--expires YYYY-MM-DD|never] '
      '[--contact "..."] [--notes "..."]',
    );
    exitCode = 2;
    return;
  }
  final url = (Platform.environment['SUPABASE_URL'] ?? '').trim();
  final secret = (Platform.environment['SUPABASE_SECRET'] ?? '').trim();
  if (url.isEmpty || secret.isEmpty) {
    stderr.writeln(
      'Set SUPABASE_URL and SUPABASE_SECRET environment variables first. '
      'The secret is the service-role key from the Supabase dashboard '
      '(Settings -> API -> service_role); it is used only here, never '
      'baked into the app.',
    );
    exitCode = 2;
    return;
  }
  // A Management API token (sbp_…) and the service-role key are both
  // "a Supabase secret", and pasting the wrong one answers the misleading
  // `Invalid API key` from PostgREST. Name the mistake instead.
  if (secret.startsWith('sbp_')) {
    stderr.writeln(
      'SUPABASE_SECRET is a Management API personal access token (sbp_…). '
      'This tool needs the project\'s service_role key instead: dashboard -> '
      'Project Settings -> API -> service_role (sb_secret_… or the legacy '
      'eyJ… JWT). Management tokens cannot read or write table data.',
    );
    exitCode = 2;
    return;
  }

  final seats = int.tryParse(flags['seats'] ?? '3') ?? 3;
  if (seats < 1) {
    stderr.writeln('--seats must be >= 1.');
    exitCode = 2;
    return;
  }
  final expiresArg = flags['expires'] ?? 'never';
  String? expiresIso;
  if (expiresArg != 'never') {
    expiresIso = _expiryToIsoUtc(expiresArg);
    if (expiresIso == null) {
      stderr.writeln(
        '--expires must be "never" or an ISO date like 2027-10-24. '
        'Got: "$expiresArg".',
      );
      exitCode = 2;
      return;
    }
  }

  final activationCode = _generateActivationCode();
  final headers = {
    'apikey': secret,
    'Authorization': 'Bearer $secret',
    'Content-Type': 'application/json',
    'Prefer': 'return=representation',
  };

  try {
    // 1. Insert the customer row (returns its UUID).
    final customerRes = await http
        .post(
          Uri.parse('$url/rest/v1/customers'),
          headers: headers,
          body: jsonEncode({
            'name': name,
            'contact': flags['contact'],
            'notes': flags['notes'],
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (customerRes.statusCode != 201) {
      stderr.writeln('Failed to create customer: ${customerRes.body}');
      exitCode = 1;
      return;
    }
    final customerId =
        (jsonDecode(customerRes.body) as List).first['id'] as String;

    // 2. Insert the license row referencing that customer.
    final licenseRes = await http
        .post(
          Uri.parse('$url/rest/v1/licenses'),
          headers: headers,
          body: jsonEncode({
            'activation_code': activationCode,
            'customer_id': customerId,
            'seat_limit': seats,
            'expires_at': expiresIso,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (licenseRes.statusCode != 201) {
      stderr.writeln('Failed to create license: ${licenseRes.body}');
      stderr.writeln(
        'NOTE: the customer row was created but the license was not. '
        'Delete the orphan customer in the Supabase dashboard before '
        're-running.',
      );
      exitCode = 1;
      return;
    }

    stdout.writeln('CUSTOMER_ID=$customerId');
    stdout.writeln('ACTIVATION_CODE=$activationCode');
    stdout.writeln('SEAT_LIMIT=$seats');
    stdout.writeln('EXPIRES=$expiresArg');
    stdout.writeln(
      'Give the buyer this code and tell them to paste it '
      'into the app on the device they want activated.',
    );
  } catch (e) {
    stderr.writeln('Request failed: $e');
    exitCode = 1;
  }
}

/// XXXX-XXXX-XXXX-XXXX-XX (22 chars, 128-bit keyspace over a 32-char
/// human-friendly alphabet). Random.secure so codes cannot be predicted.
String _generateActivationCode() {
  final rng = Random.secure();
  String block(int n) =>
      List.generate(n, (_) => _alphabet[rng.nextInt(_alphabet.length)]).join();
  return '${block(4)}-${block(4)}-${block(4)}-${block(4)}-${block(2)}';
}

String? _expiryToIsoUtc(String arg) {
  if (arg == 'never') return null;
  // Accept YYYY-MM-DD (interpreted as end-of-day UTC) or full ISO with Z.
  final asDate = DateTime.tryParse(arg);
  if (asDate == null) return null;
  final utc = arg.contains('T')
      ? asDate.toUtc()
      : DateTime.utc(asDate.year, asDate.month, asDate.day, 23, 59, 59);
  return utc.toIso8601String();
}

Map<String, String> _parseArgs(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--') && i + 1 < args.length) {
      out[a.substring(2)] = args[++i];
    }
  }
  return out;
}
