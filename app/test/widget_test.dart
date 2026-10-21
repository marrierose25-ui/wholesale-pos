import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/features/licensing/activation_screen.dart';

void main() {
  testWidgets('Activation screen displays license recovery guidance', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ActivationScreen(
          onActivated: _noop,
          errorMessage: 'license.key not found.',
          hardwareIdProvider: _testHardwareId,
        ),
      ),
    );

    expect(find.text('License Activation'), findsOneWidget);
    expect(find.text('Your Device Hardware ID:'), findsOneWidget);
    expect(find.text('license.key not found.'), findsOneWidget);
    expect(find.text('Retry Activation'), findsOneWidget);
  });
}

void _noop() {}

Future<String> _testHardwareId() async => 'test-device';
