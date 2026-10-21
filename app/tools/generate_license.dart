// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

const _privateKeyHex =
    '7c1e490bf158e0f558c19f477a8cf3f8dc440aa11a6e60b3691e8dbaeb14a732';
const _publicKeyHex =
    'b94dc2d903a1e3850e7d88fc42b427350e3ff8211a54a71c681c42a2f4541b4e';

void main(List<String> args) async {
  if (args.length != 1) {
    print('Usage: dart run tools/generate_license.dart <HARDWARE_ID>');
    exit(1);
  }

  final payload = {
    'hardware_id': args[0],
    'issued_at': DateTime.now().toIso8601String(),
    'expires_at': DateTime.now()
        .add(const Duration(days: 3650))
        .toIso8601String(),
  };

  final payloadJson = jsonEncode(payload);
  final privateKey = SimpleKeyPairData(
    hexToBytes(_privateKeyHex),
    publicKey: SimplePublicKey(
      hexToBytes(_publicKeyHex),
      type: KeyPairType.ed25519,
    ),
    type: KeyPairType.ed25519,
  );

  final signature = await Ed25519().sign(
    utf8.encode(payloadJson),
    keyPair: privateKey,
  );
  final licenseString =
      '${base64Url.encode(utf8.encode(payloadJson))}.${base64Url.encode(signature.bytes)}';

  await File('license.key').writeAsString(licenseString);

  final debugDir = Directory('build/windows/x64/runner/Debug');
  if (await debugDir.exists()) {
    await File('${debugDir.path}/license.key').writeAsString(licenseString);
  }

  print('License generated to ${Directory.current.path}\\license.key');
}

List<int> hexToBytes(String hex) {
  final result = <int>[];
  for (int i = 0; i < hex.length; i += 2) {
    result.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return result;
}
