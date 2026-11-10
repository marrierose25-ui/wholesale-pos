import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/models/picklist.dart';
import 'package:wholesale_pos_app/core/models/picklist_customer.dart';
import 'package:wholesale_pos_app/core/models/picklist_item.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/picklist_repository.dart';
import 'package:wholesale_pos_app/core/theme/app_design.dart';
import 'package:wholesale_pos_app/core/theme/app_theme.dart';
import 'package:wholesale_pos_app/features/warehouse/new_picklist_dialog.dart';

// Dialog guard for the smallest supported phone (320x568) in BOTH themes,
// including the on-screen keyboard state that squeezed the old sale window.
// The two-step New List window is exercised end to end; any RenderFlex
// overflow or framework exception fails the test.
class _FakeRepo implements PicklistRepository {
  _FakeRepo(this.customers);

  final List<PicklistCustomer> customers;

  @override
  Future<List<PicklistCustomer>> getCustomers() async => customers;

  @override
  Future<void> addCustomer(PicklistCustomer customer) async {}

  @override
  Future<void> createPicklist(
    Picklist picklist,
    List<PicklistItem> items,
  ) async {}

  @override
  Future<List<PicklistItem>> getItems(String picklistId) async => const [];

  @override
  Future<List<Picklist>> getPicklists({String? status}) async => const [];

  @override
  Future<void> toggleItemTaken(
    String picklistId,
    String itemId,
    bool isTaken,
  ) async {}

  @override
  Future<void> updateItemQuantities(
    String picklistId,
    List<PicklistItem> updatedItems,
  ) async {}
}

void main() {
  final user = User(
    id: 'u1',
    username: 'owner',
    passwordHash: 'x',
    salt: 'y',
    role: 'OWNER',
  );

  for (final brightness in [Brightness.light, Brightness.dark]) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('New List dialog fits a 320px phone ($mode)', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      AppDesign.setMode(brightness);
      addTearDown(() => AppDesign.setMode(Brightness.dark));

      final repo = _FakeRepo([
        PicklistCustomer(
          id: 'c1',
          name: 'Abebe Kebede Wholesale Merchant',
          phone: '+251 911 111 111',
          createdAt: DateTime(2026, 11, 6),
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          theme: brightness == Brightness.dark
              ? AppTheme.dark()
              : AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showDialog<bool>(
                    context: context,
                    builder: (_) =>
                        NewPicklistDialog(repository: repo, currentUser: user),
                  ),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();

      // Step 1 - customer.
      expect(find.text('New List (1/2)'), findsOneWidget);
      await tester.tap(find.text('Select Customer'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Abebe').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'step 1 overflow ($mode)');

      // Step 2 - item detail, with the keyboard open (320px is the tightest).
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.text('New List (2/2)'), findsOneWidget);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Super Sugar 1kg Bulk Carton');
      await tester.enterText(fields.at(1), '500');
      await tester.enterText(fields.at(2), '4550');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'step 2 overflow ($mode)');

      // The primary action must stay above the keyboard on the smallest phone.
      expect(
        tester.getBottomRight(find.text('Send to Warehouse')).dy,
        lessThanOrEqualTo(568 - 260),
      );

      // A second product makes the dialog content scroll instead of overflow.
      await tester.ensureVisible(find.text('Add Product'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Product'));
      await tester.pumpAndSettle();
      expect(find.text('PRODUCT 2'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'two rows ($mode)');
    });
  }
}
