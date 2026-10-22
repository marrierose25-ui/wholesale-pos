import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/product.dart';

class ProductRepository {
  final Database _db;

  ProductRepository(this._db);

  Future<void> save(Product product) async {
    await _db.insert('products', product.toMap());
  }

  /// Updates name, default price and active flag. Used by the Saved Names
  /// screen for rename, price edits and deactivate/reactivate.
  Future<void> update(Product product) async {
    await _db.update(
      'products',
      product.toMap(),
      where: 'id = ?',
      whereArgs: [product.id],
    );
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
