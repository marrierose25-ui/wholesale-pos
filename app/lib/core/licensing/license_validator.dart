import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

class LicenseValidator {
  static final _publicKeyHex =
      'b94dc2d903a1e3850e7d88fc42b427350e3ff8211a54a71c681c42a2f4541b4e';

  static Future<String> getHardwareId() async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('powershell', [
          '-Command',
          '(Get-CimInstance Win32_ComputerSystemProduct).UUID',
        ]);
        final uuid = result.stdout.toString().trim();
        if (uuid.isNotEmpty) {
          return uuid;
        }
      }
      return Platform.localHostname;
    } catch (_) {
      return Platform.localHostname;
    }
  }

  static Future<Map<String, dynamic>?> validateLicense() async {
    try {
      var file = File('license.key');
      if (!await file.exists()) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        file = File('$exeDir/license.key');
        if (!await file.exists()) {
          return {'error': 'license.key not found.'};
        }
      }

      final contents = await file.readAsString();
      final parts = contents.split('.');
      if (parts.length != 2) {
        return {'error': 'Invalid format'};
      }

      final payloadJson = utf8.decode(base64Url.decode(parts[0]));
      final signatureBytes = base64Url.decode(parts[1]);

      final publicKey = SimplePublicKey(
        hexToBytes(_publicKeyHex),
        type: KeyPairType.ed25519,
      );
      final signature = Signature(signatureBytes, publicKey: publicKey);

      final isValid = await Ed25519().verify(
        utf8.encode(payloadJson),
        signature: signature,
      );
      if (!isValid) {
        return {'error': 'Invalid signature.'};
      }

      final payload = jsonDecode(payloadJson);
      final hwId = await getHardwareId();

      if (payload['hardware_id'] != hwId) {
        return {'error': 'License is for a different device.'};
      }
      return payload;
    } catch (e) {
      return {'error': 'Error: $e'};
    }
  }

  static List<int> hexToBytes(String hex) {
    final result = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }
}
