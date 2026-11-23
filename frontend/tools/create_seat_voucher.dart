// Umer's tool: issue a seat-addition voucher to an existing customer.
//
// When a buyer wants to expand beyond their current seat_limit, they pay
// you out-of-band (bank / cash / Chapa). Then run this tool with their
// activation code and the number of seats to add. The printed voucher is
// what they paste into Settings -> Devices -> "Add seats" to bump their
// limit — no database edits by you, no restart needed on their side.
//
//   $env:SUPABASE_URL    = "https://<your-ref>.supabase.co"
//   $env:SUPABASE_SECRET = "sb_secret_..."
//   dart run tools/create_seat_voucher.dart `
//     --activation-code "MERCA-7Q2F-9K3X-4D8M-BN" `
//     --seats 2
//
// Vouchers are one-shot: the redeem_voucher Edge Function flips redeemed_at
// the moment they are applied, so a leaked voucher can only ever be spent
// once, and only on the license it was issued for.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

Future<void> main(List<String> args) async {
  final flags = _parseArgs(args);
  final activation = flags['activation-code'];
  final seats = int.tryParse(flags['seats'] ?? '');
  if (activation == null || activation.isEmpty || seats == null || seats < 1) {
    stderr.writeln(
      'Usage: dart run tools/create_seat_voucher.dart '
      '--activation-code "..." --seats N',
    );
    exitCode = 2;
    return;
  }
  final url = (Platform.environment['SUPABASE_URL'] ?? '').trim();
  final secret = (Platform.environment['SUPABASE_SECRET'] ?? '').trim();
  if (url.isEmpty || secret.isEmpty) {
    stderr.writeln('Set SUPABASE_URL and SUPABASE_SECRET first.');
    exitCode = 2;
    return;
  }

  // Sanity-check the license exists so a typo in --activation-code does not
  // create an orphan voucher.
  final lookup = await http
      .get(
        Uri.parse(
          '$url/rest/v1/licenses?activation_code=eq.$activation&select=activation_code',
        ),
        headers: {'apikey': secret, 'Authorization': 'Bearer $secret'},
      )
      .timeout(const Duration(seconds: 20));
  if (lookup.statusCode != 200) {
    stderr.writeln('License lookup failed: ${lookup.body}');
    exitCode = 1;
    return;
  }
  if ((jsonDecode(lookup.body) as List).isEmpty) {
    stderr.writeln('No license with that activation code.');
    exitCode = 1;
    return;
  }

  final voucherCode = _generateVoucherCode();
  final res = await http
      .post(
        Uri.parse('$url/rest/v1/seat_vouchers'),
        headers: {
          'apikey': secret,
          'Authorization': 'Bearer $secret',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'voucher_code': voucherCode,
          'activation_code': activation,
          'seats_added': seats,
        }),
      )
      .timeout(const Duration(seconds: 20));
  if (res.statusCode != 201) {
    stderr.writeln('Failed to create voucher: ${res.body}');
    exitCode = 1;
    return;
  }
  stdout.writeln('VOUCHER_CODE=$voucherCode');
  stdout.writeln('SEATS_ADDED=$seats');
  stdout.writeln(
    'Send this voucher to the buyer; they redeem it inside '
    'the app under Settings -> Devices -> Add seats.',
  );
}

/// V-XXXXXXXX (9 chars). Short by design: these are single-use, sent over
/// SMS / email once, and the caller already knows the parent activation.
String _generateVoucherCode() {
  final rng = Random.secure();
  final body = List.generate(
    8,
    (_) => _alphabet[rng.nextInt(_alphabet.length)],
  ).join();
  return 'V-$body';
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
