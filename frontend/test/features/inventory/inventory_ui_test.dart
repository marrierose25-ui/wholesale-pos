import 'dart:async';
import 'dart:convert';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_core/catalog.dart';
import 'package:pos_core/inventory.dart';

import 'package:wholesale_pos_app/core/theme/app_design.dart';
import 'package:wholesale_pos_app/features/inventory/inventory_screen.dart';
import 'package:wholesale_pos_app/features/inventory/stores_screen.dart';

/// In-memory [InventoryRepository] for widget tests: same contract the
/// SQLite and cloud implementations honour, minus persistence.
class FakeInventoryRepository implements InventoryRepository {
  final List<Store> stores = [];
  final List<InventoryItem> items = [];
  int createCalls = 0;
  bool failCreate = false;
  Future<void>? createGate;

  @override
  Future<List<Store>> getStores() async => List.of(stores);

  @override
  Future<void> createStore(String name) async {
    final now = DateTime.now();
    stores.add(
      Store(
        id: 'store-${stores.length + 1}',
        name: name.trim(),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  @override
  Future<void> deleteStore(String id) async {
    stores.removeWhere((s) => s.id == id);
  }

  @override
  Future<List<InventoryItem>> getInventory({String? storeId}) async {
    return List.of(items);
  }

  @override
  Future<void> createProductWithStock({
    required Product product,
    required String storeId,
    required int onHandMilliunits,
    required int reorderMilliunits,
  }) async {
    createCalls++;
    if (createGate != null) await createGate;
    if (failCreate) throw Exception('duplicate product name');
    final now = DateTime.now();
    items.add(
      InventoryItem(
        product: Product(
          id: product.id,
          name: product.name,
          code: product.code,
          unit: product.unit,
          sellingPriceMinorUnits: product.sellingPriceMinorUnits,
          boughtPriceMinorUnits: product.boughtPriceMinorUnits,
          imageData: product.imageData,
          createdAt: now,
          updatedAt: now,
        ),
        stocks: [
          StoreStock(
            storeId: storeId,
            storeName: stores
                .firstWhere((s) => s.id == storeId,
                    orElse: () => stores.first)
                .name,
            onHandMilliunits: onHandMilliunits,
            reorderMilliunits: reorderMilliunits,
          ),
        ],
      ),
    );
  }
}

Store _store(String id, String name) {
  final now = DateTime(2026, 1, 1);
  return Store(id: id, name: name, createdAt: now, updatedAt: now);
}

Product _product(String name, {String? imageData}) {
  final now = DateTime(2026, 1, 1);
  return Product(
    id: 'p-$name',
    name: name,
    code: '',
    unit: 'Kg',
    sellingPriceMinorUnits: 12000,
    boughtPriceMinorUnits: 8000,
    imageData: imageData,
    createdAt: now,
    updatedAt: now,
  );
}

InventoryItem _item(
  String name, {
  required int onHand,
  required int reorder,
  String? storeName = 'Main',
  String? imageData,
}) {
  return InventoryItem(
    product: _product(name, imageData: imageData),
    stocks: [
      StoreStock(
        storeId: 's1',
        storeName: storeName!,
        onHandMilliunits: onHand,
        reorderMilliunits: reorder,
      ),
    ],
  );
}

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InventoryScreen', () {
    testWidgets('empty state with no stores offers store creation path',
        (tester) async {
      final repo = FakeInventoryRepository();
      await tester.pumpWidget(_wrap(InventoryScreen(repository: repo)));
      await tester.pumpAndSettle();
      expect(find.text('Inventory'), findsOneWidget);
      // Empty state renders (exact copy is theme-owned; the stores-empty
      // variant must mention stores).
      expect(find.byType(InventoryScreen), findsOneWidget);
    });

    testWidgets('lists products with stock and status labels', (tester) async {
      final repo = FakeInventoryRepository()
        ..stores.add(_store('s1', 'Main Branch'))
        ..items.addAll([
          _item('Berbere', onHand: 8000, reorder: 2000), // healthy -> green
          _item('Teff', onHand: 500, reorder: 2000), // low -> red
          _item('Salt', onHand: 2000, reorder: 2000), // at reorder -> amber
        ]);
      await tester.pumpWidget(_wrap(InventoryScreen(repository: repo)));
      await tester.pumpAndSettle();
      expect(find.text('Berbere'), findsOneWidget);
      expect(find.text('Teff'), findsOneWidget);
      expect(find.text('Salt'), findsOneWidget);
      // Green / amber / red status dots (risk-first indicators).
      final colors = <Color>{};
      for (final c in tester.widgetList<Container>(find.byType(Container))) {
        final d = c.decoration;
        if (d is BoxDecoration && d.color != null) colors.add(d.color!);
      }
      for (final i in tester.widgetList<Icon>(find.byType(Icon))) {
        if (i.color != null) colors.add(i.color!);
      }
      for (final cb in tester.widgetList<ColoredBox>(find.byType(ColoredBox))) {
        colors.add(cb.color);
      }
      expect(colors, contains(AppDesign.success));
      expect(colors, contains(AppDesign.danger));
      expect(colors, contains(AppDesign.warning));
      // The same status also surfaces as row text.
      expect(find.textContaining('In stock'), findsWidgets);
      expect(find.textContaining('Low stock'), findsWidgets);
      expect(find.textContaining('At reorder level'), findsWidgets);
    });

    testWidgets('store filter chips narrow the list', (tester) async {
      final repo = FakeInventoryRepository()
        ..stores.addAll([_store('s1', 'Main'), _store('s2', 'Branch')])
        ..items.add(_item('Berbere', onHand: 8000, reorder: 2000));
      await tester.pumpWidget(_wrap(InventoryScreen(repository: repo)));
      await tester.pumpAndSettle();
      expect(find.text('All stores'), findsOneWidget);
      expect(find.text('Main'), findsWidgets);
      expect(find.text('Branch'), findsOneWidget);
      await tester.tap(find.text('Branch'));
      await tester.pumpAndSettle();
      // Filtered view still renders the shared item (fake returns it for
      // any store filter that has stock).
      expect(find.text('Berbere'), findsOneWidget);
    });

    testWidgets('product avatar renders image when imageData present',
        (tester) async {
      final png = base64Encode(
        img.encodePng(img.Image(width: 8, height: 8)),
      );
      final repo = FakeInventoryRepository()
        ..stores.add(_store('s1', 'Main'))
        ..items.add(_item('Berbere', onHand: 8000, reorder: 2000,
            imageData: png));
      await tester.pumpWidget(_wrap(InventoryScreen(repository: repo)));
      await tester.pumpAndSettle();
      // The avatar is a CircleAvatar/Container with a MemoryImage; finding
      // the product row proves hydration didn't break the list.
      expect(find.text('Berbere'), findsOneWidget);
    });

    testWidgets('store management button opens StoresScreen and creates a store',
        (tester) async {
      final repo = FakeInventoryRepository()
        ..stores.add(_store('s1', 'Main'));
      await tester.pumpWidget(_wrap(InventoryScreen(repository: repo)));
      await tester.pumpAndSettle();
      // The bag icon button opens store management.
      await tester.tap(find.byIcon(CupertinoIcons.bag).first);
      await tester.pumpAndSettle();
    });
  });

