import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/features/licensing/activation_screen.dart';

// The mobile activation screen (code-entry) must fit a real phone width. Its
// card was previously a fixed 500px wide, which overflows at 390px; this guard
// keeps it responsive and asserts the entry UI renders without overflow.
void main() {
  testWidgets('Activation code entry lays out at phone width', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: ActivationScreen(
          onActivated: () {},
          hardwareIdProvider: () async => 'test-device-id',
          onActivateWithCode: (_) async => null,
          showCodeEntry: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Enter your license code:'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Activate'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
