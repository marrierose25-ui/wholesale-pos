import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common/sqflite.dart';

import 'local_database.dart';

/// Opens the application database in the platform app-support directory.
///
/// This lives outside [LocalDatabase] because `path_provider` is a Flutter
/// plugin: keeping it in a separate library lets `local_database.dart` stay
/// importable from pure Dart (headless tools, migration workers), exposed
/// through `package:pos_local_engine/database.dart`.
Future<Database> openApplicationDatabase() async {
  LocalDatabase.configureFactoryForPlatform();
  final dir = await getApplicationSupportDirectory();
  return LocalDatabase.openAt(p.join(dir.path, LocalDatabase.databaseName));
}
