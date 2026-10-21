// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

void main(List<String> args) async {
  if (args.length != 1) {
    print('Usage: dart run tools/generate_license.dart <HARDWARE_ID>');
    exit(1);
  }

  final secretKey = utf8.encode('my-super-secret-key-for-wholesale-pos-2026');
  final payload = {
    'hardware_id': args[0],
    'issued_at': DateTime.now().toIso8601String(),
    'expires_at': DateTime.now()
        .add(const Duration(days: 3650))
        .toIso8601String(),
  };

  final payloadJson = jsonEncode(payload);
  final hmac = Hmac(sha256, secretKey);
  final digest = hmac.convert(utf8.encode(payloadJson));

  final licenseString =
      '${base64Url.encode(utf8.encode(payloadJson))}.${base64Url.encode(digest.bytes)}';

  await File('license.key').writeAsString(licenseString);

  // Also copy to the debug build folder so Flutter finds it immediately
  final debugDir = Directory('build/windows/x64/runner/Debug');
  if (await debugDir.exists()) {
    await File('${debugDir.path}/license.key').writeAsString(licenseString);
  }

  print(
    'License generated successfully to ${Directory.current.path}\\license.key',
  );
}
