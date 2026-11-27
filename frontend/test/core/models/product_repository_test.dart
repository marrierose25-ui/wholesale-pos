import 'package:flutter_test/flutter_test.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_core/pos_core.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ProductRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = SqfliteProductRepository(db);
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

  Product make(String id, String name) {
    final now = DateTime.now();
    return Product(
      id: id,
      name: name,
      code: 'C-$id',
      unit: 'Item',
      sellingPriceMinorUnits: 100,
      createdAt: now,
      updatedAt: now,
    );
  }

  test('Rejects a duplicate saved name (case-insensitive, trimmed)', () async {
    await repository.save(make('p1', 'Sugar'));
    // Same name, different case.
    await expectLater(repository.save(make('p2', 'sugar')), throwsException);
    // Same name padded with whitespace.
    await expectLater(
      repository.save(make('p3', '  Sugar  ')),
      throwsException,
    );
    // A genuinely different name is allowed.
    await repository.save(make('p4', 'Salt'));
  });

  test(
    'Update: keeping own name is fine, renaming onto another is blocked',
    () async {
      await repository.save(make('a', 'Flour'));
      await repository.save(make('b', 'Bread'));
      // Re-saving 'b' with its own name must not collide with itself.
      await repository.update(make('b', 'Bread'));
      // Renaming 'b' onto the existing 'Flour' is blocked.
      await expectLater(repository.update(make('b', 'Flour')), throwsException);
    },
  );

  test('concurrent saves cannot create duplicate normalized names', () async {
    Future<bool> attemptSave(String id, String name) async {
      try {
        await repository.save(make(id, name));
        return true;
      } catch (_) {
        return false;
      }
    }

    final outcomes = await Future.wait([
      attemptSave('concurrent-1', 'Wholesale Flour'),
      attemptSave('concurrent-2', ' wholesale flour '),
    ]);

    expect(outcomes.where((saved) => saved), hasLength(1));
    expect(await db.query('products'), hasLength(1));
  });
}
