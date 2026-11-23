// Every login here derives a 210k-round PBKDF2 key on purpose, and several of
// these tests derive a dozen of them. Under a full-suite run the default 30s
// per-test budget is a coin toss, so the whole file gets headroom rather than
// the few tests that happened to time out first.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late UserRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = SqfliteUserRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('Sets up a first owner with a secure password', () async {
    await repository.createFirstOwner('0911111111', 'long-strong-password');

    final user = await repository.authenticate(
      '0911111111',
      'long-strong-password',
    );

    expect(user, isNotNull);
    expect(user!.username, '0911111111');
    expect(user.role, 'OWNER');
  });

  test('Rejects a wrong owner password and repeat setup', () async {
    await repository.createFirstOwner('0911111111', 'long-strong-password');

    final user = await repository.authenticate('0911111111', 'wrongpass');

    expect(user, isNull);
    await expectLater(
      repository.createFirstOwner('0922222222', 'long-strong-password'),
      throwsException,
    );
  });

  test('Creates a new cashier and lists all users', () async {
    await repository.createFirstOwner('0911111111', 'long-strong-password');
    await repository.createUser('0933333333', 'password123', 'CASHIER');

    final users = await repository.getAllUsers();

    expect(users.length, 2); // Owner + Cashier
    expect(users.any((u) => u.username == '0933333333'), isTrue);

    final newUser = await repository.authenticate('0933333333', 'password123');
    expect(newUser, isNotNull);
    expect(newUser!.role, 'CASHIER');
  });

  // A pre-phone-login account keeps its text identifier: sign-in passes an
  // unrecognised value through untouched, so `legacy` still resolves.
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

  test('Accepts any phone spelling a cashier might type', () async {
    await repository.createFirstOwner('0911111111', 'long-strong-password');

    for (final spelling in [
      '+251911111111',
      '251911111111',
      '911111111',
      '0911 111 111',
    ]) {
      expect(
        await repository.authenticate(spelling, 'long-strong-password'),
        isNotNull,
        reason: 'login should accept $spelling',
      );
    }
  });

  test('Changes a password and rejects the old one', () async {
    final owner = await repository.createFirstOwner(
      '0911111111',
      'long-strong-password',
    );

    await repository.changePassword(
      userId: owner.id,
      currentPassword: 'long-strong-password',
      newPassword: 'new-strong-password',
    );

    expect(
      await repository.authenticate('0911111111', 'long-strong-password'),
      isNull,
    );
    expect(
      await repository.authenticate('0911111111', 'new-strong-password'),
      isNotNull,
    );
  });

  test('Rejects a wrong current password and invalid roles', () async {
    final owner = await repository.createFirstOwner(
      '0911111111',
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
      repository.createUser('0955555555', 'password123', 'ADMIN'),
      throwsException,
    );
  });

  test(
    'Owner can reset a cashier password and deactivate the account',
    () async {
      final owner = await repository.createFirstOwner(
        '0911111111',
        'long-strong-password',
      );
      await repository.createUser('0933333333', 'password123', 'CASHIER');
      final cashier = (await repository.getAllUsers()).firstWhere(
        (user) => user.username == '0933333333',
      );

      await repository.resetPassword(
        targetUserId: cashier.id,
        newPassword: 'brand-new-password',
        actingUserId: owner.id,
      );
      expect(
        await repository.authenticate('0933333333', 'brand-new-password'),
        isNotNull,
      );

      await repository.setUserActive(
        targetUserId: cashier.id,
        active: false,
        actingUserId: owner.id,
      );
      expect(
        await repository.authenticate('0933333333', 'brand-new-password'),
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
      repository.createUser('0966666666', 'elevenchars', 'OWNER'),
      throwsException,
    );
    // 13 chars is fine for an owner.
    await repository.createUser('0966666666', 'twelvechars12', 'OWNER');
    // 7 chars is too short for a cashier.
    await expectLater(
      repository.createUser('0977777777', 'sevench', 'CASHIER'),
      throwsException,
    );
    // 10 chars is fine for a cashier.
    await repository.createUser('0977777777', 'eightchars', 'CASHIER');
  });

  test('changePassword enforces the owner minimum', () async {
    final owner = await repository.createFirstOwner(
      '0911111111',
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
      '0911111111',
      'long-strong-password',
    );
    await repository.createUser('0933333333', 'password123', 'CASHIER');
    final cashier = (await repository.getAllUsers()).firstWhere(
      (user) => user.username == '0933333333',
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
      await repository.createFirstOwner('0911111111', 'long-strong-password');
      for (var i = 0; i < UserRepository.maxFailedAttempts; i++) {
        expect(await repository.authenticate('0911111111', 'nope'), isNull);
      }
      // The next attempt throws even with the correct password.
      await expectLater(
        repository.authenticate('0911111111', 'long-strong-password'),
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
      await repository.createFirstOwner('0911111111', 'long-strong-password');
      // Four failures (one short of the lockout threshold).
      for (var i = 0; i < UserRepository.maxFailedAttempts - 1; i++) {
        await repository.authenticate('0911111111', 'nope');
      }
      // Success resets the counter...
      expect(
        await repository.authenticate('0911111111', 'long-strong-password'),
        isNotNull,
      );
      // ...so another four failures still do not lock the account.
      for (var i = 0; i < UserRepository.maxFailedAttempts - 1; i++) {
        expect(await repository.authenticate('0911111111', 'nope'), isNull);
      }
      expect(
        await repository.authenticate('0911111111', 'long-strong-password'),
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
      await repository.createFirstOwner('0911111111', 'long-strong-password');
      await repository.createUser(
        '0988888888',
        'password123',
        'CASHIER',
        permissions: ['pos', 'reports'],
      );

      final users = await repository.getAllUsers();
      final staff = users.firstWhere((u) => u.username == '0988888888');
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
        '0911111111',
        'long-strong-password',
      );
      await repository.createUser(
        '0988888888',
        'password123',
        'CASHIER',
        permissions: ['pos'],
      );
      final staff = (await repository.getAllUsers()).firstWhere(
        (user) => user.username == '0988888888',
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
    await repository.createFirstOwner('0911111111', 'long-strong-password');
    await repository.createUser(
      '0988888888',
      'password123',
      'CASHIER',
      permissions: ['pos', 'not_a_feature'],
    );
    final staff = (await repository.getAllUsers()).firstWhere(
      (user) => user.username == '0988888888',
    );
    expect(staff.permissions, ['pos']);
  });

  test('Accounts are identified by a canonical phone number', () async {
    await repository.createFirstOwner(
      '+251 911 111 111',
      'long-strong-password',
    );
    final owner = (await repository.getAllUsers()).single;
    expect(owner.username, '0911111111');
    expect(
      await repository.authenticate('0911111111', 'long-strong-password'),
      isNotNull,
    );

    // A name is no longer a valid identifier for a new account.
    await expectLater(
      repository.createUser('cashier1', 'password123', 'CASHIER'),
      throwsA(predicate((e) => e.toString().contains('valid phone number'))),
    );

    // Any accepted spelling is stored in the canonical form.
    await repository.createUser('251922222222', 'password123', 'CASHIER');
    final cashier = (await repository.getAllUsers()).firstWhere(
      (user) => user.role == 'CASHIER',
    );
    expect(cashier.username, '0922222222');
  });

  test('setUserPhone renames the login and retires the old number', () async {
    final owner = await repository.createFirstOwner(
      '0911111111',
      'long-strong-password',
    );
    await repository.createUser('0922222222', 'password123', 'CASHIER');
    final cashier = (await repository.getAllUsers()).firstWhere(
      (user) => user.username == '0922222222',
    );

    await repository.setUserPhone(
      userId: cashier.id,
      phone: '+251 933 333 333',
      actingUserId: owner.id,
    );

    final renamed = await repository.getById(cashier.id);
    expect(renamed!.username, '0933333333');
    expect(
      await repository.authenticate('0933333333', 'password123'),
      isNotNull,
    );
    expect(await repository.authenticate('0922222222', 'password123'), isNull);
  });

  test(
    'setUserPhone rejects duplicates, non-owners and the demo account',
    () async {
      final owner = await repository.createFirstOwner(
        '0911111111',
        'long-strong-password',
      );
      await repository.createUser('0922222222', 'password123', 'CASHIER');
      await repository.createUser('0933333333', 'password123', 'CASHIER');
      final users = await repository.getAllUsers();
      final cashier = users.firstWhere((u) => u.username == '0922222222');
      final other = users.firstWhere((u) => u.username == '0933333333');

      // A number already used by another account cannot be reused.
      await expectLater(
        repository.setUserPhone(
          userId: cashier.id,
          phone: '0933333333',
          actingUserId: owner.id,
        ),
        throwsA(predicate((e) => e.toString().contains('already in use'))),
      );
      // Only an active owner may rename a login.
      await expectLater(
        repository.setUserPhone(
          userId: other.id,
          phone: '0944444444',
          actingUserId: cashier.id,
        ),
        throwsA(predicate((e) => e.toString().contains('active owner'))),
      );
      // The demo login keeps the name `demo`.
      await repository.ensureDemoUser();
      final demo = (await repository.getAllUsers()).firstWhere((u) => u.isDemo);
      await expectLater(
        repository.setUserPhone(
          userId: demo.id,
          phone: '0955555555',
          actingUserId: owner.id,
        ),
        throwsA(predicate((e) => e.toString().contains('demo login'))),
      );
    },
  );

  test('Deleting a disabled account frees its phone number', () async {
    final owner = await repository.createFirstOwner(
      '0911111111',
      'long-strong-password',
    );
    await repository.createUser('0922222222', 'password123', 'CASHIER');
    final cashier = (await repository.getAllUsers()).firstWhere(
      (user) => user.username == '0922222222',
    );
    await repository.setUserActive(
      targetUserId: cashier.id,
      active: false,
      actingUserId: owner.id,
    );

    await repository.deleteUser(
      targetUserId: cashier.id,
      actingUserId: owner.id,
    );

    expect((await repository.getAllUsers()).length, 1);
    expect(await repository.getById(cashier.id), isNull);
    expect(await repository.authenticate('0922222222', 'password123'), isNull);
    // Nothing was recorded against the account, so the row is gone and the
    // number is free again.
    await repository.createUser('0922222222', 'password123', 'CASHIER');
    expect(
      await repository.authenticate('0922222222', 'password123'),
      isNotNull,
    );
  });

  test('Deleting an account with history keeps its sale attribution', () async {
    final owner = await repository.createFirstOwner(
      '0911111111',
      'long-strong-password',
    );
    await repository.createUser('0922222222', 'password123', 'CASHIER');
    final cashier = (await repository.getAllUsers()).firstWhere(
      (user) => user.username == '0922222222',
    );
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': cashier.id,
      'opening_cash_minor_units': 0,
      'status': 'CLOSED',
      'opened_at': DateTime.now().toIso8601String(),
    });
    await repository.setUserActive(
      targetUserId: cashier.id,
      active: false,
      actingUserId: owner.id,
    );

    await repository.deleteUser(
      targetUserId: cashier.id,
      actingUserId: owner.id,
    );

    expect((await repository.getAllUsers()).length, 1);
    final kept = await db.query(
      'users',
      columns: ['deleted_at'],
      where: 'id = ?',
      whereArgs: [cashier.id],
    );
    expect(kept.single['deleted_at'], isNotNull);
    // Re-adding the same number reuses the row, so the shift keeps pointing at
    // a named cashier instead of a dangling id.
    await repository.createUser('0922222222', 'password123', 'CASHIER');
    final rehired = (await repository.getAllUsers()).firstWhere(
      (user) => user.username == '0922222222',
    );
    expect(rehired.id, cashier.id);
    expect(
      await repository.authenticate('0922222222', 'password123'),
      isNotNull,
    );
  });

  test('Deleting refuses active, demo and self accounts', () async {
    final owner = await repository.createFirstOwner(
      '0911111111',
      'long-strong-password',
    );
    await repository.createUser('0922222222', 'password123', 'CASHIER');
    await repository.ensureDemoUser();
    final users = await repository.getAllUsers();
    final cashier = users.firstWhere((u) => u.username == '0922222222');
    final demo = users.firstWhere((u) => u.isDemo);

    await expectLater(
      repository.deleteUser(targetUserId: cashier.id, actingUserId: owner.id),
      throwsA(predicate((e) => e.toString().contains('Deactivate'))),
    );
    // The demo account is refused even though it is still active, so its
    // stable training login can never be deleted.
    await expectLater(
      repository.deleteUser(targetUserId: demo.id, actingUserId: owner.id),
      throwsA(predicate((e) => e.toString().contains('demo'))),
    );
    await expectLater(
      repository.deleteUser(targetUserId: owner.id, actingUserId: owner.id),
      throwsA(predicate((e) => e.toString().contains('your own account'))),
    );
    // Only an active owner may delete.
    await expectLater(
      repository.deleteUser(targetUserId: owner.id, actingUserId: cashier.id),
      throwsA(predicate((e) => e.toString().contains('active owner'))),
    );
  });

  test('A lockout survives a restart', () async {
    await repository.createFirstOwner('0911111111', 'long-strong-password');
    for (var i = 0; i < UserRepository.maxFailedAttempts; i++) {
      await repository.authenticate('0911111111', 'nope');
    }

    final guards = await db.query(
      'settings',
      where: "key LIKE 'login_guard:%'",
    );
    expect(guards, hasLength(1));

    // A second repository on the same file stands in for a relaunch: the
    // in-memory map is empty, and only the persisted row can hold the lock.
    final relaunched = SqfliteUserRepository(db);
    await expectLater(
      relaunched.authenticate('0911111111', 'long-strong-password'),
      throwsA(predicate((e) => e.toString().contains('Too many failed'))),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('A successful login deletes the persisted counter', () async {
    await repository.createFirstOwner('0911111111', 'long-strong-password');
    await repository.authenticate('0911111111', 'nope');
    expect(
      await db.query('settings', where: "key LIKE 'login_guard:%'"),
      hasLength(1),
    );

    expect(
      await repository.authenticate('0911111111', 'long-strong-password'),
      isNotNull,
    );

    expect(
      await db.query('settings', where: "key LIKE 'login_guard:%'"),
      isEmpty,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('Every mutating account method writes an audit row', () async {
    final owner = await repository.createFirstOwner(
      '0911111111',
      'long-strong-password',
    );
    await repository.createUser('0933333333', 'password123', 'CASHIER');
    final cashier = (await repository.authenticate(
      '0933333333',
      'password123',
    ))!;

    await repository.changePassword(
      userId: cashier.id,
      currentPassword: 'password123',
      newPassword: 'password456',
    );
    await repository.setUserPhone(
      userId: cashier.id,
      phone: '0944444444',
      actingUserId: owner.id,
    );
    await repository.resetPassword(
      targetUserId: cashier.id,
      newPassword: 'password789',
      actingUserId: owner.id,
    );
    await repository.setUserActive(
      targetUserId: cashier.id,
      active: false,
      actingUserId: owner.id,
    );
    await repository.deleteUser(
      targetUserId: cashier.id,
      actingUserId: owner.id,
    );

    // The Audit Log screen reads this table, so a change that does not land
    // here never appears on it.
    final rows = await db.query('audit_logs', columns: ['action']);
    final actions = rows.map((r) => r['action'] as String).toSet();
    expect(
      actions,
      containsAll(<String>[
        'PASSWORD_CHANGED',
        'USER_PHONE_CHANGED',
        'PASSWORD_RESET',
        'USER_DEACTIVATED',
        'USER_DELETED',
      ]),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
