import 'package:sqflite/sqflite.dart';

import '../models/product.dart';

class ProductRepository {
  final Database _db;

  ProductRepository(this._db);

  Future<void> save(Product product) async {
    await _ensureNameIsUnique(product.name, excludeId: null);
    await _db.insert('products', product.toMap());
  }

  /// Updates name, default price and active flag. Used by the Saved Names
  /// screen for rename, price edits and deactivate/reactivate.
  Future<void> update(Product product) async {
    await _ensureNameIsUnique(product.name, excludeId: product.id);
    await _db.update(
      'products',
      product.toMap(),
      where: 'id = ?',
      whereArgs: [product.id],
    );
  }

  /// Saved names are POS search shortcuts, so two products sharing a name make
  /// tapping ambiguous. Enforce uniqueness here (case-insensitive, trimmed)
  /// rather than with a raw UNIQUE index, which would fail the migration on
  /// any duplicates that already exist and fights the "code is the unique key"
  /// design. Blocks against every product, active or not, so a deactivated
  /// name can be reactivated instead of recreated.
  Future<void> _ensureNameIsUnique(String name, {String? excludeId}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return; // empty names are rejected by the form.
    final maps = await _db.query(
      'products',
      columns: ['id'],
      where:
          'LOWER(TRIM(name)) = LOWER(TRIM(?))'
          '${excludeId != null ? ' AND id <> ?' : ''}',
      whereArgs: excludeId != null ? [trimmed, excludeId] : [trimmed],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      throw Exception(
        'A saved name "$trimmed" already exists. Names must be unique.',
      );
    }
  }

  Future<void> deactivate(String id) async {
    await _db.update(
      'products',
      {'is_active': 0, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> reactivate(String id) async {
    await _db.update(
      'products',
      {'is_active': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Product?> getById(String id) async {
    final maps = await _db.query(
      'products',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return Product.fromMap(maps.first);
  }

  Future<List<Product>> getAllActive() async {
    final maps = await _db.query(
      'products',
      where: 'is_active = ?',
      whereArgs: [1],
      orderBy: 'name ASC',
    );

    return maps.map((map) => Product.fromMap(map)).toList();
  }

  /// Deactivated names are kept for history; the Saved Names screen can
  /// bring them back instead of recreating them.
  Future<List<Product>> getAllInactive() async {
    final maps = await _db.query(
      'products',
      where: 'is_active = ?',
      whereArgs: [0],
      orderBy: 'name ASC',
    );

    return maps.map((map) => Product.fromMap(map)).toList();
  }
}
