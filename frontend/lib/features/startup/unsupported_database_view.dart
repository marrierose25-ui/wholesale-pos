import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pos_local_engine/pos_local_engine.dart';

/// Dedicated recovery screen shown when the on-disk database was written by
/// a NEWER build of the app than the one installed.
///
/// The database was refused, not damaged: `user_version`, tables, rows,
/// indexes and triggers are untouched, and a `.bak` safety copy was taken
/// before the refusal. The only safe recovery is installing the newer app
/// (or restoring the previous installation) — this screen must never suggest
/// deleting, uninstalling or hand-editing database files.
class UnsupportedDatabaseVersionView extends StatelessWidget {
  const UnsupportedDatabaseVersionView({super.key, required this.error});

  final UnsupportedDatabaseVersionException error;

  Future<String?> _backupPath() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final path = p.join(
        dir.path,
        '${LocalDatabase.databaseName}${LocalDatabase.backupSuffix}',
      );
      return await File(path).exists() ? path : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                shrinkWrap: true,
                children: [
                  const Icon(Icons.system_update_alt, size: 40),
                  const SizedBox(height: 12),
                  const Text(
                    'This database belongs to a newer version of Wholesale POS',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'The database on this device was last used by a newer '
                    'version of the app (schema v${error.foundVersion}), but '
                    'this installation only supports up to schema '
                    'v${error.supportedVersion}.',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your data is safe: the app refused to open the '
                    'database rather than risk damaging it, and nothing was '
                    'changed or deleted.',
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'What to do:',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '1. Install the newer version of Wholesale POS that '
                    'created this database (or restore the previous '
                    'installation), then open the app again.\n'
                    '2. Do NOT uninstall the app, delete app data, or replace '
                    'database files manually — that is the only way to lose '
                    'this data.\n'
                    '3. If you need help, send support the details below.',
                  ),
                  const SizedBox(height: 16),
                  FutureBuilder<String?>(
                    future: _backupPath(),
                    builder: (context, snapshot) {
                      final backup = snapshot.data;
                      return Text(
                        'Detected schema: v${error.foundVersion}   •   '
                        'Supported: v${error.supportedVersion}   •   '
                        'Safety copy: '
                        '${backup == null ? 'not found' : 'created at $backup'}',
                        style: const TextStyle(fontSize: 12),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
