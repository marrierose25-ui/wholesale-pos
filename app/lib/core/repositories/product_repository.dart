import 'package:sqflite/sqflite.dart';

import '../models/product.dart';

/// Data-access contract for saved names / products.
///
/// The [SqfliteProductRepository] implementation is the local-first default
/// used on Android and Windows. The cloud (web/PWA) implementation added in the
/// PWA milestones implements the same contract over HTTP so every screen can
/// depend on this abstract type without knowing where the rows live.
abstract class ProductRepository {
  factory ProductRepository(Database db) = SqfliteProductRepository;

  Future<void> save(Product product);

  /// Updates name, default price and active flag. Used by the Saved Names
  /// screen for rename, price edits and deactivate/reactivate.
  Future<void> update(Product product);

  Future<void> deactivate(String id);

  Future<void> reactivate(String id);

  Future<Product?> getById(String id);

  Future<List<Product>> getAllActive();

  /// Deactivated names are kept for history; the Saved Names screen can
  /// bring them back instead of recreating them.
  Future<List<Product>> getAllInactive();
}

class SqfliteProductRepository implements ProductRepository {
  final Database _db;

  SqfliteProductRepository(this._db);

  @override
  Future<void> save(Product product) async {
    await _ensureNameIsUnique(product.name, excludeId: null);
    await _db.insert('products', product.toMap());
  }

  /// Updates name, default price and active flag. Used by the Saved Names
  /// screen for rename, price edits and deactivate/reactivate.
  @override
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

  @override
  Future<void> deactivate(String id) async {
    await _db.update(
      'products',
      {'is_active': 0, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> reactivate(String id) async {
    await _db.update(
      'products',
      {'is_active': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
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

  @override
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
  @override
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
