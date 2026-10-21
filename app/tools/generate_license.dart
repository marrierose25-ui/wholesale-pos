import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'Usage: dart run tools/generate_license.dart <hardware-id-or-> <private-key-path> <output-license-path>',
    );
    exitCode = 2;
    return;
  }

  final hardwareId = args[0];
  final privateKeyFile = File(args[1]).absolute;
  final outputFile = File(args[2]).absolute;

  if (!await privateKeyFile.exists()) {
    stderr.writeln('Private signing key does not exist.');
    exitCode = 2;
    return;
  }
  if (await outputFile.exists()) {
    stderr.writeln('Output license already exists; refusing to overwrite.');
    exitCode = 2;
    return;
  }

  try {
    final seed = base64Url.decode(
      base64Url.normalize((await privateKeyFile.readAsString()).trim()),
    );
    if (seed.length != 32) throw const FormatException();
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);

    final now = DateTime.now().toUtc();
    final expiresAt = DateTime.utc(
      now.year + 1,
      now.month,
      now.day,
      now.hour,
      now.minute,
      now.second,
    );

    final payload = <String, Object?>{
      'format': 'wholesale-pos-license',
      'version': 1,
      'product': 'wholesale_pos',
      'entitlements': ['pos'],
      if (hardwareId != '-') 'hardware_id': hardwareId,
      'issued_at': now.toIso8601String(),
      'expires_at': expiresAt.toIso8601String(),
    };

    final payloadBytes = utf8.encode(jsonEncode(_canonicalize(payload)));
    final signature = await Ed25519().sign(payloadBytes, keyPair: keyPair);
    final contents =
        '${base64Url.encode(payloadBytes)}.${base64Url.encode(signature.bytes)}';

    await outputFile.parent.create(recursive: true);
    final handle = await outputFile.open(mode: FileMode.write);
    try {
      await handle.writeString(contents);
      await handle.flush();
    } finally {
      await handle.close();
    }
    stdout.writeln(
      'License written to ${outputFile.path}. Expires at ${expiresAt.toIso8601String()}.',
    );
  } catch (error) {
    stderr.writeln('License generation failed: ${error.runtimeType}.');
    exitCode = 1;
  }
}

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonicalize(value[key])};
  }
  if (value is List) return value.map(_canonicalize).toList();
  return value;
}