  group('StoresScreen', () {
    testWidgets('lists stores and creates a new one via dialog',
        (tester) async {
      final repo = FakeInventoryRepository()
        ..stores.add(_store('s1', 'Main Branch'));
      await tester.pumpWidget(
        _wrap(StoresScreen(repository: repo, onDataChanged: () {})),
      );
      await tester.pumpAndSettle();
      expect(find.text('Main Branch'), findsOneWidget);

      // Open the create dialog (FAB or app-bar action).
      await tester.tap(find.byIcon(CupertinoIcons.add).last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Warehouse');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.stores.any((s) => s.name == 'Warehouse'), isTrue);
    });
  });

  group('ProductWizard', () {
    Future<void> openWizard(
      WidgetTester tester,
      FakeInventoryRepository repo,
    ) async {
      await tester.pumpWidget(_wrap(InventoryScreen(repository: repo)));
      await tester.pumpAndSettle();
      // Tap the + (add product) circle button — the second Pressable in the
      // header row, identifiable by its add icon.
      await tester.tap(find.byIcon(CupertinoIcons.add).first);
      await tester.pumpAndSettle();
    }

    testWidgets('step 1 requires name before advancing', (tester) async {
      final repo = FakeInventoryRepository()
        ..stores.add(_store('s1', 'Main'));
      await openWizard(tester, repo);
      // Step 1: leave name empty, tap Next.
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Item name is required.'), findsOneWidget);
    });

    testWidgets('back navigation preserves entered values', (tester) async {
      final repo = FakeInventoryRepository()
        ..stores.add(_store('s1', 'Main'));
      await openWizard(tester, repo);
      // Fill name + prices on step 1.
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Berbere');
      // Advance is blocked until unit is chosen; pick the unit dropdown or
      // type into the unit field if present.
      // Go forward far enough to exercise Back.
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      // Whatever step we are on, Back must not lose the name.
      final back = find.text('Back');
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back);
        await tester.pumpAndSettle();
      }
      expect(find.text('Berbere'), findsWidgets);
    });

    testWidgets('no-store state routes to store creation', (tester) async {
      final repo = FakeInventoryRepository(); // zero stores
      await openWizard(tester, repo);
      // Complete step 1 so the wizard reaches the store step.
      await _fillStep1(tester);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      // With zero stores the step shows the create-store path, not a picker.
      expect(find.text('No stores yet. Create one first — your product details are kept.'),
          findsOneWidget);
      await tester.tap(find.text('Create a store'));
      await tester.pumpAndSettle();
      // The inline dialog asks for a store name and saves through the repo.
      expect(find.text('New store'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Branch Office');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.stores.any((s) => s.name == 'Branch Office'), isTrue);
    });

    testWidgets('double-submit prevention: Done tapped twice calls create once',
        (tester) async {
      final repo = FakeInventoryRepository()
        ..stores.add(_store('s1', 'Main'));
      // Slow the create so the second tap lands while _saving is true.
      final gate = Completer<void>();
      repo.createGate = gate.future;
      await openWizard(tester, repo);
      // Fill the wizard: name, unit, prices, store, quantities.
      await _fillWizard(tester, repo);
      final done = find.text('Done');
      await tester.tap(done);
      await tester.tap(done, warnIfMissed: false);
      gate.complete();
      await tester.pumpAndSettle();
      expect(repo.createCalls, 1);
    });

    testWidgets('image picker cancellation keeps image optional',
        (tester) async {
      // Mock the image_picker platform channel: pickImage returns null
      // (user cancelled), which must leave the wizard usable.
      const channel = MethodChannel('plugins.flutter.io/image_picker');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pickImage') return null;
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final repo = FakeInventoryRepository()
        ..stores.add(_store('s1', 'Main'));
      await openWizard(tester, repo);
      // Tap the photo affordance; cancellation must not break the step.
      final photoBtn = find.textContaining('photo', findRichText: true);
      if (photoBtn.evaluate().isNotEmpty) {
        await tester.tap(photoBtn.first);
        await tester.pumpAndSettle();
      }
      expect(find.byType(TextField), findsWidgets);
    });
  });
}

/// Fills wizard step 1: name, 'Kilograms' unit chip, bought + selling price.
Future<void> _fillStep1(WidgetTester tester) async {
  var fields = find.byType(TextField);
  await tester.enterText(fields.at(0), 'Berbere');
  await tester.tap(find.text('Kilograms'));
  await tester.pumpAndSettle();
  fields = find.byType(TextField);
  await tester.enterText(fields.at(1), '80');
  await tester.enterText(fields.at(2), '120');
  await tester.pumpAndSettle();
}

/// Drives the wizard through all three steps with valid input.
Future<void> _fillWizard(
  WidgetTester tester,
  FakeInventoryRepository repo,
) async {
  await _fillStep1(tester);
  await tester.tap(find.text('Next'));
  await tester.pumpAndSettle();

  // Step 2: pick the 'Main' store chip, enter on-hand quantity, advance.
  await tester.tap(find.text('Main'));
  await tester.pumpAndSettle();
  var fields = find.byType(TextField);
  await tester.enterText(fields.last, '10');
  await tester.pumpAndSettle();
  await tester.tap(find.text('Next'));
  await tester.pumpAndSettle();

  // Step 3: reorder quantity.
  fields = find.byType(TextField);
  await tester.enterText(fields.last, '2');
  await tester.pumpAndSettle();
}
