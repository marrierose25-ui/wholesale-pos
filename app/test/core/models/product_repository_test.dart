import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/models/product.dart';
import 'package:wholesale_pos_app/core/repositories/product_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ProductRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = ProductRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('Can save and retrieve a product', () async {
    final now = DateTime.now();
    final product = Product(
      id: 'prod-1',
      name: 'White Flour 50kg',
      code: 'FLOUR-50',
      category: 'Baking',
      unit: 'Bag',
      sellingPriceMinorUnits: 450000,
      createdAt: now,
      updatedAt: now,
    );

    await repository.save(product);
    final fetched = await repository.getById('prod-1');

    expect(fetched, isNotNull);
    expect(fetched!.name, 'White Flour 50kg');
    expect(fetched.sellingPriceMinorUnits, 450000);
    expect(fetched.unit, 'Bag');
  });

  test('Returns null for a missing product', () async {
    final fetched = await repository.getById('unknown-id');
    expect(fetched, isNull);
  });
}
