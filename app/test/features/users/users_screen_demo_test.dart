import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/user_repository.dart';
import 'package:wholesale_pos_app/features/users/user_management_screen.dart';

// The Users screen must advertise the permanent training account with a Demo
// chip and must not offer to deactivate it, while an ordinary staff row keeps
// that action. The repository still throws if the menu is bypassed.
void main() {
  late Database db;
  late UserRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = UserRepository(db);
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

      // Close the menu and confirm an ordinary staff row still offers it.
      await tester.tapAt(const Offset(4, 4));
      await pumpFrames(3);
      await tester.tap(menuOf('alice'));
      await pumpFrames(3);
      expect(find.text('Deactivate'), findsOneWidget);
    });

    expect(tester.takeException(), isNull);
  });
}
