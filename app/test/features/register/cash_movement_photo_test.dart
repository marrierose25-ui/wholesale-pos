import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/core/repositories/shift_repository.dart';
import 'package:wholesale_pos_app/core/theme/app_design.dart';
import 'package:wholesale_pos_app/features/register/cash_history_screen.dart';
import 'package:wholesale_pos_app/features/sales/shift.dart';

// Optional proof photos on register cash movements (mainly debits: "upload
// proof the cash left the drawer"). Covers the storage round-trip through the
// repository and the ledger UI: a camera badge on rows that carry a proof,
// tapping it opens the full-screen viewer.
void main() {
  late Database db;

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
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'u-owner',
      'opening_cash_minor_units': 0,
      'status': 'OPEN',
      'opened_at': stamp,
    });
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'a movement stores its optional proof photo and reads it back',
    () async {
      final shift = await ShiftRepository(db).ensureActiveShift('u-owner');
      await ShiftRepository(db).addCashMovement(
        shift.id,
        'WITHDRAWAL',
        20000,
        'Bank drop',
        userId: 'u-owner',
        photo: base64Encode(utf8.encode('proof-bytes')),
      );
      // A movement without a photo stays null — the column is optional.
      await ShiftRepository(db).addCashMovement(
        shift.id,
        'DEPOSIT',
        5000,
        'Float top-up',
        userId: 'u-owner',
      );

      final movements = await ShiftRepository(db).getCashMovements();
      final byReason = {for (final m in movements) m.reason: m};
      expect(
        byReason['Bank drop']!.photo,
        base64Encode(utf8.encode('proof-bytes')),
      );
      expect(byReason['Float top-up']!.photo, isNull);

      // The model round-trips the field through its map form too.
      final row = (await db.query(
        'cash_movements',
        where: 'id = ?',
        whereArgs: [movements.first.id],
      )).first;
      expect(CashMovement.fromMap(row).photo, movements.first.photo);
    },
  );

  // A valid 1x1 PNG. The badge is driven purely by the photo being non-null,
  // so the row renders it without ever decoding (only the full-screen viewer,
  // opened on tap, decodes — and that path isn't pumped here).
  const photoBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8'
      'BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

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

  CashMovement mv({
    required String id,
    required String type,
    required int amount,
    required String reason,
    String? photo,
  }) => CashMovement(
    id: id,
    shiftId: 'shift-1',
    type: type,
    amountMinorUnits: amount,
    reason: reason,
    createdAt: DateTime(2026, 8, 8, 10),
    photo: photo,
  );

  // The day drill-down renders _MovementRow for every passed movement, so it
  // exercises the photo badge without the repo/outbox/sync path (the pattern
  // the day-detail test proves is hang-free).
  Widget dayHost(List<CashMovement> movements) => MaterialApp(
    home: RegisterDayScreen(
      saleRepository: SaleRepository(db),
      day: DateTime(2026, 8, 8),
      movements: movements,
    ),
  );

  testWidgets('a camera badge shows only on movements with a proof', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        dayHost([
          mv(
            id: 'm1',
            type: 'WITHDRAWAL',
            amount: 20000,
            reason: 'Bank drop',
            photo: photoBase64,
          ),
          mv(id: 'm2', type: 'DEPOSIT', amount: 5000, reason: 'Float top-up'),
        ]),
      );
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }

      // Debits tab: only the photo-carrying withdrawal, with its badge.
      await tapTab(tester, 'Debits');
      expect(find.text('Bank drop'), findsOneWidget);
      expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);

      // Credits tab: the deposit row carries no badge.
      await tapTab(tester, 'Credits');
      expect(find.text('Float top-up'), findsOneWidget);
      expect(find.byIcon(Icons.photo_camera_outlined), findsNothing);
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('a proof badge lays out at phone width without overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        dayHost([
          mv(
            id: 'm1',
            type: 'WITHDRAWAL',
            amount: 20000,
            reason: 'Long withdrawal reason that must ellipsize on a narrow phone screen',
            photo: photoBase64,
          ),
        ]),
      );
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
      await tapTab(tester, 'Debits');
      expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('touching a movement row with a proof opens the viewer', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        dayHost([
          mv(
            id: 'm1',
            type: 'WITHDRAWAL',
            amount: 20000,
            reason: 'Bank drop',
            photo: photoBase64,
          ),
        ]),
      );
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
      await tapTab(tester, 'Debits');

      // Tap the transaction itself (not just the tiny badge) to open proof.
      await tester.tap(find.text('Bank drop'));
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
      expect(find.byType(Dialog), findsOneWidget);
    });

    expect(tester.takeException(), isNull);
  });
}
