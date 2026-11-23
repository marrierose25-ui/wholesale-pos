/// Pure-Dart entry point for the local database layer.
///
/// Unlike `package:pos_local_engine/pos_local_engine.dart` (which pulls in
/// Flutter-bound repositories), this library exposes only
/// [LocalDatabase] — safe to import from headless Dart tools such as the
/// interrupted-migration test worker.
library;

export 'src/database/local_database.dart';
