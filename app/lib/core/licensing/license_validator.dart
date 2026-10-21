import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class LicenseValidator {
  // Shared secret for HMAC
  static final _secretKey = utf8.encode('wholesale-pos-secret-key-2026');

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
      if (parts.length != 2) return {'error': 'Invalid format'};

      final payloadJson = utf8.decode(base64Url.decode(parts[0]));
      final signatureBytes = base64Url.decode(parts[1]);

      // Verify HMAC
      final hmac = Hmac(sha256, _secretKey);
      final expectedDigest = hmac.convert(utf8.encode(payloadJson)).bytes;

      // Compare bytes safely
      if (expectedDigest.length != signatureBytes.length) {
        return {'error': 'Invalid signature length'};
      }
      int diff = 0;
      for (int i = 0; i < expectedDigest.length; i++) {
        diff |= expectedDigest[i] ^ signatureBytes[i];
      }
      if (diff != 0) return {'error': 'Invalid signature.'};

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
}
