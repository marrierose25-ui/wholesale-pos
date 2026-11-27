// DEPRECATED — seat vouchers are retired.
//
// The commercial policy changed: ONE activation code = ONE business with
// UNLIMITED devices. There is no seat_limit to raise, so vouchers no longer
// do anything. The licensing Edge Function answers `redeem_voucher` with a
// deliberate 410 deprecation response, and historical seat_vouchers rows
// are kept for audit only — they are never silently redeemed.
//
// This tool is kept so old runbooks fail loudly instead of writing orphan
// rows. It refuses to run.
import 'dart:io';

Future<void> main(List<String> args) async {
  stderr.writeln(
    'create_seat_voucher is deprecated and disabled.\n'
    'One activation code now covers unlimited devices — there are no seats '
    'left to purchase, so vouchers are no longer issued or redeemed.\n'
    'Historical voucher records remain in the database for audit only.',
  );
  exitCode = 1;
}
