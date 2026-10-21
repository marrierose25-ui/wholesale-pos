// ignore_for_file: avoid_print
import 'dart:io';

import 'package:cryptography/cryptography.dart';

void main() async {
  print('Generating a mathematically valid Ed25519 keypair...');
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final privateKey = await keyPair.extractPrivateKeyBytes();
  final publicKey = await keyPair.extractPublicKey();

  String toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  final privHex = toHex(privateKey);
  final pubHex = toHex(publicKey.bytes);

  print('Private Key: $privHex');
  print('Public Key: $pubHex');

  // 1. Rewrite License Validator
  final validatorPath = 'lib/core/licensing/license_validator.dart';
  final validatorCode = File(validatorPath).readAsStringSync();
  final newValidatorCode = validatorCode.replaceAll(
    RegExp(r"static final _publicKeyHex = '[a-f0-9]+';"),
    "static final _publicKeyHex = '$pubHex';",
  );
  File(validatorPath).writeAsStringSync(newValidatorCode);
  print('Updated license_validator.dart');

  // 2. Rewrite License Generator
  final generatorPath = 'tools/generate_license.dart';
  final generatorCode = File(generatorPath).readAsStringSync();
  var newGeneratorCode = generatorCode.replaceAll(
    RegExp(r"const _privateKeyHex = '[a-f0-9]+';"),
    "const _privateKeyHex = '$privHex';",
  );
  newGeneratorCode = newGeneratorCode.replaceAll(
    RegExp(r"const _publicKeyHex = '[a-f0-9]+';"),
    "const _publicKeyHex = '$pubHex';",
  );
  File(generatorPath).writeAsStringSync(newGeneratorCode);
  print('Updated generate_license.dart');
}
