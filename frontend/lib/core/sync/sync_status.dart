/// What the background sync loop is doing, in the terms an operator needs:
/// whether this device can reach the cloud at all, when it last worked, and —
/// the case that used to be invisible — why it cannot.
///
/// A till that holds a pre-Phase-17 `license.key` looks perfectly healthy: it
/// signs in, rings up sales, and quietly never syncs. That is exactly the
/// "my other device sees nothing" complaint, so the state is now reported
/// rather than swallowed.
class SyncStatus {
  /// False when the build carries no gateway URL at all (plain offline build).
  final bool configured;

  /// Last cycle that completed without an error.
  final DateTime? lastSuccess;

  /// Why the last cycle failed, or null when it succeeded.
  final String? error;

  /// True when [error] is the cloud refusing this device's licence — retrying
  /// will never help, the device has to be activated once.
  final bool authenticationFailed;

  /// Rows written into SQLite by the last pull: transactions another till
  /// recorded that this one had never seen.
  final int applied;

  /// Outbox rows still waiting to upload.
  final int queued;

  /// Rows the cloud permanently refused, held in durable quarantine with
  /// their payloads until an operator retries or discards them.
  final int quarantined;

  const SyncStatus({
    this.configured = false,
    this.lastSuccess,
    this.error,
    this.authenticationFailed = false,
    this.applied = 0,
    this.queued = 0,
    this.quarantined = 0,
  });

  /// No remote target on this build; nothing is expected to happen.
  static const SyncStatus disabled = SyncStatus();

  bool get isConnected => configured && lastSuccess != null && error == null;

  bool get isFailing => error != null;

  /// One plain sentence for the settings screen.
  String get summary {
    if (!configured) {
      return 'Cloud sync is off on this build. Everything stays on this device.';
    }
    final failure = error;
    if (failure != null) {
      return authenticationFailed
          ? 'This device is not activated for cloud sync. Enter your shop '
                'activation code once and it will download every other '
                'device\'s transactions.'
          : 'Last sync failed: $failure';
    }
    final last = lastSuccess;
    if (last == null) return 'Waiting for the first sync…';
    final clock =
        '${last.hour.toString().padLeft(2, '0')}:'
        '${last.minute.toString().padLeft(2, '0')}';
    if (applied > 0) {
      return 'Synced $clock · $applied new record'
          '${applied == 1 ? '' : 's'} downloaded from other devices.';
    }
    return 'Synced $clock · up to date with every device.';
  }
}
