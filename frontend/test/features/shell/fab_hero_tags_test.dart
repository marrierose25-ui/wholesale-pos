import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_core/pos_core.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:wholesale_pos_app/core/theme/app_theme.dart';
import 'package:wholesale_pos_app/features/finance/finance_overview_screen.dart';
import 'package:wholesale_pos_app/features/finance/finance_person_screen.dart';
import 'package:wholesale_pos_app/features/users/user_management_screen.dart';

// The shell keeps every tab mounted at once (a single IndexedStack), so the
// FABs of all screens live in ONE route subtree. FloatingActionButton defaults
// its heroTag to a shared constant, so two mounted FABs make Hero throw
// "multiple heroes that share the same tag" as soon as any route transition
// runs -- which crashed the app when leaving Money Tracking.
//
// Each FAB therefore needs an explicit, unique tag. This test mounts the
// FAB-bearing screens together and drives a route transition, which is the
// exact situation that used to blow up.
void main() {
  late Database db;
  late User owner;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'u-owner',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'OWNER',
      'created_at': now,
    });
    await db.insert('devices', {
      'id': 'test-device',
      'name': 'Front Counter Till',
      'platform': 'Windows',
    });
    await db.insert('finance_categories', {
      'id': 'fin-cat-1',
      'name': 'Transport & Logistics Costs',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('finance_entries', {
      'id': 'fin-entry-1',
      'category_id': 'fin-cat-1',
      'source': 'ABC Shipping Company Limited',
      'amount_minor_units': 120000,
      'description': 'Monthly warehouse delivery truck rental settlement',
      'status': 'PENDING',
      'entry_date': now,
      'created_at': now,
      'created_by': 'u-owner',
      'updated_at': now,
    });
    owner = User(
      id: 'u-owner',
      username: 'owner',
      passwordHash: 'x',
      salt: 'y',
      role: 'OWNER',
    );
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('screens with a FAB keep unique hero tags when all mounted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: IndexedStack(
            index: 0,
            children: [
              FinanceOverviewScreen(
                financeRepository: SqfliteFinanceRepository(db),
                currentUser: owner,
              ),
              FinancePersonScreen(
                financeRepository: SqfliteFinanceRepository(db),
                currentUser: owner,
                categoryId: 'fin-cat-1',
                personName: 'ABC Shipping Company Limited',
              ),
              UserManagementScreen(
                userRepository: SqfliteUserRepository(db),
                currentUser: owner,
              ),
            ],
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await tester.pump(const Duration(milliseconds: 40));
      }
    });

    expect(tester.takeException(), isNull);

    final tags = tester
        .widgetList<FloatingActionButton>(
          // IndexedStack keeps the unselected tabs offstage; Hero still walks
          // them, so the invariant must be checked with offstage included.
          find.byType(FloatingActionButton, skipOffstage: false),
        )
        .map((fab) => fab.heroTag)
        .toList();
    expect(tags.length, 3, reason: 'expected three FABs mounted together');
    expect(
      tags.whereType<String>().length,
      tags.length,
      reason: 'every FAB needs an explicit heroTag',
    );
    expect(
      tags.toSet().length,
      tags.length,
      reason: 'hero tags must be unique within the IndexedStack subtree: $tags',
    );

    // Route transitions are what collect the heroes; this used to assert.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('next screen')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('next screen'), findsOneWidget);
  });
}
