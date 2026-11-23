// Extracted verbatim from the pre-Stage-6 application implementation.
// Signatures and documentation are unchanged; only the SQLite factory
// line (which belongs to the implementation package) was removed.
import 'package:pos_core/catalog.dart';

abstract class ProductRepository {

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
