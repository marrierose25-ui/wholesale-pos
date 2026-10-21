import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tools/print_public_key.dart <seed-path> [license-path]',
    );
    exitCode = 2;
    return;
  }
  final seed = base64Url.decode(
    base64Url.normalize((await File(args[0]).readAsString()).trim()),
  );
  if (seed.length != 32) {
    stderr.writeln('Seed must be 32 bytes.');
    exitCode = 2;
    return;
  }
  final keyPair = await Ed25519().newKeyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();
  final hex = publicKey.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  stdout.writeln('PUBLIC_KEY=$hex');

  if (args.length > 1) {
    final parts = (await File(args[1]).readAsString()).trim().split('.');
    final payloadBytes = base64Url.decode(base64Url.normalize(parts[0]));
    final signatureBytes = base64Url.decode(base64Url.normalize(parts[1]));
    final valid = await Ed25519().verify(
      payloadBytes,
      signature: Signature(signatureBytes, publicKey: publicKey),
    );
    stdout.writeln('LICENSE_VALID=$valid');
    stdout.writeln(utf8.decode(payloadBytes));
  }
}
