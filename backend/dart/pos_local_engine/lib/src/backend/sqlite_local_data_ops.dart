import 'package:sqflite/sqflite.dart';

import '../auth/settings_session_store.dart';
import '../database/local_database.dart';
import '../licensing/device_activation.dart';
import '../licensing/device_fingerprint.dart';
import '../utils/data_exporter.dart';
import '../utils/data_importer.dart';
import 'package:pos_contracts/pos_contracts.dart';

/// [LocalDataOps] backed by the app's single shared [Database]. All safeguards
/// live in the underlying statics (pre-restore validation, owner check,
/// device re-registration); this class only adapts the signatures.
class SqliteLocalDataOps implements LocalDataOps {
  final Database db;

  SqliteLocalDataOps(this.db);

  @override
  int get schemaVersion => LocalDatabase.schemaVersion;

  @override
  Future<String?> getSetting(String key) => LocalDatabase.getSetting(db, key);

  @override
  Future<void> setSetting(String key, String value) =>
      LocalDatabase.setSetting(db, key, value);

  @override
  Future<void> clearStoredSession() => SettingsSessionStore(db).clear();

  @override
  Future<String> exportBackup({required String userId}) =>
      DataExporter.exportToJson(db, requestingUserId: userId);

  @override
  Future<void> restoreBackup(String path, {required String userId}) async {
    await DataImporter.importFromJson(
      db,
      path,
      requestingUserId: userId,
    );
    // Restores replace the devices table; make sure this machine still has
    // a device row so new sales do not violate the foreign key.
    await LocalDatabase.registerCurrentDevice(db);
  }

  @override
  Future<String?> activationCode() =>
      LocalDatabase.getSetting(db, DeviceActivation.activationCodeKey);

  @override
  Future<String> deviceFingerprint() => DeviceFingerprint.get(db);

  @override
  Future<DeviceActivationResult> redeemActivationCode(String code) =>
      DeviceActivation.redeem(db, code);
}
