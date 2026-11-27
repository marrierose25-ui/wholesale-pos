import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show sqfliteFfiInit;

/// Backup/restore round-trip for product images: the JPEG bytes must survive
/// export -> import still linked to the correct product, malformed rows must
/// be skipped safely, and a backup that predates the image table restores
/// cleanly.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);
  final String documentsPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  late Directory docsDir;
  setUpAll(() async {
    sqfliteFfiInit();
    docsDir = await Directory.systemTemp.createTemp('img_backup_docs_');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });
  tearDownAll(() async {
    try {
      await docsDir.delete(recursive: true);
    } catch (_) {}
  });

  const ownerId = 'owner-1';
  const productId = 'prod-img-1';
  final jpeg = base64Encode(List<int>.generate(256, (i) => i % 256));

  int seq = 0;

  Future<void> seedOwner(Database db) async {
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': ownerId,
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'OWNER',
      'is_active': 1,
      'permissions': '[]',
      'is_demo': 0,
      'created_at': now,
      'updated_at': now,
    });
  }

  // Real files: sqflite's ':memory:' path aliases one shared database per
  // factory, which would collide across tests.
  Future<Database> seeded() async {
    seq++;
    final dir = await Directory.systemTemp.createTemp('img_backup_$seq');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final db = await LocalDatabase.openAt(p.join(dir.path, 'db.sqlite'));
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': ownerId,
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'OWNER',
      'is_active': 1,
      'permissions': '[]',
      'is_demo': 0,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('products', {
      'id': productId,
      'name': 'Berbere',
      'code': 'B-1',
      'category': null,
      'unit': 'Kg',
      'selling_price_minor_units': 12000,
      'bought_price_minor_units': 8000,
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('product_images', {
      'product_id': productId,
      'jpeg_bytes': base64Decode(jpeg),
      'created_at': now,
      'updated_at': now,
    });
    return db;
  }

  test('image bytes round-trip linked to the correct product', () async {
    final source = await seeded();
    final exportPath = await DataExporter.exportToJson(
      source,
      requestingUserId: ownerId,
    );
    final exported =
        jsonDecode(await File(exportPath).readAsString()) as Map;
    expect(exported['product_images'], hasLength(1));
    expect(
      (exported['product_images'] as List).single['jpeg_bytes'],
      jpeg,
    );

    // Restore into a second, empty database.
    final tdir = await Directory.systemTemp.createTemp('img_backup_t$seq');
    addTearDown(() async {
      try {
        await tdir.delete(recursive: true);
      } catch (_) {}
    });
    final target = await LocalDatabase.openAt(p.join(tdir.path, 'db.sqlite'));
    await seedOwner(target);
    await DataImporter.importFromJson(
      target,
      exportPath,
      requestingUserId: ownerId,
    );

    final images = await target.query('product_images');
    expect(images, hasLength(1));
    expect(images.single['product_id'], productId);
    expect(
      base64Encode(images.single['jpeg_bytes'] as List<int>),
      jpeg,
    );
    // Linkage: the product the image belongs to came back too.
    final products = await target.query('products');
    expect(products.single['id'], productId);
    expect(products.single['bought_price_minor_units'], 8000);

    await source.close();
    await target.close();
    await File(exportPath).delete();
  });

  test('malformed and orphaned image rows are skipped, not fatal', () async {
    final source = await seeded();
    final exportPath = await DataExporter.exportToJson(
      source,
      requestingUserId: ownerId,
    );

    // Corrupt the backup: bad base64, an orphan product_id, and a null row.
    final data =
        jsonDecode(await File(exportPath).readAsString()) as Map<String, dynamic>;
    data['product_images'] = [
      {'product_id': productId, 'jpeg_bytes': '!!!not-base64!!!',
       'created_at': '2026-01-01'},
      {'product_id': 'ghost-product', 'jpeg_bytes': jpeg,
       'created_at': '2026-01-01'},
      {'product_id': null, 'jpeg_bytes': jpeg, 'created_at': '2026-01-01'},
    ];
    final badPath = '$exportPath.bad';
    await File(badPath).writeAsString(jsonEncode(data));

    final tdir = await Directory.systemTemp.createTemp('img_backup_t$seq');
    addTearDown(() async {
      try {
        await tdir.delete(recursive: true);
      } catch (_) {}
    });
    final target = await LocalDatabase.openAt(p.join(tdir.path, 'db.sqlite'));
    await seedOwner(target);
    await DataImporter.importFromJson(
      target,
      badPath,
      requestingUserId: ownerId,
    );
    // Every image row was unusable -> none restored, restore still succeeded.
    expect(await target.query('product_images'), isEmpty);
    expect(await target.query('products'), hasLength(1));

    await source.close();
    await target.close();
    await File(exportPath).delete();
    await File(badPath).delete();
  });

  test('backup without product_images restores cleanly', () async {
    final source = await seeded();
    final exportPath = await DataExporter.exportToJson(
      source,
      requestingUserId: ownerId,
    );
    final data =
        jsonDecode(await File(exportPath).readAsString()) as Map<String, dynamic>;
    data.remove('product_images'); // simulate a pre-image backup
    data.remove('stores');
    data.remove('store_inventory');
    final oldPath = '$exportPath.old';
    await File(oldPath).writeAsString(jsonEncode(data));

    final tdir = await Directory.systemTemp.createTemp('img_backup_t$seq');
    addTearDown(() async {
      try {
        await tdir.delete(recursive: true);
      } catch (_) {}
    });
    final target = await LocalDatabase.openAt(p.join(tdir.path, 'db.sqlite'));
    await seedOwner(target);
    await DataImporter.importFromJson(
      target,
      oldPath,
      requestingUserId: ownerId,
    );
    expect(await target.query('products'), hasLength(1));
    expect(await target.query('product_images'), isEmpty);
    expect(await target.query('stores'), isEmpty);

    await source.close();
    await target.close();
    await File(exportPath).delete();
    await File(oldPath).delete();
  });
}
