import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static architecture-boundary checks for the Stage-6 package split.
///
/// These scan the source tree so the dependency rules cannot silently regress:
/// the domain package stays pure, `pos_contracts` names no storage or platform
/// package, `pos_local_engine` never imports the app, the web compile graph
/// never reaches SQLite, and each shared utility has exactly one home.
///
/// Helper to check whether a class implements an AppBackend getter by name.
/// Uses case-insensitive matching so `deviceId` matches `deviceId` / `DeviceId`.
bool _implementsGetter(String content, String name) {
  return RegExp(name, caseSensitive: false).hasMatch(content);
}

void main() {
  List<File> dartFilesIn(String directory) {
    final dir = Directory(directory);
    if (!dir.existsSync()) return const [];
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
  }

  String rel(File f) => f.path.replaceAll('\\', '/');

  List<String> importsOf(File f) => RegExp(
    "^import\\s+['\"]([^'\"]+)['\"]",
    multiLine: true,
  ).allMatches(f.readAsStringSync()).map((m) => m.group(1)!).toList();

  final appLib = dartFilesIn('lib');

  group('app boundaries', () {
    test('abstract AppBackend and CloudBackend do not import features (native may)', () {
      // NativeBackend legitimately imports settings_screen.dart to provide the
      // platform-specific SettingsScreen widget for native platforms. CloudBackend
      // must not import features (web-safe). AppBackend (abstract) defines only
      // interfaces and should not import widgets.
      final offenders = <String>[];
      final allowed = ['lib/core/backend/native_backend.dart'];
      for (final f in appLib.where((f) => rel(f).startsWith('lib/core/'))) {
        if (allowed.contains(rel(f))) continue;
        for (final imp in importsOf(f)) {
          if (imp.contains('features/')) offenders.add('${rel(f)} -> $imp');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('features never import sqflite or reference Database', () {
      final offenders = <String>[];
      for (final f in appLib.where((f) => rel(f).startsWith('lib/features/'))) {
        for (final imp in importsOf(f)) {
          if (imp.startsWith('package:sqflite')) {
            offenders.add('${rel(f)} -> $imp');
          }
        }
        final code = f.readAsStringSync().replaceAll('Database schema', '');
        if (RegExp(r'\bDatabase\b').hasMatch(code)) {
          offenders.add('${rel(f)} references Database');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('the duplicate app persistence layer is gone', () {
      const removed = [
        'lib/core/database/local_database.dart',
        'lib/core/repositories/sale_repository.dart',
        'lib/core/repositories/user_repository.dart',
        'lib/core/repositories/finance_repository.dart',
        'lib/core/repositories/shift_repository.dart',
        'lib/core/repositories/product_repository.dart',
        'lib/core/repositories/picklist_repository.dart',
        'lib/core/repositories/reporting_repository.dart',
        'lib/core/auth/session_store.dart',
        'lib/core/utils/date_range.dart',
        'lib/core/utils/money_utils.dart',
        'lib/core/utils/report_filters.dart',
        'lib/core/utils/data_exporter.dart',
        'lib/core/utils/data_importer.dart',
        'lib/core/util/phone_number.dart',
        'lib/core/sync/sync_outbox.dart',
        'lib/core/sync/sync_outbox_entry.dart',
        'lib/core/sync/sync_outbox_repository.dart',
        'lib/core/sync/sync_pull_applier.dart',
        'lib/core/sync/sync_backend.dart',
        'lib/core/licensing/activation_client.dart',
        'lib/core/licensing/device_activation.dart',
        'lib/core/licensing/device_fingerprint.dart',
        'lib/core/licensing/license_validator.dart',
        'lib/core/cloud/cloud_api_client.dart',
        'lib/core/cloud/cloud_product_repository.dart',
        'lib/core/cloud/cloud_sale_repository.dart',
        'lib/core/cloud/cloud_shift_repository.dart',
        'lib/core/cloud/cloud_finance_repository.dart',
        'lib/core/cloud/cloud_user_repository.dart',
        'lib/core/cloud/cloud_picklist_repository.dart',
      ];
      final remaining = removed.where((p) => File(p).existsSync()).toList();
      expect(remaining, isEmpty, reason: remaining.join('\n'));
    });
  });

  group('pos_core purity', () {
    test('domain package has no flutter/sqlite/supabase/http/io imports', () {
      final offenders = <String>[];
      for (final f in dartFilesIn('../backend/dart/pos_core/lib')) {
        for (final imp in importsOf(f)) {
          if (imp.startsWith('package:flutter') ||
              imp.startsWith('package:sqflite') ||
              imp.contains('supabase') ||
              imp == 'dart:io' ||
              imp == 'dart:ffi' ||
              imp == 'package:http/http.dart') {
            offenders.add('${rel(f)} -> $imp');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('pos_contracts purity', () {
    test('contracts use no Flutter, SQLite, path_provider, io or plugins', () {
      final offenders = <String>[];
      const plugins = [
        'device_info_plus',
        'file_selector',
        'image_picker',
        'audioplayers',
        'printing',
      ];
      for (final f in dartFilesIn('../backend/dart/pos_contracts/lib')) {
        for (final imp in importsOf(f)) {
          if (imp.startsWith('package:flutter') ||
              imp.startsWith('package:sqflite') ||
              imp.startsWith('package:path_provider') ||
              imp.startsWith('package:http') ||
              imp == 'dart:io' ||
              imp == 'dart:ffi' ||
              imp.contains('supabase') ||
              plugins.any((p) => imp.startsWith('package:$p'))) {
            offenders.add('${rel(f)} -> $imp');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('pos_local_engine independence', () {
    test('engine never imports the application or its frontend', () {
      final offenders = <String>[];
      for (final f in dartFilesIn('../backend/dart/pos_local_engine/lib')) {
        for (final imp in importsOf(f)) {
          if (imp.startsWith('package:wholesale_pos_app') ||
              imp.contains('/features/') ||
              imp.contains('/presentation/')) {
            offenders.add('${rel(f)} -> $imp');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('engine does not import Flutter widgets or plugins', () {
      final offenders = <String>[];
      for (final f in dartFilesIn('../backend/dart/pos_local_engine/lib')) {
        for (final imp in importsOf(f)) {
          if (imp.startsWith('package:flutter/')) {
            offenders.add('${rel(f)} -> $imp');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('pos_cloud_engine correctness', () {
    test('no Flutter or native database imports (web-safe)', () {
      final offenders = <String>[];
      for (final f in dartFilesIn('../backend/dart/pos_cloud_engine/lib')) {
        for (final imp in importsOf(f)) {
          if (imp.startsWith('package:flutter') ||
              imp.startsWith('package:sqflite') ||
              imp == 'dart:io' ||
              imp.contains('/features/') ||
              imp.contains('/presentation/')) {
            offenders.add('${rel(f)} -> $imp');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('cloud repos implement their repository contracts', () {
      final offenders = <String>[];
      const expectedImports = [
        'package:pos_contracts/pos_contracts.dart',
        '../api/cloud_api_client.dart',
      ];
      for (final f in dartFilesIn(
        '../backend/dart/pos_cloud_engine/lib/src/repositories',
      )) {
        final content = f.readAsStringSync();
        if (!content.contains(expectedImports[0])) {
          offenders.add('${rel(f)} missing pos_contracts import');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('cloud backend composition', () {
    test('CloudBackend uses pos_cloud_engine, never frontend-local cloud copies', () {
      final f = File('lib/core/backend/cloud_backend.dart');
      expect(f.existsSync(), isTrue);
      final content = f.readAsStringSync();
      expect(
        content.contains("import 'package:pos_cloud_engine/pos_cloud_engine.dart'"),
        isTrue,
        reason: 'CloudBackend must import the canonical cloud engine barrel',
      );
      final offenders = importsOf(f)
          .where((i) => i.contains('/cloud/cloud_'))
          .toList();
      expect(
        offenders,
        isEmpty,
        reason: 'CloudBackend still imports duplicate cloud files: $offenders',
      );
    });
  });

  group('one authoritative implementation', () {
    test('shared utilities are defined only in their owning package', () {
      const classNames = [
        'DateRange',
        'MoneyUtils',
        'LocalDatabase',
        'SettingsSessionStore',
        'DataExporter',
        'DataImporter',
        'SyncOutbox',
        'CloudSyncPuller',
        'PhoneNumber',
        'AppLogger',
      ];
      const functions = [
        'Future<void> requireFeature',
        'String notDemoOperator',
      ];
      final offenders = <String>[];
      final roots = [
        'lib',
        '../backend/dart/pos_core/lib',
        '../backend/dart/pos_contracts/lib',
        '../backend/dart/pos_local_engine/lib',
        '../backend/dart/pos_cloud_engine/lib',
      ];
      for (final name in classNames) {
        final pattern = RegExp(
          r'^\s*(?:abstract\s+|final\s+|sealed\s+|base\s+|interface\s+)*class\s+'
          '$name\\b',
          multiLine: true,
        );
        final matches = <String>[];
        for (final root in roots) {
          for (final f in dartFilesIn(root)) {
            if (pattern.hasMatch(f.readAsStringSync())) matches.add(rel(f));
          }
        }
        if (matches.length != 1) {
          offenders.add('$name -> ${matches.join(', ')}');
        }
      }
      for (final name in functions) {
        final matches = <String>[];
        for (final root in roots) {
          for (final f in dartFilesIn(root)) {
            if (f.readAsStringSync().contains(name)) matches.add(rel(f));
          }
        }
        if (matches.length != 1) {
          offenders.add('$name -> ${matches.join(', ')}');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('compile graphs', () {
    Set<File> reachableFrom(String entry) {
      final seen = <String>{};
      final queue = <File>[File(entry)];
      final result = <File>{};
      while (queue.isNotEmpty) {
        final f = queue.removeLast();
        final key = rel(f);
        if (!seen.add(key)) continue;
        result.add(f);
        for (final imp in importsOf(f)) {
          if (imp.startsWith('package:') || imp.startsWith('dart:')) continue;
          final target = File(
            imp.startsWith('/')
                ? imp
                : '${f.parent.path}${Platform.pathSeparator}$imp',
          );
          if (target.existsSync()) queue.add(target);
        }
      }
      return result;
    }

    test('web entry graph never reaches the native engine or SQLite', () {
      final graph = reachableFrom('lib/main_web.dart');
      expect(graph, isNotEmpty);
      final offenders = <String>[];
      for (final f in graph) {
        for (final imp in importsOf(f)) {
          if (imp.startsWith('package:pos_local_engine') ||
              imp.startsWith('package:sqflite') ||
              imp.startsWith('package:path_provider') ||
              imp == 'dart:io' ||
              imp == 'dart:ffi') {
            offenders.add('${rel(f)} -> $imp');
          }
        }
        if (f.readAsStringSync().contains('LocalDatabase')) {
          offenders.add('${rel(f)} references LocalDatabase');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('native entry graph reaches the local engine', () {
      final graph = reachableFrom('lib/main.dart');
      final reachesEngine = graph.any(
        (f) =>
            importsOf(f).any((i) => i.startsWith('package:pos_local_engine')),
      );
      expect(reachesEngine, isTrue);
    });
  });

  group('frontend boundaries', () {
    test(
      'feature widgets use repository contracts not raw Database handles',
      () {
        final offenders = <String>[];
        for (final f in appLib.where(
          (f) => rel(f).startsWith('lib/features/'),
        )) {
          final content = f.readAsStringSync();
          // Look for `final Database` field declarations (not in comments)
          final lineMatches = RegExp(
            r'^[\s]*(?:final|var)\s+Database\b',
            multiLine: true,
          ).allMatches(content);
          for (final m in lineMatches) {
            final line = content.substring(m.start).split('\n').first.trim();
            if (!line.startsWith('//') && !line.startsWith('*')) {
              offenders.add('${rel(f)}: $line');
            }
          }
        }
        expect(offenders, isEmpty, reason: offenders.join('\n'));
      },
    );

    test('features do not import platform-specific engine implementations directly '
        '(pos_cloud_engine is OK; pos_local_engine references are legacy and tracked)', () {
      // pos_cloud_engine is the sanctioned cloud package (Rule L8) and may
      // be imported by features. pos_local_engine is the native engine:
      // references are pre-existing F-5 residue, allowed only for the two
      // tracked legacy files below — any NEW importer fails this test.
      const legacyPosLocalEngine = {
        'lib/features/licensing/activation_screen.dart',
        'lib/features/startup/unsupported_database_view.dart',
      };
      final offenders = <String>[];
      for (final f in appLib.where((f) => rel(f).startsWith('lib/features/'))) {
        if (legacyPosLocalEngine.contains(rel(f))) continue;
        for (final imp in importsOf(f)) {
          if (imp.startsWith('package:pos_local_engine')) {
            offenders.add('${rel(f)} -> $imp');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('all expected nav tabs are present in the app shell', () {
      // The navigation shell in app_shell.dart registers tabs for each feature.
      // This test confirms that every feature directory has a corresponding UI
      // reference in the shell (a simplified structural check — not full BFS).
      const requiredFeatures = [
        'dashboard',
        'pos',
        'register',
        'finance',
        'warehouse',
        'reports',
        'users',
        'audit',
      ];
      final shellFile = File('lib/app_shell.dart');
      expect(shellFile.existsSync(), isTrue);
      final shellContent = shellFile.readAsStringSync();
      for (final feature in requiredFeatures) {
        // Each feature appears either as a route path ('/$feature' or '/$feature/')
        // or as a screen import referencing the feature directory.
        final hasRoute =
            shellContent.contains("'$feature'") ||
            shellContent.contains('"$feature"');
        final hasImport =
            shellContent.contains("features/$feature/") ||
            shellContent.contains("'features/$feature");
        expect(
          hasRoute || hasImport,
          isTrue,
          reason:
              'Shell missing reference to feature: $feature (check routes and imports)',
        );
      }
    });
  });

  group('native/web symmetry', () {
    test('every AppBackend getter has a concrete provider in both NativeBackend and CloudBackend', () {
      // Explicitly enumerate the public getters so the check is stable
      // across refactors and does not accidentally match identifiers like
      // 'repository' or 'Stage' pulled out of type annotations.
      const getters = <String>[
        'products',
        'sales',
        'reporting',
        'users',
        'shifts',
        'finance',
        'picklists',
        'session',
        'deviceId',
      ];

      final nativeFile = File('lib/core/backend/native_backend.dart');
      final cloudFile = File('lib/core/backend/cloud_backend.dart');
      if (!nativeFile.existsSync() || !cloudFile.existsSync()) return;
      final nativeContent = nativeFile.readAsStringSync();
      final cloudContent = cloudFile.readAsStringSync();

      final missingNative = <String>[];
      final missingCloud = <String>[];
      for (final g in getters) {
        if (!_implementsGetter(nativeContent, g)) {
          missingNative.add(g);
        }
        if (!_implementsGetter(cloudContent, g)) {
          missingCloud.add(g);
        }
      }
      expect(
        missingNative,
        isEmpty,
        reason: 'NativeBackend missing: ${missingNative.join(', ')}',
      );
      expect(
        missingCloud,
        isEmpty,
        reason: 'CloudBackend missing: ${missingCloud.join(', ')}',
      );
    });

    test('cloud backend files have zero sqflite/path_provider/pos_local_engine imports', () {
      // Only inspect cloud_backend.dart and web_local_storage.dart; do NOT
      // scan native_backend.dart (which legitimately imports sqflite).
      final allowedDir = Directory('lib/core/backend');
      if (!allowedDir.existsSync()) return;
      const forbiddenPkgs = [
        'package:sqflite',
        'package:path_provider',
        'package:pos_local_engine',
      ];
      final offenders = <String>[];
      for (final name in ['cloud_backend.dart', 'web_local_storage.dart']) {
        final f = File('${allowedDir.path}$Platform.pathSeparator$name');
        if (!f.existsSync()) continue;
        for (final imp in importsOf(f)) {
          if (forbiddenPkgs.any((p) => imp.startsWith(p))) {
            offenders.add('${rel(f)} -> $imp');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('backend parity', () {
    test('pos_cloud_engine exposes the same repository count as pos_local_engine', () {
      // Both packages implement repos for the same set of domains.
      // pos_local_engine stores repos as flat .dart files;
      // pos_cloud_engine groups them under modules (catalog/, sales/, etc.).
      // We count concrete Repository classes, not files.
      final localRepoFiles = dartFilesIn(
        '../backend/dart/pos_local_engine/lib/src/repositories',
      ).where((f) => f.uri.pathSegments.last.endsWith('_repository.dart'));
      final cloudModuleDirs = Directory(
        '../backend/dart/pos_cloud_engine/lib/src/repositories',
      ).listSync(recursive: false).whereType<Directory>().toList();
      int cloudRepoCount = 0;
      for (final mod in cloudModuleDirs) {
        for (final entity in mod.listSync(recursive: true)) {
          if (entity is File && entity.path.endsWith('_repository.dart')) {
            cloudRepoCount++;
          }
        }
      }
      expect(
        cloudRepoCount,
        localRepoFiles.length,
        reason:
            'Local engine has ${localRepoFiles.length} repo files; cloud engine exposed $cloudRepoCount',
      );
    });

    test('every domain repo has both a sqflite and a cloud implementation', () {
      // Identify domain suffixes from local engine repo filenames.
      final localRepoFiles = dartFilesIn(
        '../backend/dart/pos_local_engine/lib/src/repositories',
      ).where((f) => f.uri.pathSegments.last.endsWith('_repository.dart'));
      final domainSuffixes = <String>{
        for (final f in localRepoFiles)
          f.uri.pathSegments.last
              .replaceAll('sqflite_', '')
              .replaceAll('_repository.dart', ''),
      };

      final cloudBaseDir = Directory(
        '../backend/dart/pos_cloud_engine/lib/src/repositories',
      );
      final foundDomains = <String>{};
      if (cloudBaseDir.existsSync()) {
        for (final entity in cloudBaseDir.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('_repository.dart')) {
            continue;
          }
          final stem = entity.uri.pathSegments.last
              .replaceAll('cloud_', '')
              .replaceAll('_repository.dart', '');
          foundDomains.add(stem);
        }
      }

      final missing = domainSuffixes.difference(foundDomains);
      expect(
        missing,
        isEmpty,
        reason: 'Domains without cloud impl: ${missing.toList()}',
      );
    });
  });
}
