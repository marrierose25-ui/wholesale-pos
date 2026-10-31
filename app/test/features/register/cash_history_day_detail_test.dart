import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/core/repositories/shift_repository.dart';
import 'package:wholesale_pos_app/core/theme/app_design.dart';
import 'package:wholesale_pos_app/features/register/cash_history_screen.dart';
import 'package:wholesale_pos_app/features/register/register_history_screen.dart';
import 'package:wholesale_pos_app/features/sales/sale.dart';
import 'package:wholesale_pos_app/features/sales/sale_item.dart';

// Register History day drill-down: the day-grouped RegisterHistoryScreen lists
// each day (no type tabs — just search and period); tapping one opens
// RegisterDayScreen whose Sales/Credits/Debits tabs show that day's completed
// sales, deposits and withdrawals one section at a time. Runs against the real
// in-memory schema.
void main() {
  late Database db;

  final owner = User(
    id: 'u-owner',
    username: 'owner',
    passwordHash: 'x',
    salt: 'y',
    role: 'OWNER',
  );

  final day = DateTime(2026, 8, 8);

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    final stamp = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'u-owner',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'OWNER',
      'created_at': stamp,
    });
    await db.insert('devices', {
      'id': 'device-1',
      'name': 'Till 1',
      'platform': 'Windows',
    });
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'u-owner',
      'opening_cash_minor_units': 5000,
      'status': 'OPEN',
      'opened_at': stamp,
    });
    await db.insert('products', {
      'id': 'prod-1',
      'name': 'Sugar 50kg',
      'code': 'SGR50',
      'unit': 'bag',
      'selling_price_minor_units': 12000,
      'created_at': stamp,
      'updated_at': stamp,
    });

    // 8 Aug: one cash sale + one deposit + one withdrawal.
    await SaleRepository(db).saveSale(
      Sale(
        id: 'sale-aug8',
        receiptNumber: 'REC-20260808-0001',
        cashierId: 'u-owner',
        deviceId: 'device-1',
        shiftId: 'shift-1',
        paymentMethod: 'CASH',
        subtotalMinorUnits: 12000,
        discountMinorUnits: 0,
        totalMinorUnits: 12000,
        amountPaidMinorUnits: 12000,
        changeMinorUnits: 0,
        createdAt: DateTime(2026, 8, 8, 12),
        items: [
          SaleItem(
            id: 'item-aug8',
            saleId: 'sale-aug8',
            productId: 'prod-1',
            productNameSnapshot: 'Sugar 50kg',
            unitPriceSnapshotMinorUnits: 12000,
            quantityText: '1 bag',
            billingQuantityMilliunits: 1000,
            lineTotalMinorUnits: 12000,
          ),
        ],
      ),
    );
    await db.insert('cash_movements', {
      'id': 'mv-in',
      'shift_id': 'shift-1',
      'type': 'DEPOSIT',
      'amount_minor_units': 5000,
      'reason': 'Float top-up',
      'created_at': DateTime(2026, 8, 8, 10).toIso8601String(),
      'user_id': 'u-owner',
    });
    await db.insert('cash_movements', {
      'id': 'mv-out',
      'shift_id': 'shift-1',
      'type': 'WITHDRAWAL',
      'amount_minor_units': 2000,
      'reason': 'Bank drop',
      'created_at': DateTime(2026, 8, 8, 15, 30).toIso8601String(),
      'user_id': 'u-owner',
    });
    // A neighbouring day that must NOT leak into the 8 Aug drill-down.
    await db.insert('cash_movements', {
      'id': 'mv-other',
      'shift_id': 'shift-1',
      'type': 'EXPENSE',
      'amount_minor_units': 1000,
      'reason': 'Taxi fare',
      'created_at': DateTime(2026, 8, 7, 9).toIso8601String(),
      'user_id': 'u-owner',
    });
  });

  tearDown(() async {
    await db.close();
  });

  // The drill-down's sale query resolves on the REAL event loop while its
  // spinner animates, so pumpAndSettle never settles — advance real time and
  // frames together instead. The timed pumps also drive the pushed route's
  // slide-in transition to completion (a duration-less pump() never advances
  // the fake clock, which would leave the day screen stuck mid-slide).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // The ledger stays in the tree under the pushed day screen, so day-detail
  // assertions must scope to RegisterDayScreen itself.
  Finder inDay(String text) => find.descendant(
    of: find.byType(RegisterDayScreen),
    matching: find.text(text),
  );

  Finder inDayContaining(String text) => find.descendant(
    of: find.byType(RegisterDayScreen),
    matching: find.textContaining(text),
  );

  Future<void> pumpLedger(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RegisterHistoryScreen(
            shiftRepository: ShiftRepository(db),
            saleRepository: SaleRepository(db),
            currentUser: owner,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });
  }

  // Tap one of the day screen's Sales/Credits/Debits pills. Scoped to the
  // PillTabs row because the section header reuses the same words.
  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(
      find
          .descendant(of: find.byType(PillTabs), matching: find.text(label))
          .first,
    );
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  }

  testWidgets(
    'tapping a ledger day opens its tabbed sales, credits and debits',
    (tester) async {
      await pumpLedger(tester);

      // Day headers render in the friendly '8 August 2026' format, and the
      // list itself carries no All/Credits/Debits pills anymore.
      expect(find.text('8 August 2026'), findsOneWidget);
      expect(find.text('7 August 2026'), findsOneWidget);
      // Each card's number is the net drawer change, not the movement total:
      // 8 Aug = 120 cash sale + 50 credit - 20 debit = +150.00 Br (the raw
      // movement net alone would be +30.00). 7 Aug = -10.00 debit.
      expect(find.text('+150.00 Br'), findsOneWidget);
      expect(find.text('-10.00 Br'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(RegisterHistoryScreen),
          matching: find.text('Credits'),
        ),
        findsNothing,
      );

      await tester.runAsync(() async {
        await tester.tap(find.text('8 August 2026'));
        // Double settle: the pushed route's slide-in transition needs a full
        // ~300ms of real frames before the day screen sits at x=0.
        await settle(tester);
        await settle(tester);
      });

      // Sales tab (default): the day's completed sale in the shared ledger
      // format — Item/Quantity/Unit Price/Total columns like the Dashboard's
      // day drill-down ('Sales' appears twice: the pill and the section
      // header).
      expect(inDay('Sales'), findsWidgets);
      expect(inDay('Item'), findsOneWidget);
      expect(inDay('Sugar 50kg'), findsOneWidget);
      expect(inDay('1 bag'), findsOneWidget);
      // Unit price, total and the 'Cash sales' summary all carry 120.00.
      expect(inDayContaining('120.00'), findsNWidgets(3));
      expect(inDayContaining('Cash'), findsWidgets);
      expect(inDay('Float top-up'), findsNothing);
      expect(inDay('Bank drop'), findsNothing);
      // Other days' movements stay out.
      expect(inDay('Taxi fare'), findsNothing);
      // Summary: cash sales 120 + deposits 50 - withdrawals 20 = net 150.00.
      expect(inDay('Cash sales'), findsOneWidget);
      expect(inDay('Net drawer change'), findsOneWidget);
      expect(inDayContaining('150.00'), findsOneWidget);

      // Credits tab, then Debits tab — each shows only its own rows.
      await tester.runAsync(() async {
        await tapTab(tester, 'Credits');
        await settle(tester);
      });
      expect(inDay('Float top-up'), findsOneWidget);
      expect(inDay('Bank drop'), findsNothing);
      expect(inDay('Sugar 50kg'), findsNothing);

      await tester.runAsync(() async {
        await tapTab(tester, 'Debits');
        await settle(tester);
      });
      expect(inDay('Bank drop'), findsOneWidget);
      expect(inDay('Float top-up'), findsNothing);
    },
  );

  testWidgets('tapped day lists every movement type across its tabs', (
    tester,
  ) async {
    await pumpLedger(tester);

    await tester.runAsync(() async {
      await tester.tap(find.text('8 August 2026'));
      // Double settle so the route slide-in fully lands at x=0 (see above).
      await settle(tester);
      await settle(tester);
    });

    // The day detail carries the whole picture across its tabs — the deposit,
    // the withdrawal and the cash sale included.
    expect(inDay('Float top-up'), findsNothing);
    expect(inDay('Bank drop'), findsNothing);
    expect(inDay('Sugar 50kg'), findsOneWidget);

    await tester.runAsync(() async {
      await tapTab(tester, 'Credits');
      await settle(tester);
    });
    expect(inDay('Float top-up'), findsOneWidget);

    await tester.runAsync(() async {
      await tapTab(tester, 'Debits');
      await settle(tester);
    });
    expect(inDay('Bank drop'), findsOneWidget);
  });

  testWidgets('day drill-down lays out at phone width', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RegisterDayScreen(
            saleRepository: SaleRepository(db),
            day: day,
            movements: const [],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });

    expect(tester.takeException(), isNull);
    expect(find.text('8 August 2026'), findsOneWidget);
    expect(find.text('Sugar 50kg'), findsOneWidget);
  });
}
