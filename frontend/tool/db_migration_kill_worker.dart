// Test worker for interrupted_migration_test.dart. Opens a database through
// the real LocalDatabase migration path, pauses inside the upgrade
// transaction at the requested checkpoint, drops the marker file, and waits
// to be killed.
//
// Runs under the plain Dart VM (`dart run`), which works because
// package:pos_local_engine/database.dart is pure Dart — the Flutter-bound
// repositories and path_provider live outside this entry point.
//
// Usage: dart run tool/db_migration_kill_worker.dart <dbPath> <checkpoint> <marker>
// Checkpoints: start | mid | late
import 'dart:io';

import 'package:pos_local_engine/database.dart';

Future<void> main(List<String> args) async {
  final dbPath = args[0];
  final checkpoint = args[1];
  final marker = args[2];

  var hit = false;
  LocalDatabase.migrationTestPauseHook = (name) async {
    if (name == checkpoint && !hit) {
      hit = true;
      await File(marker).writeAsString('hit:$checkpoint');
      // The parent test kills this process while the migration transaction
      // is still open. Never reached in a passing run.
      await Future<void>.delayed(const Duration(days: 365));
    }
  };

  await LocalDatabase.openAt(dbPath);
  stdout.writeln('OPENED');
  await stdout.flush();
}
