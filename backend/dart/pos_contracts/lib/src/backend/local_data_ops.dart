import '../licensing/device_activation.dart';

/// The narrow local-data capability the Settings screen needs — everything it
/// used to reach through a raw `Database` handle, expressed as meaningful
/// operations. Implemented by [SqliteLocalDataOps] on native; the UI never sees
/// SQLite.
abstract class LocalDataOps {
  /// Schema version reported in the About footer.
  int get schemaVersion;

  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);

  /// Drops any persisted sign-in session (used when "remember me" is turned
  /// off).
  Future<void> clearStoredSession();

  /// Writes a full JSON backup and returns the saved file path.
  Future<String> exportBackup({required String userId});

  /// Restores a JSON backup produced by [exportBackup], then re-registers
  /// this device so restored sales keep satisfying the FK.
  Future<void> restoreBackup(String path, {required String userId});

  /// The shop's activation code, or null when this till is not activated.
  Future<String?> activationCode();

  /// This machine's stable hardware fingerprint.
  Future<String> deviceFingerprint();

  /// Redeems an activation code on this device (seat join / re-activation).
  Future<DeviceActivationResult> redeemActivationCode(String code);
}
