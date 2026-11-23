import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:wholesale_pos_app/features/users/user_management_screen.dart';

// The Users screen must advertise the permanent training account with a Demo
// chip and must not offer to deactivate it, while an ordinary staff row keeps
// that action. The repository still throws if the menu is bypassed.
void main() {
  late Database db;
  late UserRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = SqfliteUserRepository(db);
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'owner-1',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'OWNER',
      'is_active': 1,
      'created_at': now,
    });
    await db.insert('users', {
      'id': 'cashier-1',
      'username': 'alice',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'CASHIER',
      'is_active': 1,
      'created_at': now,
    });
    await repository.ensureDemoUser();
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('demo row shows the Demo chip and hides Deactivate', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final owner = User(
      id: 'owner-1',
      username: 'owner',
      passwordHash: 'x',
      salt: 'y',
      role: 'OWNER',
    );

    Future<void> pumpFrames([int n = 10]) async {
      for (var i = 0; i < n; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await tester.pump(const Duration(milliseconds: 40));
      }
    }

    Finder menuOf(String username) => find.descendant(
      of: find.ancestor(
        of: find.text(username),
        matching: find.byType(ListTile),
      ),
      matching: find.byType(PopupMenuButton<String>),
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: UserManagementScreen(
            userRepository: repository,
            currentUser: owner,
          ),
        ),
      );
      await pumpFrames();

      // The demo row is labelled...
      expect(find.text('demo'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'Demo'), findsOneWidget);

      // ...and its menu keeps Reset Password / Permissions but has no
      // Deactivate item.
      await tester.tap(menuOf('demo'));
      await pumpFrames(3);
      expect(find.text('Reset Password'), findsOneWidget);
      expect(find.text('Permissions'), findsOneWidget);
      expect(find.text('Deactivate'), findsNothing);
      // The demo login is pinned, so it cannot be moved to a phone number.
      expect(find.text('Edit phone'), findsNothing);

      // Close the menu and confirm an ordinary staff row still offers both.
      await tester.tapAt(const Offset(4, 4));
      await pumpFrames(3);
      await tester.tap(menuOf('alice'));
      await pumpFrames(3);
      expect(find.text('Deactivate'), findsOneWidget);
      expect(find.text('Edit phone'), findsOneWidget);
      // Deleting is only offered once the account is disabled.
      expect(find.text('Delete Account'), findsNothing);

      // Edit phone opens the rename dialog prefilled with the current value.
      await tester.tap(find.text('Edit phone'));
      await pumpFrames(3);
      expect(find.text('Change Phone Number'), findsOneWidget);
      expect(
        find.text('This is the number the account signs in with.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await pumpFrames(12);
      expect(find.text('Change Phone Number'), findsNothing);
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('a disabled account can be deleted from its menu', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = _DeletingUsers([
      User(
        id: 'owner-1',
        username: 'owner',
        passwordHash: 'x',
        salt: 'y',
        role: 'OWNER',
      ),
      User(
        id: 'cashier-1',
        username: 'alice',
        passwordHash: 'x',
        salt: 'y',
        role: 'CASHIER',
      ),
      User(
        id: 'cashier-2',
        username: 'bob',
        passwordHash: 'x',
        salt: 'y',
        role: 'CASHIER',
        isActive: false,
      ),
    ]);

    Finder menuOf(String username) => find.descendant(
      of: find.ancestor(
        of: find.text(username),
        matching: find.byType(ListTile),
      ),
      matching: find.byType(PopupMenuButton<String>),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: UserManagementScreen(
          userRepository: repo,
          currentUser: repo.users.first,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(menuOf('bob'));
    await tester.pumpAndSettle();
    expect(find.text('Activate'), findsOneWidget);
    await tester.tap(find.text('Delete Account'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Account?'), findsOneWidget);
    expect(find.textContaining('can no longer sign in'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(repo.deletes, 1);
    expect(repo.deletedId, 'cashier-2');
    expect(find.text('bob'), findsNothing);
    expect(find.text('alice'), findsOneWidget);
  });
}

/// Records the delete the menu triggers. The real guards (owner-only,
/// deactivated-only, history retention) live in the repository and are
/// covered by user_repository_test.dart.
class _DeletingUsers implements UserRepository {
  _DeletingUsers(this.users);

  final List<User> users;
  int deletes = 0;
  String? deletedId;

  @override
  Future<List<User>> getAllUsers() async => List.of(users);

  @override
  Future<void> deleteUser({
    required String targetUserId,
    required String actingUserId,
  }) async {
    deletes++;
    deletedId = targetUserId;
    users.removeWhere((user) => user.id == targetUserId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('delete flow uses only getAllUsers/deleteUser');
}
