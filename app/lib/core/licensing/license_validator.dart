import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class LicenseValidator {
  // Secret key for HMAC signing
  static final _secretKey = utf8.encode(
    'my-super-secret-key-for-wholesale-pos-2026',
  );

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
          return {
            'error':
                'license.key not found in app folder or executable folder.',
          };
        }
      }

      final contents = await file.readAsString();
      final parts = contents.split('.');
      if (parts.length != 2) {
        return {'error': 'Invalid license.key format'};
      }

      final payloadJson = utf8.decode(base64Url.decode(parts[0]));
      final signatureBytes = base64Url.decode(parts[1]);

      final hmac = Hmac(sha256, _secretKey);
      final digest = hmac.convert(utf8.encode(payloadJson));
      final expectedSignature = digest.bytes;

      // Constant time comparison
      if (expectedSignature.length != signatureBytes.length) {
        return {'error': 'Invalid signature length'};
      }
      int diff = 0;
      for (int i = 0; i < expectedSignature.length; i++) {
        diff |= expectedSignature[i] ^ signatureBytes[i];
      }
      if (diff != 0) {
        return {'error': 'Cryptographic signature is invalid.'};
      }

      final payload = jsonDecode(payloadJson);
      final hwId = await getHardwareId();

      if (payload['hardware_id'] != hwId) {
        return {
          'error':
              'License is for ${payload['hardware_id']}, but this PC is $hwId',
        };
      }
      return payload;
    } catch (e) {
      return {'error': 'Validation exception: $e'};
    }
  }
}
