import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:uuid/uuid.dart';

import '../database/local_database.dart';
import 'license_validator.dart';

/// Stable-per-device identifier used to bind a licensing seat to a specific
/// phone / PC. The licensing server stores this hash on each device
/// registration and includes it in every signed license payload; the client
/// re-computes it on every startup and refuses to run a license whose bound
/// fingerprint does not match.
///
/// Platform choices:
///  - Windows: WMI motherboard UUID (already used by LicenseValidator).
///    Stable across app reinstalls and Windows updates, changes only if the
///    motherboard itself is replaced.
///  - Android / iOS: a random UUID generated on first launch and persisted
///    in the SQLite `settings` table under [installUuidKey]. Stable across
///    app updates; changes on uninstall (SQLite file is wiped) — the buyer
///    re-activates and either reuses their existing seat (same code + device
///    row already exists server-side after reactivation window) or a Umer
///    tool deactivates the stale registration.
///
/// The output is always the SHA-256 hex of a namespaced raw value, so the
/// caller never leaks a plain hardware identifier to the server.
class DeviceFingerprint {
  static const String installUuidKey = 'device_install_uuid';
  static const String _settingsTable = 'settings';

  /// Returns the current device's fingerprint. Requires the SQLite [db] so
  /// the mobile install UUID can be created / read.
  static Future<String> get(Database db) async {
    final raw = await _rawValue(db);
    return sha256.convert(utf8.encode(raw)).toString();
  }

  static Future<String> _rawValue(Database db) async {
    if (Platform.isWindows) {
      final hwid = await LicenseValidator.getHardwareId();
      return 'win|$hwid';
    }
    if (Platform.isAndroid || Platform.isIOS) {
      final prefix = Platform.isAndroid ? 'and' : 'ios';
      var uuid = await LocalDatabase.getSetting(db, installUuidKey);
      if (uuid == null || uuid.isEmpty) {
        uuid = const Uuid().v4();
        await LocalDatabase.setSetting(db, installUuidKey, uuid);
      }
      return '$prefix|$uuid';
    }
    // Unsupported platform (macOS / Linux / web): deterministic fallback so
    // tests can still exercise the code path. Not shipped.
    return 'other|${Platform.localHostname}';
  }

  /// Convenience for widget tests that don't want to touch a real database.
  /// Uses the same SHA-256 shape so the stored license payload verifies.
  static String forTesting(String seed) =>
      sha256.convert(utf8.encode('test|$seed')).toString();

  /// Exposed so tests can assert the install UUID row lives in `settings`
  /// and nowhere else (i.e., never leaks into JSON backups).
  static const String settingsTableName = _settingsTable;
}
