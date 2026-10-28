import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/features/dashboard/sales_by_day_screen.dart';
import 'package:wholesale_pos_app/features/sales/sale.dart';
import 'package:wholesale_pos_app/features/sales/sale_item.dart';

// The unified Sales History groups every sale by calendar day (newest first);
// tapping a day reveals that day's sales. The default "All" tab includes
// voided sales, but a day's money figure counts only completed cash + bank, so
// voided rows show without inflating the total. Kept at real phone width
// (390x844) so overflow regressions surface.
void main() {
  late Database db;
  late SaleRepository repo;

  final owner = User(
    id: 'user-1',
    username: 'owner',
    passwordHash: 'x',
    salt: 'x',
    role: 'OWNER',
  );

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'user-1',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'x',
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
      'cashier_id': 'user-1',
      'opening_cash_minor_units': 0,
      'status': 'OPEN',
      'opened_at': now,
    });
    repo = SaleRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Sale buildSale(String id, DateTime at) {
    return Sale(
      id: id,
      receiptNumber: 'REC-$id',
      cashierId: 'user-1',
      deviceId: 'device-1',
      shiftId: 'shift-1',
      subtotalMinorUnits: 5000,
      discountMinorUnits: 0,
      totalMinorUnits: 5000,
      amountPaidMinorUnits: 5000,
      changeMinorUnits: 0,
      createdAt: at,
      items: [
        SaleItem(
          id: 'item-$id',
          saleId: id,
          productId: 'prod-1',
          productNameSnapshot: 'Sugar-$id',
          unitPriceSnapshotMinorUnits: 5000,
          quantityText: '1',
          billingQuantityMilliunits: 1000,
          lineTotalMinorUnits: 5000,
        ),
      ],
    );
  }

  testWidgets('sales group by day; a voided sale lists but adds no money', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 12);
    final yesterday = today.subtract(const Duration(days: 1));

    await tester.runAsync(() async {
      await repo.saveSale(buildSale('t1', today));
      await repo.saveSale(buildSale('y1', yesterday));
      await repo.saveSale(
        buildSale('y2', yesterday.add(const Duration(hours: 1))),
      );
      // A voided sale on yesterday: listed under All, but excluded from money.
      await repo.saveSale(
        buildSale('v1', yesterday.subtract(const Duration(hours: 2))),
      );
      await repo.voidSale('v1', 'user-1', 'mistake');

      await tester.pumpWidget(
        MaterialApp(
          home: SalesByDayScreen(saleRepository: repo, currentUser: owner),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await tester.pump(const Duration(milliseconds: 40));
      }

      // Day headings newest-first. Yesterday lists all 3 sales but its money
      // total is the 2 completed cash sales only (Br 100.00, not 150.00).
      expect(find.text(SalesByDayScreen.formatDay(today)), findsOneWidget);
      expect(find.text('Today · 1 sale'), findsOneWidget);
      expect(find.text(SalesByDayScreen.formatDay(yesterday)), findsOneWidget);
      expect(find.text('Yesterday · 3 sales'), findsOneWidget);
      expect(find.text('100.00 Br'), findsOneWidget);
      expect(find.text('150.00 Br'), findsNothing);
      expect(tester.takeException(), isNull);

      // Tap yesterday -> all three sales as a compact ledger, newest first;
      // the voided one is present (All tab) yet the collected total stays
      // at 100.00.
      await tester.tap(find.text(SalesByDayScreen.formatDay(yesterday)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('3 sales'), findsOneWidget);
      expect(find.text('Sugar-y2'), findsOneWidget);
      expect(find.text('Sugar-y1'), findsOneWidget);
      expect(find.text('Sugar-v1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('an empty history shows the placeholder', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: SalesByDayScreen(saleRepository: repo, currentUser: owner),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(find.text('No sales recorded yet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
