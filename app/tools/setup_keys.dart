import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tools/setup_keys.dart <private-key-path-outside-project>',
    );
    exitCode = 2;
    return;
  }
  final project = Directory.current.resolveSymbolicLinksSync();
  final destination = File(args.single).absolute;
  final parent = await destination.parent.create(recursive: true);
  final resolvedParent = await parent.resolveSymbolicLinks();

  if (resolvedParent == project ||
      resolvedParent.startsWith('$project${Platform.pathSeparator}')) {
    stderr.writeln('Refusing to store private key inside the project.');
    exitCode = 2;
    return;
  }
  if (await destination.exists()) {
    stderr.writeln(
      'Private-key destination already exists; refusing to overwrite.',
    );
    exitCode = 2;
    return;
  }

  try {
    final pair = await Ed25519().newKeyPair();
    final privateBytes = await pair.extractPrivateKeyBytes();
    final publicKey = await pair.extractPublicKey();
    final publicHex = publicKey.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();

    await destination.create(exclusive: true);
    final keyHandle = await destination.open(mode: FileMode.writeOnly);
    try {
      await keyHandle.writeString(base64Url.encode(privateBytes));
      await keyHandle.flush();
    } finally {
      await keyHandle.close();
    }

    stdout.writeln('Private signing key written to ${destination.path}.');
    stdout.writeln('Back it up now; it is never written into the project.');
    stdout.writeln('');
    stdout.writeln('Public verification key (hex):');
    stdout.writeln(publicHex);
    stdout.writeln('');
    stdout.writeln('Build the licensed application with:');
    stdout.writeln(
      'flutter build windows --release '
      '--dart-define=WHOLESALE_POS_LICENSE_PUBLIC_KEY=$publicHex',
    );
  } catch (error) {
    stderr.writeln('Key setup failed: ${error.runtimeType}.');
    exitCode = 1;
  }
}
