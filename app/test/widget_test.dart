import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/product_repository.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/core/repositories/user_repository.dart';
import 'package:wholesale_pos_app/core/repositories/shift_repository.dart';
import 'package:wholesale_pos_app/main.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('App starts and displays activation screen without license', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      final db = await LocalDatabase.openInMemory();
      final productRepo = ProductRepository(db);
      final saleRepo = SaleRepository(db);
      final userRepo = UserRepository(db);
      final shiftRepo = ShiftRepository(db);

      await tester.pumpWidget(
        WholesalePosApp(
          db: db,
          productRepository: productRepo,
          saleRepository: saleRepo,
          userRepository: userRepo,
          shiftRepository: shiftRepo,
        ),
      );

      await Future.delayed(const Duration(milliseconds: 500));
      await tester.pump();

      // Since there is no license.key in the test environment, it must show the Activation Screen
      expect(find.text('License Activation'), findsOneWidget);
      expect(find.text('Your Device Hardware ID:'), findsOneWidget);

      await db.close();
    });
  });
}
