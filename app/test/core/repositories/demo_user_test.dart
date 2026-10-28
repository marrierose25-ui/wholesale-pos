import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/auth/features.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/user_repository.dart';

// Covers the permanent training account: it is created exactly once, always a
// CASHIER that can sign in with the fixed demo password, can never be
// deactivated, cannot be forged through createUser, and keeps its feature ticks
// editable so the owner can retrain different people.
void main() {
  late Database db;
  late UserRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = UserRepository(db);
    // An active owner is the actor for the status/permission guards.
    await db.insert('users', {
      'id': 'owner-1',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'OWNER',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
  });

  tearDown(() async {
    await db.close();
  });

  test('ensureDemoUser is idempotent and creates one active cashier', () async {
    await repository.ensureDemoUser();
    await repository.ensureDemoUser();

    final users = await repository.getAllUsers();
    final demos = users.where((u) => u.isDemo).toList();

    expect(demos.length, 1);
    expect(demos.single.username, 'demo');
    expect(demos.single.role, 'CASHIER');
    expect(demos.single.isActive, isTrue);
    expect(demos.single.permissions, kDefaultStaffPermissions);
  });

  test('the demo account signs in with the fixed demo password', () async {
    await repository.ensureDemoUser();

    final user = await repository.authenticate('demo', 'demo1234');

    expect(user, isNotNull);
    expect(user!.isDemo, isTrue);
    expect(user.role, 'CASHIER');
  });

  test('the demo account cannot be deactivated', () async {
    await repository.ensureDemoUser();
    final demo = (await repository.getAllUsers()).firstWhere((u) => u.isDemo);

    await expectLater(
      repository.setUserActive(
        targetUserId: demo.id,
        active: false,
        actingUserId: 'owner-1',
      ),
      throwsA(
        predicate(
          (e) => e.toString().contains('cannot be deactivated'),
          'mentions the demo guard',
        ),
      ),
    );

    // Still active afterwards.
    final after = await repository.getById(demo.id);
    expect(after, isNotNull);
    expect(after!.isActive, isTrue);
  });

  test('createUser rejects the reserved demo username', () async {
    await expectLater(
      repository.createUser('demo', 'password123', 'CASHIER'),
      throwsException,
    );
    // Case-insensitive too.
    await expectLater(
      repository.createUser('DEMO', 'password123', 'CASHIER'),
      throwsException,
    );
  });

  test('the owner can retrain the demo account permissions', () async {
    await repository.ensureDemoUser();
    final demo = (await repository.getAllUsers()).firstWhere((u) => u.isDemo);

    await repository.setUserPermissions(demo.id, const ['pos', 'finance']);

    final updated = await repository.getById(demo.id);
    expect(updated, isNotNull);
    expect(
      updated!.permissions,
      normalizeFeatureKeys(const ['pos', 'finance']),
    );
    expect(updated.can('finance'), isTrue);
    expect(updated.can('reports'), isFalse);
    // Editing permissions never clears the protected flag.
    expect(updated.isDemo, isTrue);
  });
}
