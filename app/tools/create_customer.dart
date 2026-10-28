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
import 'dart:async';
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
      '[--contact "..."] [--notes "..."] [--timeout 60]',
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

  final timeout = Duration(
    seconds: int.tryParse(flags['timeout'] ?? '60') ?? 60,
  );
  final activationCode = _generateActivationCode();
  final headers = {
    'apikey': secret,
    'Authorization': 'Bearer $secret',
    'Content-Type': 'application/json',
    'Prefer': 'return=representation',
  };
  final base = '$url/rest/v1';

  // 0. Reachability first. A DNS/TLS/firewall problem and a wrong key both end
  //    up as "it did not work"; asking the gateway a question that needs no
  //    data tells the two apart in one line.
  final reachable = await _call(
    'Reachability check',
    () =>
        http.get(Uri.parse('$url/auth/v1/health'), headers: {'apikey': secret}),
    const Duration(seconds: 15),
    retry: true,
  );
  if (reachable == null) {
    stderr.writeln(
      'Cannot reach $url. Check the URL, the connection, and any VPN or '
      'firewall in between. Nothing was written.',
    );
    exitCode = 1;
    return;
  }

  try {
    // 1. Customer row. Look before inserting: a run that timed out after the
    //    server committed would otherwise leave a duplicate behind on retry.
    //    (`customers.name` is not unique, so this is a courtesy - delete the
    //    existing row first if you genuinely want a second shop of that name.)
    final existing = await _findRow(
      base,
      headers,
      'customers?select=id&name=eq.${Uri.encodeComponent(name)}&limit=1',
      timeout,
    );
    String? customerId = existing?['id'] as String?;
    if (customerId != null) {
      stdout.writeln('NOTE: customer "$name" already exists; reusing it.');
    } else {
      final customerRes = await _call(
        'Creating the customer',
        () => http.post(
          Uri.parse('$base/customers'),
          headers: headers,
          body: jsonEncode({
            'name': name,
            'contact': flags['contact'],
            'notes': flags['notes'],
          }),
        ),
        timeout,
      );
      if (customerRes == null) {
        // The insert may have committed even though no reply came back.
        customerId =
            (await _findRow(
                  base,
                  headers,
                  'customers?select=id&name=eq.${Uri.encodeComponent(name)}&limit=1',
                  timeout,
                ))?['id']
                as String?;
        if (customerId == null) {
          stderr.writeln(
            'The customer was not created; nothing changed, so re-running is '
            'safe.',
          );
          exitCode = 1;
          return;
        }
        stdout.writeln('NOTE: the insert landed despite the timeout.');
      } else if (customerRes.statusCode != 201) {
        stderr.writeln('Failed to create customer: ${customerRes.body}');
        exitCode = 1;
        return;
      } else {
        customerId =
            (jsonDecode(customerRes.body) as List).first['id'] as String;
      }
    }

    // 2. License row. activation_code is the primary key, so a duplicate is
    //    impossible; a timeout is verified rather than retried.
    final licenseRes = await _call(
      'Creating the licence',
      () => http.post(
        Uri.parse('$base/licenses'),
        headers: headers,
        body: jsonEncode({
          'activation_code': activationCode,
          'customer_id': customerId,
          'seat_limit': seats,
          'expires_at': expiresIso,
        }),
      ),
      timeout,
    );
    if (licenseRes == null) {
      final landed = await _findRow(
        base,
        headers,
        'licenses?select=activation_code'
        '&activation_code=eq.${Uri.encodeComponent(activationCode)}'
        '&limit=1',
        timeout,
      );
      if (landed == null) {
        stderr.writeln(
          'The licence insert did not finish and did not land. The customer '
          'row exists now; re-running will reuse it and only create the '
          'licence.',
        );
        exitCode = 1;
        return;
      }
      stdout.writeln('NOTE: the licence landed despite the timeout.');
    } else if (licenseRes.statusCode != 201) {
      stderr.writeln('Failed to create license: ${licenseRes.body}');
      stderr.writeln(
        'NOTE: the customer row was created but the license was not. '
        'Re-running will reuse that customer instead of making a second one.',
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

/// One HTTP call, with a timeout that names the step that stalled.
///
/// The bare 20-second cliff was the problem: a stalled round trip and a wrong
/// key both surfaced as one opaque line. Reads are retried once because that
/// cannot hurt; writes are not, because a retry can duplicate a row - the
/// caller verifies those instead.
Future<http.Response?> _call(
  String label,
  Future<http.Response> Function() send,
  Duration timeout, {
  bool retry = false,
}) async {
  for (var attempt = 1; ; attempt++) {
    try {
      return await send().timeout(timeout);
    } on TimeoutException {
      if (!retry || attempt == 2) {
        stderr.writeln('$label did not answer within ${timeout.inSeconds}s.');
        return null;
      }
      stdout.writeln('$label timed out, retrying once...');
    } on SocketException catch (e) {
      stderr.writeln('$label could not open a connection: ${e.message}');
      return null;
    } on http.ClientException catch (e) {
      stderr.writeln('$label failed: ${e.message}');
      return null;
    }
  }
}

/// Returns the first matching row, or null when there is none (or the lookup
/// itself failed - the caller then treats the write as not having landed).
Future<Map<String, dynamic>?> _findRow(
  String base,
  Map<String, String> headers,
  String query,
  Duration timeout,
) async {
  final res = await _call(
    'Lookup',
    () => http.get(Uri.parse('$base/$query'), headers: headers),
    timeout,
    retry: true,
  );
  if (res == null || res.statusCode != 200) return null;
  final rows = jsonDecode(res.body) as List;
  if (rows.isEmpty) return null;
  return (rows.first as Map).cast<String, dynamic>();
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
