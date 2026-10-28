import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/features/dashboard/sales_by_day_screen.dart';
import 'package:wholesale_pos_app/features/sales/sale.dart';
import 'package:wholesale_pos_app/features/sales/sale_item.dart';

// The unified Sales History lists a loan sale (it is a recorded sale) but that
// day's money figure counts only completed cash + bank, so the total ties to
// the Dashboard revenue KPI. Drilling into the day reveals the loan row itself.
void main() {
  late Database db;
  late SaleRepository repo;

  final owner = User(
    id: 'u-1',
    username: 'owner',
    passwordHash: 'x',
    salt: 'y',
    role: 'OWNER',
  );

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repo = SaleRepository(db);
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'u-1',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'OWNER',
      'created_at': now,
    });
    await db.insert('devices', {
      'id': 'device-1',
      'name': 'PC',
      'platform': 'Windows',
    });
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'u-1',
      'opening_cash_minor_units': 0,
      'status': 'OPEN',
      'opened_at': now,
    });
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedSale({
    required String id,
    required int totalMinorUnits,
    required String paymentMethod,
    required String product,
  }) async {
    await repo.saveSale(
      Sale(
        id: id,
        receiptNumber: 'REC-$id',
        cashierId: 'u-1',
        deviceId: 'device-1',
        shiftId: 'shift-1',
        paymentMethod: paymentMethod,
        subtotalMinorUnits: totalMinorUnits,
        discountMinorUnits: 0,
        totalMinorUnits: totalMinorUnits,
        amountPaidMinorUnits: totalMinorUnits,
        changeMinorUnits: 0,
        createdAt: DateTime.now(),
        items: [
          SaleItem(
            id: 'item-$id',
            saleId: id,
            productId: 'MANUAL',
            productNameSnapshot: product,
            unitPriceSnapshotMinorUnits: totalMinorUnits,
            quantityText: '1',
            billingQuantityMilliunits: 1000,
            lineTotalMinorUnits: totalMinorUnits,
          ),
        ],
      ),
    );
  }

  testWidgets('a loan sale lists but adds nothing to the day money total', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final today = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
      12,
    );

    await tester.runAsync(() async {
      await seedSale(
        id: 'cash-1',
        totalMinorUnits: 10000,
        paymentMethod: 'CASH',
        product: 'Sugar',
      );
      await seedSale(
        id: 'loan-1',
        totalMinorUnits: 5000,
        paymentMethod: 'LOAN',
        product: 'Flour',
      );

      // Both are recorded and retrievable as completed sales.
      expect(await repo.getSales(status: 'COMPLETED'), hasLength(2));

      await tester.pumpWidget(
        MaterialApp(
          home: SalesByDayScreen(saleRepository: repo, currentUser: owner),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }

      // Day card counts both sales but its money figure is the cash takings
      // only (Br 100.00), never the loan-inflated Br 150.00.
      expect(find.text('Today · 2 sales'), findsOneWidget);
      expect(find.text('100.00 Br'), findsOneWidget);
      expect(find.text('150.00 Br'), findsNothing);

      // Drill into the day -> the loan row is present, header stays collected.
      await tester.tap(find.text(SalesByDayScreen.formatDay(today)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('2 sales'), findsWidgets);
      expect(find.text('Flour'), findsOneWidget);
      expect(find.text('Sugar'), findsOneWidget);
    });

    expect(tester.takeException(), isNull);
  });
}
