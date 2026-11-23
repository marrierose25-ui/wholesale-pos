import 'package:pos_local_engine/pos_local_engine.dart';

import 'sync_service.dart';

/// Everything the UI needs from the sync engine.
///
/// Three moments need it directly instead of waiting for the timer: a device
/// that joins an existing shop must pull its accounts BEFORE the login screen
/// decides whether this is first-time setup; a sign-in should refresh the ledger
/// immediately rather than on the next tick; and Settings lets the operator see
/// the loop's state and restart it by hand.
class SyncRuntime {
  final SyncService service;
  final CloudSyncPuller puller;

  const SyncRuntime({required this.service, required this.puller});
}
