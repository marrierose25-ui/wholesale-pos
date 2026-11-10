import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/auth/features.dart';
import 'package:wholesale_pos_app/core/models/picklist.dart';
import 'package:wholesale_pos_app/core/models/picklist_customer.dart';
import 'package:wholesale_pos_app/core/models/picklist_item.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/picklist_repository.dart';
import 'package:wholesale_pos_app/core/theme/app_theme.dart';
import 'package:wholesale_pos_app/features/warehouse/picklist_detail_screen.dart';
import 'package:wholesale_pos_app/features/warehouse/warehouse_history_screen.dart';
import 'package:wholesale_pos_app/features/warehouse/warehouse_screen.dart';

// Layout and behaviour guard for the redesigned Warehouse flow: the shop
// worker's New List form, the warehouse worker's tick-box fill screen, the
// permission split between "new" and "to fill", and the date -> customer ->
// taken history drill-down. Renders at a real phone width and a desktop width
// and fails on any RenderFlex overflow.
class _FakeRepo implements PicklistRepository {
  _FakeRepo({
    this.customers = const [],
    this.picklists = const [],
    this.items = const [],
  });

  final List<PicklistCustomer> customers;
  final List<Picklist> picklists;
  List<PicklistItem> items;
  bool toggled = false;
  Picklist? createdHeader;
  List<PicklistItem>? createdItems;

  @override
  Future<List<PicklistCustomer>> getCustomers() async => customers;

  @override
  Future<List<PicklistItem>> getItems(String picklistId) async => items;

  @override
  Future<List<Picklist>> getPicklists({String? status}) async => picklists;

  @override
  Future<void> addCustomer(PicklistCustomer customer) async {}

  @override
  Future<void> createPicklist(
    Picklist picklist,
    List<PicklistItem> items,
  ) async {
    createdHeader = picklist;
    createdItems = items;
    this.items = items;
  }

  @override
  Future<void> updateItemQuantities(
    String picklistId,
    List<PicklistItem> updatedItems,
  ) async {}

  @override
  Future<void> toggleItemTaken(
    String picklistId,
    String itemId,
    bool isTaken,
  ) async {
    toggled = true;
    items = [
      for (final i in items)
        if (i.id == itemId)
          i.copyWith(takenQty: isTaken ? i.requestedQty : 0)
        else
          i,
    ];
  }
}

Picklist _picklist({
  String id = 'p1',
  String customer = 'Aymen',
  String status = Picklist.statusPending,
  DateTime? created,
}) => Picklist(
  id: id,
  customerName: customer,
  status: status,
  createdBy: 'u1',
  createdAt: created ?? DateTime(2026, 11, 6),
  updatedAt: created ?? DateTime(2026, 11, 6),
);

PicklistItem _item({
  String id = 'i1',
  String product = 'Sugar',
  int requested = 5,
  int taken = 0,
  String unit = 'Karton',
  int price = 4550,
}) => PicklistItem(
  id: id,
  picklistId: 'p1',
  productName: product,
  requestedQty: requested,
  takenQty: taken,
  unit: unit,
  unitPriceMinorUnits: price,
  lineTotalMinorUnits: price * requested,
  updatedAt: DateTime(2026, 11, 6),
);

User _user() => User(
  id: 'u1',
  username: 'owner',
  passwordHash: 'x',
  salt: 'y',
  role: 'OWNER',
);

User _staff(List<String> permissions) => User(
  id: 'u2',
  username: 'staff',
  passwordHash: 'x',
  salt: 'y',
  role: 'CASHIER',
  permissions: permissions,
);

