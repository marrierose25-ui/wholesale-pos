import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/user_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late UserRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = UserRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('Seeds default owner and authenticates', () async {
    await repository.seedDefaultUser();

    final user = await repository.authenticate('owner', 'admin');

    expect(user, isNotNull);
    expect(user!.username, 'owner');
    expect(user.role, 'OWNER');
  });

  test('Fails authentication with wrong password', () async {
    await repository.seedDefaultUser();

    final user = await repository.authenticate('owner', 'wrongpass');

    expect(user, isNull);
  });

  test('Creates a new cashier and lists all users', () async {
    await repository.seedDefaultUser();
    await repository.createUser('cashier1', 'password123', 'CASHIER');

    final users = await repository.getAllUsers();

    expect(users.length, 2); // Owner + Cashier
    expect(users.any((u) => u.username == 'cashier1'), isTrue);

    final newUser = await repository.authenticate('cashier1', 'password123');
    expect(newUser, isNotNull);
    expect(newUser!.role, 'CASHIER');
  });
}
