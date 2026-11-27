import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_local_engine/pos_local_engine.dart';

import 'package:wholesale_pos_app/features/startup/unsupported_database_view.dart';

void main() {
  const error = UnsupportedDatabaseVersionException(
    foundVersion: 26,
    supportedVersion: 23,
  );

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
        const MaterialApp(
          home: UnsupportedDatabaseVersionView(error: error),
        ),
      );

  testWidgets('explains the newer-version refusal and recovery steps', (
    tester,
  ) async {
    await pump(tester);
    await tester.pumpAndSettle();

    expect(
      find.text('This database belongs to a newer version of Wholesale POS'),
      findsOneWidget,
    );
    expect(find.textContaining('schema v26'), findsWidgets);
    expect(find.textContaining('up to schema v23'), findsOneWidget);
    expect(find.textContaining('nothing was changed or deleted'), findsOneWidget);
    expect(find.textContaining('Install the newer version'), findsOneWidget);
    expect(find.textContaining('Do NOT uninstall'), findsOneWidget);
    expect(find.textContaining('Detected schema: v26'), findsOneWidget);
    expect(find.textContaining('Supported: v23'), findsOneWidget);
  });

  testWidgets('does not offer retry, delete or restore actions', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsNothing);
    expect(find.textContaining('Delete'), findsNothing);
    expect(find.textContaining('Restore'), findsNothing);
  });
}
