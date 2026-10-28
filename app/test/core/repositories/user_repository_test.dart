import 'dart:convert';

import 'package:crypto/crypto.dart';
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

  test('Sets up a first owner with a secure password', () async {
    await repository.createFirstOwner('owner', 'long-strong-password');

    final user = await repository.authenticate('owner', 'long-strong-password');

    expect(user, isNotNull);
    expect(user!.username, 'owner');
    expect(user.role, 'OWNER');
  });

  test('Rejects a wrong owner password and repeat setup', () async {
    await repository.createFirstOwner('owner', 'long-strong-password');

    final user = await repository.authenticate('owner', 'wrongpass');

    expect(user, isNull);
    await expectLater(
      repository.createFirstOwner('another', 'long-strong-password'),
      throwsException,
    );
  });

  test('Creates a new cashier and lists all users', () async {
    await repository.createFirstOwner('owner', 'long-strong-password');
    await repository.createUser('cashier1', 'password123', 'CASHIER');

    final users = await repository.getAllUsers();

    expect(users.length, 2); // Owner + Cashier
    expect(users.any((u) => u.username == 'cashier1'), isTrue);

    final newUser = await repository.authenticate('cashier1', 'password123');
    expect(newUser, isNotNull);
    expect(newUser!.role, 'CASHIER');
  });

  test('Authenticates and upgrades a legacy password hash', () async {
    const password = 'legacy-password';
    const salt = 'old-static-salt';
    final key = utf8.encode(password);
    var bytes = Hmac(sha256, key).convert(utf8.encode(salt)).bytes;
    for (var i = 0; i < 10000; i++) {
      bytes = Hmac(sha256, key).convert(bytes).bytes;
    }
    await db.insert('users', {
      'id': 'legacy-user',
      'username': 'legacy',
      'password_hash': base64.encode(bytes),
      'salt': salt,
      'role': 'OWNER',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });

    expect(await repository.authenticate('legacy', password), isNotNull);
    final stored = (await db.query(
      'users',
      where: 'id = ?',
      whereArgs: ['legacy-user'],
    )).single;
    expect(stored['password_hash'], startsWith(r'pbkdf2-sha256$v=1$i=210000$'));
    expect(stored['salt'], isNot(salt));
    expect(await repository.authenticate('legacy', password), isNotNull);
    expect(await repository.authenticate('legacy', 'wrong-password'), isNull);
  });

  test('Authenticates usernames case-insensitively', () async {
    await repository.createFirstOwner('OwnerOne', 'long-strong-password');

    expect(
      await repository.authenticate('ownerone', 'long-strong-password'),
      isNotNull,
    );
    expect(
      await repository.authenticate('OWNERONE', 'long-strong-password'),
      isNotNull,
    );
  });

  test('Changes a password and rejects the old one', () async {
    final owner = await repository.createFirstOwner(
      'owner',
      'long-strong-password',
    );

    await repository.changePassword(
      userId: owner.id,
      currentPassword: 'long-strong-password',
      newPassword: 'new-strong-password',
    );

    expect(
      await repository.authenticate('owner', 'long-strong-password'),
      isNull,
    );
    expect(
      await repository.authenticate('owner', 'new-strong-password'),
      isNotNull,
    );
  });

  test('Rejects a wrong current password and invalid roles', () async {
    final owner = await repository.createFirstOwner(
      'owner',
      'long-strong-password',
    );

    await expectLater(
      repository.changePassword(
        userId: owner.id,
        currentPassword: 'not-the-password',
        newPassword: 'new-strong-password',
      ),
      throwsException,
    );
    await expectLater(
      repository.createUser('bad-role', 'password123', 'ADMIN'),
      throwsException,
    );
  });

  test(
    'Owner can reset a cashier password and deactivate the account',
    () async {
      final owner = await repository.createFirstOwner(
        'owner',
        'long-strong-password',
      );
      await repository.createUser('cashier1', 'password123', 'CASHIER');
      final cashier = (await repository.getAllUsers()).firstWhere(
        (user) => user.username == 'cashier1',
      );

      await repository.resetPassword(
        targetUserId: cashier.id,
        newPassword: 'brand-new-password',
        actingUserId: owner.id,
      );
      expect(
        await repository.authenticate('cashier1', 'brand-new-password'),
        isNotNull,
      );

      await repository.setUserActive(
        targetUserId: cashier.id,
        active: false,
        actingUserId: owner.id,
      );
      expect(
        await repository.authenticate('cashier1', 'brand-new-password'),
        isNull,
      );

      await expectLater(
        repository.setUserActive(
          targetUserId: owner.id,
          active: false,
          actingUserId: owner.id,
        ),
        throwsException,
      );
    },
  );

  test('Owner password needs 12 chars, cashier needs 8', () async {
    // 11 chars is too short for an owner.
    await expectLater(
      repository.createUser('boss', 'elevenchars', 'OWNER'),
      throwsException,
    );
    // 13 chars is fine for an owner.
    await repository.createUser('boss', 'twelvechars12', 'OWNER');
    // 7 chars is too short for a cashier.
    await expectLater(
      repository.createUser('temp', 'sevench', 'CASHIER'),
      throwsException,
    );
    // 10 chars is fine for a cashier.
    await repository.createUser('temp', 'eightchars', 'CASHIER');
  });

  test('changePassword enforces the owner minimum', () async {
    final owner = await repository.createFirstOwner(
      'owner',
      'long-strong-password',
    );
    await expectLater(
      repository.changePassword(
        userId: owner.id,
        currentPassword: 'long-strong-password',
        newPassword: 'short12', // 7 < 12
      ),
      throwsException,
    );
  });

  test('resetPassword enforces the target user role minimum', () async {
    final owner = await repository.createFirstOwner(
      'owner',
      'long-strong-password',
    );
    await repository.createUser('cashier1', 'password123', 'CASHIER');
    final cashier = (await repository.getAllUsers()).firstWhere(
      (user) => user.username == 'cashier1',
    );
    // Cashier target only needs 8 characters.
    await repository.resetPassword(
      targetUserId: cashier.id,
      newPassword: 'neweightchars',
      actingUserId: owner.id,
    );
    // Owner target needs 12, so 8 is rejected.
    await expectLater(
      repository.resetPassword(
        targetUserId: owner.id,
        newPassword: 'tooshort',
        actingUserId: owner.id,
      ),
      throwsException,
    );
  });

  test(
    'Locks a username for the cooldown after repeated failures',
    () async {
      await repository.createFirstOwner('owner', 'long-strong-password');
      for (var i = 0; i < UserRepository.maxFailedAttempts; i++) {
        expect(await repository.authenticate('owner', 'nope'), isNull);
      }
      // The next attempt throws even with the correct password.
      await expectLater(
        repository.authenticate('owner', 'long-strong-password'),
        throwsException,
      );
    },
    // Each authenticate runs 210k PBKDF2 rounds; under full-suite CPU
    // contention this can exceed the 30s default, so give it headroom.
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'A successful login clears the failed-attempt counter',
    () async {
      await repository.createFirstOwner('owner', 'long-strong-password');
      // Four failures (one short of the lockout threshold).
      for (var i = 0; i < UserRepository.maxFailedAttempts - 1; i++) {
        await repository.authenticate('owner', 'nope');
      }
      // Success resets the counter...
      expect(
        await repository.authenticate('owner', 'long-strong-password'),
        isNotNull,
      );
      // ...so another four failures still do not lock the account.
      for (var i = 0; i < UserRepository.maxFailedAttempts - 1; i++) {
        expect(await repository.authenticate('owner', 'nope'), isNull);
      }
      expect(
        await repository.authenticate('owner', 'long-strong-password'),
        isNotNull,
      );
    },
    // Eleven 210k-round PBKDF2 derivations run here (see the lockout test
    // above); without an explicit timeout a contended suite can time this out.
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'Creates a staff account with feature permissions and reads them back',
    () async {
      await repository.createFirstOwner('owner', 'long-strong-password');
      await repository.createUser(
        'staff',
        'password123',
        'CASHIER',
        permissions: ['pos', 'reports'],
      );

      final users = await repository.getAllUsers();
      final staff = users.firstWhere((u) => u.username == 'staff');
      expect(staff.permissions, ['pos', 'reports']);
      expect(staff.can('pos'), isTrue);
      expect(staff.can('reports'), isTrue);
      expect(staff.can('users'), isFalse);

      // Owner bypasses the tick list: stores nothing, can open everything.
      final owner = users.firstWhere((u) => u.role == 'OWNER');
      expect(owner.permissions, isEmpty);
      expect(owner.can('users'), isTrue);
      expect(owner.can('audit'), isTrue);
    },
  );

  test(
    'setUserPermissions adds and removes features and rejects owners',
    () async {
      final owner = await repository.createFirstOwner(
        'owner',
        'long-strong-password',
      );
      await repository.createUser(
        'staff',
        'password123',
        'CASHIER',
        permissions: ['pos'],
      );
      final staff = (await repository.getAllUsers()).firstWhere(
        (user) => user.username == 'staff',
      );

      await repository.setUserPermissions(staff.id, [
        'pos',
        'register',
        'reports',
      ]);
      var after = await repository.getById(staff.id);
      expect(after!.permissions, ['pos', 'register', 'reports']);

      await repository.setUserPermissions(staff.id, ['pos']);
      after = await repository.getById(staff.id);
      expect(after!.permissions, ['pos']);

      // Owner rows bypass ticks — editing their permissions is rejected.
      await expectLater(
        repository.setUserPermissions(owner.id, ['pos']),
        throwsException,
      );
    },
  );

  test('createUser drops unknown feature keys', () async {
    await repository.createFirstOwner('owner', 'long-strong-password');
    await repository.createUser(
      'staff',
      'password123',
      'CASHIER',
      permissions: ['pos', 'not_a_feature'],
    );
    final staff = (await repository.getAllUsers()).firstWhere(
      (user) => user.username == 'staff',
    );
    expect(staff.permissions, ['pos']);
  });
}
