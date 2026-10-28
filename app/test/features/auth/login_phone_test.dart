import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/user_repository.dart';
import 'package:wholesale_pos_app/features/auth/login_screen.dart';

// The sign-in screen is a phone-number login: the field is labelled Phone
// Number, an empty submit asks for it, and any accepted spelling of the number
// the owner stored signs the account in.
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

  // Hashes run on a background isolate, so the widget tree has to be pumped
  // inside runAsync (real timers) until the awaited work lands.
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() done, {
    int ticks = 800,
  }) async {
    for (var i = 0; i < ticks && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  testWidgets('asks for a phone number instead of a username', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(userRepository: repository, onLoginSuccess: (_) {}),
        ),
      );
      // An empty database shows the first-owner form; the identifier field is
      // still the phone number.
      await waitFor(
        tester,
        () => find.text('Create Account').evaluate().isNotEmpty,
      );

      // The identifier field is labelled as a phone number but must still accept
      // letters: the training account signs in as `demo`.
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.decoration?.labelText, 'Phone Number');
      expect(field.keyboardType, TextInputType.text);

      await tester.tap(find.text('Create Account'));
      await tester.pump();
      expect(find.text('Please enter your phone number.'), findsOneWidget);
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('signs in with any accepted phone spelling', (tester) async {
    User? signedIn;
    await tester.runAsync(() async {
      await repository.createFirstOwner('0911111111', 'long-strong-password');
      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(
            userRepository: repository,
            onLoginSuccess: (user) => signedIn = user,
          ),
        ),
      );
      await waitFor(tester, () => find.text('Sign In').evaluate().isNotEmpty);

      await tester.enterText(find.byType(TextField).at(0), '+251 911 111 111');
      await tester.enterText(
        find.byType(TextField).at(1),
        'long-strong-password',
      );
      await tester.tap(find.text('Sign In'));
      await waitFor(tester, () => signedIn != null);
    });

    expect(signedIn, isNotNull);
    expect(signedIn!.username, '0911111111');
    expect(signedIn!.role, 'OWNER');
  });
}
