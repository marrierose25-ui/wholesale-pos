import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
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
///  - Android: Settings.Secure.ANDROID_ID (via [device_info_plus]). Survives
///    an app uninstall/reinstall — it is fixed per (device, user, signing key)
///    and only changes on a factory reset or a different signing key, so a
///    reinstalled phone reuses its existing seat instead of burning a new one.
///  - iOS: identifierForVendor — stable while at least one app from the same
///    vendor remains installed.
///    Both fall back to a DB-persisted install UUID only if the platform id is
///    unavailable, so activation can never hard-fail (that fallback is NOT
///    reinstall-stable, but is a better outcome than crashing the launcher).
///
/// The output is always the SHA-256 hex of a namespaced raw value, so the
/// caller never leaks a plain hardware identifier to the server.
class DeviceFingerprint {
  static const String installUuidKey = 'device_install_uuid';
  static const String _settingsTable = 'settings';

  /// Returns the current device's fingerprint. Requires the SQLite [db] so
  /// the mobile install-UUID fallback can be created / read.
  static Future<String> get(Database db) async {
    final raw = await _rawValue(db);
    return sha256.convert(utf8.encode(raw)).toString();
  }

  static Future<String> _rawValue(Database db) async {
    final prefix = Platform.isAndroid
        ? 'and'
        : Platform.isIOS
        ? 'ios'
        : 'other';

    // 1. Preferred: a stable, reinstall-surviving platform identifier.
    final stable = await _stablePlatformId();
    if (stable != null && stable.isNotEmpty) {
      return '$prefix|$stable';
    }

    // 2. Windows: the motherboard UUID, cached in the settings table so a
    //    transient CIM failure (AV scan / slow box / first-launch timeout)
    //    can never flip the fingerprint and re-bind the seat — the same class
    //    of bug that burned seats on Android. Only a real UUID is cached; the
    //    hostname fallback is transient and gets replaced by the cached UUID
    //    on the next successful startup.
    if (Platform.isWindows) {
      const hwCacheKey = 'device_hw_uuid';
      final cached = await LocalDatabase.getSetting(db, hwCacheKey);
      if (cached != null && cached.isNotEmpty) {
        return 'win|$cached';
      }
      final hwid = await LicenseValidator.tryGetHardwareId();
      if (hwid != null && hwid.isNotEmpty) {
        await LocalDatabase.setSetting(db, hwCacheKey, hwid);
        return 'win|$hwid';
      }
      return 'win|${Platform.localHostname}';
    }

    // 3. Fallback for mobile when the platform id is unavailable: a random
    //    UUID persisted in SQLite. Reinstall-stable only if the DB survives.
    if (Platform.isAndroid || Platform.isIOS) {
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

  /// Reads the OS-provided identifier that persists across an app reinstall.
  /// Returns null if unavailable (unsupported platform, plugin missing in a
  /// unit-test host, or a permission error) so the caller can fall back.
  static Future<String?> _stablePlatformId() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        return (await info.androidInfo).id;
      }
      if (Platform.isIOS) {
        return (await info.iosInfo).identifierForVendor;
      }
    } catch (_) {
      // Plugin channel unavailable — caller falls back to the safer paths.
    }
    return null;
  }

  /// Convenience for widget tests that don't want to touch a real database.
  /// Uses the same SHA-256 shape so the stored license payload verifies.
  static String forTesting(String seed) =>
      sha256.convert(utf8.encode('test|$seed')).toString();

  /// Exposed so tests can assert the install UUID row lives in `settings`
  /// and nowhere else (i.e., never leaks into JSON backups).
  static const String settingsTableName = _settingsTable;
}
