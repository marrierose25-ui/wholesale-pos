import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/product.dart';

class ProductRepository {
  final Database _db;

  ProductRepository(this._db);

  Future<void> save(Product product) async {
    await _db.insert('products', product.toMap());
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
}