Future<void> _pump(WidgetTester tester, Widget home, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.dark(), home: home));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('create list is a two-step dialog with an empty quantity', (
    tester,
  ) async {
    final repo = _FakeRepo(
      customers: [
        PicklistCustomer(
          id: 'c1',
          name: 'Aymen',
          createdAt: DateTime(2026, 11, 6),
        ),
      ],
    );
    await _pump(
      tester,
      WarehouseScreen(
        repository: repo,
        currentUser: _staff([FeatureDef.warehouse]),
      ),
      const Size(390, 844),
    );
    await tester.pumpAndSettle();

    // Step one: the + opens the customer window, not the product form.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('New List (1/2)'), findsOneWidget);
    expect(find.text('Select Customer'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(find.text('Choose a customer.'), findsOneWidget);

    await tester.tap(find.text('Select Customer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aymen').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // Step two: item detail with an explicit quantity, never a default 1.
    expect(find.text('New List (2/2)'), findsOneWidget);
    expect(find.text('Send to Warehouse'), findsOneWidget);
    expect(find.text('Karton'), findsOneWidget);

    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(1)).controller?.text, isEmpty);

    await tester.enterText(fields.at(0), 'Sugar');
    await tester.enterText(fields.at(1), '5');
    await tester.enterText(fields.at(2), '45.50');
    await tester.pump();

    expect(find.text('227.50 Br'), findsNWidgets(2));

    // The unit is a fixed-choice dropdown, not a text field.
    await tester.tap(find.text('Karton').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Derzen').last);
    await tester.pumpAndSettle();
    expect(find.text('Derzen'), findsOneWidget);

    await tester.tap(find.text('Add Product'));
    await tester.pumpAndSettle();
    expect(find.text('PRODUCT 2'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('shop worker sends the unit and quantities to the repository', (
    tester,
  ) async {
    final repo = _FakeRepo(
      customers: [
        PicklistCustomer(
          id: 'c1',
          name: 'Aymen',
          createdAt: DateTime(2026, 11, 6),
        ),
      ],
    );
    await _pump(
      tester,
      WarehouseScreen(
        repository: repo,
        currentUser: _staff([FeatureDef.warehouse]),
      ),
      const Size(390, 844),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select Customer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aymen').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Sugar');
    await tester.enterText(fields.at(1), '5');
    await tester.enterText(fields.at(2), '45.50');
    await tester.pump();

    await tester.tap(find.text('Karton').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Derzen').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send to Warehouse'));
    await tester.pumpAndSettle();

    expect(find.text('New List (2/2)'), findsNothing);
    expect(repo.createdHeader?.customerName, 'Aymen');
    expect(repo.createdItems, hasLength(1));
    final line = repo.createdItems!.single;
    expect(line.productName, 'Sugar');
    expect(line.requestedQty, 5);
    expect(line.unit, 'Derzen');
    expect(line.unitPriceMinorUnits, 4550);
    expect(line.lineTotalMinorUnits, 22750);
  });

  testWidgets('completed list shows ticked boxes and hides money', (
    tester,
  ) async {
    final repo = _FakeRepo(items: [_item(taken: 5)]);
    await _pump(
      tester,
      PicklistDetailScreen(
        repository: repo,
        picklist: _picklist(status: Picklist.statusCompleted),
      ),
      const Size(390, 844),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('DONE — this list is finished.'), findsOneWidget);
    expect(find.text('All items taken'), findsOneWidget);
    expect(find.text('5 Karton requested'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(find.text('Taken'), findsOneWidget);
    expect(find.textContaining('Br'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('warehouse worker ticks a box and the pick auto-saves', (
    tester,
  ) async {
    final repo = _FakeRepo(items: [_item()]);
    await _pump(
      tester,
      PicklistDetailScreen(repository: repo, picklist: _picklist()),
      const Size(1280, 800),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('5 Karton requested'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    expect(find.textContaining('Br'), findsNothing);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(repo.toggled, isTrue);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(find.text('DONE — this list is finished.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shop worker sees only the New List screen', (tester) async {
    final repo = _FakeRepo(
      picklists: [_picklist(id: 'p1', customer: 'Open Order')],
    );
    await _pump(
      tester,
      WarehouseScreen(
        repository: repo,
        currentUser: _staff([FeatureDef.warehouse]),
      ),
      const Size(390, 844),
    );
    await tester.pumpAndSettle();

    expect(find.text('New List'), findsOneWidget);
    // The action is now a single large + circle, not a labelled card.
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.text('Lists to fill'), findsNothing);
    // History is read-only and available to the shop side too (with money).
    expect(find.text('History'), findsOneWidget);
    expect(find.text('To Fill'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fill worker sees the queue only, with no money', (tester) async {
    final repo = _FakeRepo(
      picklists: [
        _picklist(id: 'p1', customer: 'Open Order'),
        _picklist(
          id: 'p2',
          customer: 'Finished Order',
          status: Picklist.statusCompleted,
        ),
      ],
      items: [_item(id: 'i1', product: 'Sugar')],
    );
    await _pump(
      tester,
      WarehouseScreen(
        repository: repo,
        currentUser: _staff([FeatureDef.warehouseFill]),
      ),
      const Size(390, 844),
    );
    await tester.pumpAndSettle();

    expect(find.text('Lists to fill'), findsOneWidget);
    expect(find.text('Open Order'), findsOneWidget);
    expect(find.text('Sugar'), findsOneWidget);
    expect(find.text('Finished Order'), findsNothing);
    expect(find.text('NEW LIST'), findsNothing);
    expect(find.textContaining('Br'), findsNothing);
    expect(find.text('History'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner gets a switch between filling and creating', (
    tester,
  ) async {
    final repo = _FakeRepo(
      picklists: [_picklist(id: 'p1', customer: 'Open Order')],
    );
    await _pump(
      tester,
      WarehouseScreen(repository: repo, currentUser: _user()),
      const Size(390, 844),
    );
    await tester.pumpAndSettle();

    expect(find.text('To Fill'), findsOneWidget);
    expect(find.text('Lists to fill'), findsOneWidget);

    await tester.tap(find.text('New List'));
    await tester.pumpAndSettle();
    // The mode switch itself has an add icon; the body's large + circle is the
    // second one.
    expect(find.byIcon(Icons.add), findsNWidgets(2));
    expect(find.text('Lists to fill'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history drills date -> customer -> what was taken', (
    tester,
  ) async {
    final repo = _FakeRepo(
      picklists: [
        _picklist(id: 'p1', customer: 'Aymen'),
        _picklist(id: 'p2', customer: 'Semir'),
        _picklist(
          id: 'p3',
          customer: 'Qoder',
          status: Picklist.statusCompleted,
          created: DateTime(2026, 11, 5),
        ),
      ],
      items: [
        _item(id: 'i1', product: 'Chew', requested: 50, taken: 50),
        _item(id: 'i2', product: 'Flour', requested: 30, taken: 10),
      ],
    );
    await _pump(
      tester,
      WarehouseHistoryScreen(repository: repo),
      const Size(390, 844),
    );
    await tester.pumpAndSettle();

    expect(find.text('6 November 2026'), findsOneWidget);
    expect(find.text('5 November 2026'), findsOneWidget);
    expect(find.textContaining('2 customers'), findsOneWidget);

    await tester.tap(find.text('6 November 2026'));
    await tester.pumpAndSettle();
    expect(find.text('Aymen'), findsOneWidget);
    expect(find.text('Semir'), findsOneWidget);

    await tester.tap(find.text('Aymen'));
    await tester.pumpAndSettle();
    expect(find.text('Chew'), findsOneWidget);
    // Only the Asked quantity is shown; the Taken column was removed.
    expect(find.text('50'), findsOneWidget);
    expect(find.text('Flour'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(find.text('Taken'), findsNothing);
    expect(find.text('Asked'), findsOneWidget);
    expect(find.textContaining('Br'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shop-side history shows prices and the value taken', (
    tester,
  ) async {
    final repo = _FakeRepo(
      picklists: [_picklist(id: 'p1', customer: 'Aymen')],
      items: [
        _item(id: 'i1', product: 'Chew', requested: 50, taken: 50),
        _item(id: 'i2', product: 'Flour', requested: 30, taken: 10),
      ],
    );
    await _pump(
      tester,
      WarehouseHistoryScreen(repository: repo, showMoney: true),
      const Size(390, 844),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('6 November 2026'));
    await tester.pumpAndSettle();
    // The customer row carries the list's value taken.
    expect(find.textContaining('2,730.00 Br'), findsOneWidget);

    await tester.tap(find.text('Aymen'));
    await tester.pumpAndSettle();
    expect(find.text('Price'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(find.text('45.50 Br'), findsNWidgets(2));
    expect(find.text('2,275.00 Br'), findsOneWidget);
    expect(find.text('455.00 Br'), findsOneWidget);
    expect(find.text('Value taken'), findsOneWidget);
    expect(find.text('2,730.00 Br'), findsOneWidget);
    // Asked quantities only; the Taken column is gone.
    expect(find.text('50'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
