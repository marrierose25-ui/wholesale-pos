import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_core/pos_core.dart';
import 'package:pos_cloud_engine/pos_cloud_engine.dart';

const url = 'https://example.supabase.co/functions/v1/pos-api';

/// Records the last decoded request body + headers so tests can assert the
/// exact action/payload the client sends, and returns a canned server reply.
class _Recorder {
  Map<String, dynamic>? body;
  Map<String, String>? headers;
  http.Response Function(Map<String, dynamic> body) reply = (_) =>
      http.Response('{"ok":true}', 200);
}

CloudApiClient _clientWith(_Recorder rec, {String activation = 'MERCA-1'}) {
  final mock = MockClient((req) async {
    rec.body = jsonDecode(req.body) as Map<String, dynamic>;
    rec.headers = req.headers;
    return rec.reply(rec.body!);
  });
  return CloudApiClient(url: url, client: mock, activationCode: activation);
}

Product _product({String id = 'p1', bool active = true}) => Product(
  id: id,
  name: 'Sugar 50kg',
  code: 'SGR50',
  unit: 'bag',
  sellingPriceMinorUnits: 45000,
  isActive: active,
  createdAt: DateTime.parse('2026-01-01T00:00:00.000'),
  updatedAt: DateTime.parse('2026-01-01T00:00:00.000'),
);

void main() {
  group('CloudApiClient', () {
    test('call returns the decoded body on ok:true', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response('{"ok":true,"value":"x"}', 200);
      final api = _clientWith(rec);
      final res = await api.call('get_setting', {'key': 'theme'});
      expect(res['value'], 'x');
      expect(rec.body!['action'], 'get_setting');
      expect(rec.body!['key'], 'theme');
    });

    test('call throws CloudApiException carrying the server error', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response('{"ok":false,"error":"Nope."}', 400);
      final api = _clientWith(rec);
      await expectLater(
        api.call('login'),
        throwsA(
          isA<CloudApiException>().having((e) => e.message, 'message', 'Nope.'),
        ),
      );
    });

    test('attaches the bearer token once signed in', () async {
      final rec = _Recorder();
      final api = _clientWith(rec);
      api.token = 'jwt-abc';
      await api.call('list_users');
      expect(rec.headers!['Authorization'], 'Bearer jwt-abc');
    });
  });

  group('CloudProductRepository', () {
    test('getAllActive maps server rows to Products', () async {
      final serverRow = _product().toMap()
        ..remove('is_active')
        ..['is_active'] = 1;
      final rec = _Recorder()
        ..reply = (_) => http.Response(
          jsonEncode({
            'ok': true,
            'products': [serverRow],
          }),
          200,
        );
      final repo = CloudProductRepository(_clientWith(rec));
      final products = await repo.getAllActive();
      expect(products, hasLength(1));
      expect(products.first.id, 'p1');
      expect(products.first.sellingPriceMinorUnits, 45000);
      expect(products.first.isActive, isTrue);
      expect(rec.body!['action'], 'list_products');
    });

    test('getAllInactive sends the inactive flag', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response('{"ok":true,"products":[]}', 200);
      final repo = CloudProductRepository(_clientWith(rec));
      await repo.getAllInactive();
      expect(rec.body!['action'], 'list_products');
      expect(rec.body!['inactive'], true);
    });

    test('save posts the product map verbatim', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response('{"ok":true,"id":"p1"}', 200);
      final repo = CloudProductRepository(_clientWith(rec));
      await repo.save(_product());
      expect(rec.body!['action'], 'save_product');
      expect(
        (rec.body!['product'] as Map<String, dynamic>)['name'],
        'Sugar 50kg',
      );
    });
  });

  group('CloudUserRepository', () {
    test(
      'authenticate stores the session token and returns the user',
      () async {
        final rec = _Recorder()
          ..reply = (_) => http.Response(
            jsonEncode({
              'ok': true,
              'token': 'jwt-1',
              'user_id': 'u1',
              'username': 'owner',
              'role': 'OWNER',
              'permissions': ['pos', 'history'],
            }),
            200,
          );
        final api = _clientWith(rec);
        final repo = CloudUserRepository(api);
        final user = await repo.authenticate(
          '+251 912 345 678',
          'long-strong-password',
        );
        expect(user?.id, 'u1');
        expect(user?.role, 'OWNER');
        // The hash/salt never reach the client.
        expect(user?.passwordHash, isEmpty);
        // login carries the permission list through to the User.
        expect(user?.permissions, ['pos', 'history']);
        expect(api.token, 'jwt-1');
        expect(rec.body!['action'], 'login');
        expect(rec.body!['activation_code'], 'MERCA-1');
        // The typed spelling is folded to the canonical phone before it ships.
        expect(rec.body!['username'], '0912345678');
      },
    );

    test('authenticate returns null when the server refuses', () async {
      final rec = _Recorder()
        ..reply = (_) =>
            http.Response('{"ok":false,"error":"Invalid credentials."}', 401);
      final api = _clientWith(rec);
      final repo = CloudUserRepository(api);
      expect(await repo.authenticate('owner', 'wrong'), isNull);
      expect(api.token, isNull);
    });

    test(
      'getAllUsers maps active boolean rows without leaking secrets',
      () async {
        final rec = _Recorder()
          ..reply = (_) => http.Response(
            jsonEncode({
              'ok': true,
              'users': [
                {
                  'id': 'u1',
                  'username': 'owner',
                  'role': 'OWNER',
                  'active': true,
                },
                {
                  'id': 'u2',
                  'username': 'sam',
                  'role': 'CASHIER',
                  'active': false,
                  'permissions': ['pos', 'register'],
                },
              ],
            }),
            200,
          );
        final repo = CloudUserRepository(_clientWith(rec));
        final users = await repo.getAllUsers();
        expect(users, hasLength(2));
        expect(users.first.isActive, isTrue);
        expect(users.last.isActive, isFalse);
        expect(users.last.passwordHash, isEmpty);
        expect(users.last.permissions, ['pos', 'register']);
      },
    );

    test('createUser posts the role/password contract', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response('{"ok":true,"id":"u9"}', 200);
      final repo = CloudUserRepository(_clientWith(rec));
      await repo.createUser(
        '+251 912 345 678',
        'secret1234',
        'CASHIER',
        permissions: ['pos', 'history'],
      );
      expect(rec.body!['action'], 'create_user');
      expect(rec.body!['username'], '0912345678');
      expect(rec.body!['role'], 'CASHIER');
      expect(rec.body!['permissions'], ['pos', 'history']);
    });

    test('setUserPermissions sends the set_user_permissions action', () async {
      final rec = _Recorder()..reply = (_) => http.Response('{"ok":true}', 200);
      final repo = CloudUserRepository(_clientWith(rec));
      await repo.setUserPermissions('u9', ['pos', 'reports']);
      expect(rec.body!['action'], 'set_user_permissions');
      expect(rec.body!['target_user_id'], 'u9');
      expect(rec.body!['permissions'], ['pos', 'reports']);
    });

    test('setUserPhone posts the canonical phone to set_user_phone', () async {
      final rec = _Recorder()..reply = (_) => http.Response('{"ok":true}', 200);
      final repo = CloudUserRepository(_clientWith(rec));
      await repo.setUserPhone(
        userId: 'u9',
        phone: '0933-333-333',
        actingUserId: 'u1',
      );
      expect(rec.body!['action'], 'set_user_phone');
      expect(rec.body!['target_user_id'], 'u9');
      expect(rec.body!['phone'], '0933333333');
    });

    test('createUser refuses a non-phone identifier locally', () async {
      final rec = _Recorder();
      final repo = CloudUserRepository(_clientWith(rec));
      await expectLater(
        repo.createUser('sam', 'secret1234', 'CASHIER'),
        throwsA(predicate((e) => e.toString().contains('valid phone number'))),
      );
      expect(rec.body, isNull);
    });

    test('deleteUser posts the target to delete_user', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response('{"ok":true,"retained":false}', 200);
      final repo = CloudUserRepository(_clientWith(rec));
      await repo.deleteUser(targetUserId: 'u9', actingUserId: 'u1');
      expect(rec.body!['action'], 'delete_user');
      expect(rec.body!['target_user_id'], 'u9');
    });
  });

  group('CloudShiftRepository', () {
    test('getShiftSummary casts server numbers to int', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response(
          jsonEncode({
            'ok': true,
            'summary': {
              'cash_sales': 5000,
              'bank_sales': 1200,
              'expected_cash': 6200,
            },
          }),
          200,
        );
      final repo = CloudShiftRepository(_clientWith(rec));
      final shift = Shift.fromMap(const {
        'id': 's1',
        'cashier_id': 'u1',
        'opening_cash_minor_units': 0,
        'status': 'OPEN',
        'opened_at': '2026-01-01T00:00:00.000',
      });
      final summary = await repo.getShiftSummary(shift);
      expect(summary['expected_cash'], 6200);
      expect(summary['cash_sales'], isA<int>());
      expect(rec.body!['action'], 'shift_summary');
      expect(rec.body!['shift_id'], 's1');
    });

    test(
      'closeShift posts the counted cash under the tenant shift id',
      () async {
        final rec = _Recorder()
          ..reply = (_) => http.Response('{"ok":true}', 200);
        final repo = CloudShiftRepository(_clientWith(rec));
        final shift = Shift.fromMap(const {
          'id': 's9',
          'cashier_id': 'u1',
          'opening_cash_minor_units': 100,
          'status': 'OPEN',
          'opened_at': '2026-01-01T00:00:00.000',
        });
        await repo.closeShift(shift, 900000);
        expect(rec.body!['action'], 'close_shift');
        expect(rec.body!['shift_id'], 's9');
        expect(rec.body!['closing_cash_minor_units'], 900000);
      },
    );

    test('getActiveShift returns null when none is open', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response('{"ok":true,"shift":null}', 200);
      final repo = CloudShiftRepository(_clientWith(rec));
      expect(await repo.getActiveShift(), isNull);
    });

    test('implements the shared ShiftRepository interface type', () {
      final repo = CloudShiftRepository(_clientWith(_Recorder()));
      expect(repo, isA<ShiftRepository>());
    });
  });

  group('CloudSaleRepository', () {
    // A hydrated server row = a sales-table row + items + the two display-only
    // join fields pos-api adds (cashier_name, has_pending_void_request).
    Map<String, dynamic> saleRow({
      String id = 's1',
      String? voidedShiftId,
      String shiftId = 'sh1',
      String status = 'COMPLETED',
      bool pendingVoid = false,
      List<Map<String, dynamic>> items = const [],
    }) => {
      'id': id,
      'receipt_number': 'REC-20260101-0001',
      'cashier_id': 'u1',
      'device_id': 'dev-1',
      'shift_id': shiftId,
      'customer_name': 'Walk-in',
      'payment_method': 'CASH',
      'subtotal_minor_units': 45000,
      'discount_minor_units': 0,
      'total_minor_units': 45000,
      'amount_paid_minor_units': 45000,
      'change_minor_units': 0,
      'status': status,
      'void_reason': null,
      'voided_at': null,
      'voided_by': null,
      'voided_shift_id': voidedShiftId,
      'created_at': '2026-01-01T09:00:00.000',
      'synced_at': null,
      'cashier_name': 'owner',
      'has_pending_void_request': pendingVoid,
      'items': items,
    };

    test('saveSale posts the sale aggregate', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response('{"ok":true,"id":"s1"}', 200);
      final repo = CloudSaleRepository(_clientWith(rec));
      final sale = Sale(
        id: 's1',
        receiptNumber: 'REC-20260101-0001',
        cashierId: 'u1',
        deviceId: 'dev-1',
        shiftId: 'sh1',
        subtotalMinorUnits: 45000,
        discountMinorUnits: 0,
        totalMinorUnits: 45000,
        amountPaidMinorUnits: 45000,
        changeMinorUnits: 0,
        createdAt: DateTime.parse('2026-01-01T09:00:00.000'),
        items: [
          SaleItem(
            id: 'i1',
            saleId: 's1',
            productId: 'p1',
            productNameSnapshot: 'Sugar 50kg',
            unitPriceSnapshotMinorUnits: 45000,
            quantityText: '1',
            billingQuantityMilliunits: 1000,
            lineTotalMinorUnits: 45000,
          ),
        ],
      );
      await repo.saveSale(sale);
      expect(rec.body!['action'], 'insert_sale');
      expect((rec.body!['sale'] as Map<String, dynamic>)['id'], 's1');
      final items = rec.body!['items'] as List;
      expect(items, hasLength(1));
      expect(
        (items.first as Map<String, dynamic>)['product_name_snapshot'],
        'Sugar 50kg',
      );
    });

    test('nextReceiptNumber returns the server-issued number', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response(
          '{"ok":true,"receipt_number":"REC-20260101-0007"}',
          200,
        );
      final repo = CloudSaleRepository(_clientWith(rec));
      expect(await repo.nextReceiptNumber(), 'REC-20260101-0007');
    });

    test('getSales rebuilds the hydrated Sale aggregate', () async {
      final row = saleRow(
        items: [
          {
            'id': 'i1',
            'sale_id': 's1',
            'product_id': 'p1',
            'product_name_snapshot': 'Sugar 50kg',
            'unit_price_snapshot_minor_units': 45000,
            'quantity_text': '1',
            'billing_quantity_milliunits': 1000,
            'line_discount_minor_units': 0,
            'line_total_minor_units': 45000,
            'notes': null,
          },
        ],
      );
      final rec = _Recorder()
        ..reply = (_) => http.Response(
          jsonEncode({
            'ok': true,
            'sales': [row],
          }),
          200,
        );
      final repo = CloudSaleRepository(_clientWith(rec));
      final sales = await repo.getSales(searchQuery: ' sugar', status: 'ALL');
      expect(sales, hasLength(1));
      expect(sales.first.cashierName, 'owner');
      expect(sales.first.totalMinorUnits, 45000);
      expect(sales.first.items, hasLength(1));
      expect(sales.first.items.first.lineTotalMinorUnits, 45000);
      // 'ALL' status and blank-trimmed query behaviour: status ALL is dropped,
      // the trimmed query is forwarded lower-cased source untouched.
      expect(rec.body!.containsKey('status'), isFalse);
      expect(rec.body!['search_query'], 'sugar');
    });

    test('getDashboardStats casts server numbers to int', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response(
          jsonEncode({
            'ok': true,
            'stats': {
              'revenue': 120000,
              'sales_count': 3,
              'cash_revenue': 90000,
              'bank_revenue': 30000,
              'average_sale': 40000,
              'expected_cash': 90000,
              'is_shift_open': 1,
              'void_count': 0,
              'pending_void_requests': 2,
            },
          }),
          200,
        );
      final repo = CloudSaleRepository(_clientWith(rec));
      final stats = await repo.getDashboardStats();
      expect(stats['revenue'], 120000);
      expect(stats['revenue'], isA<int>());
      expect(stats['pending_void_requests'], 2);
      // Defaults to today's range when the caller passes none.
      expect(rec.body!['action'], 'dashboard_summary');
      expect(rec.body!['period_start'], isA<String>());
    });

    test(
      'getProductSalesSummary renames server keys to the native shape',
      () async {
        final rec = _Recorder()
          ..reply = (_) => http.Response(
            jsonEncode({
              'ok': true,
              'product_summary': [
                {
                  'product_name_snapshot': 'Sugar 50kg',
                  'qty': 1500,
                  'lines': 2,
                  'revenue': 67500,
                },
              ],
              'cashier_performance': [
                {'username': 'owner', 'total_sales': 2, 'total_revenue': 67500},
              ],
            }),
            200,
          );
        final repo = CloudSaleRepository(_clientWith(rec));
        final summary = await repo.getProductSalesSummary();
        expect(summary.first['product_name_snapshot'], 'Sugar 50kg');
        expect(summary.first['total_qty_milliunits'], 1500);
        expect(summary.first['line_count'], 2);
        expect(summary.first['total_revenue'], 67500);
        final perf = await repo.getCashierPerformance();
        expect(perf.first['username'], 'owner');
        expect(perf.first['total_revenue'], 67500);
      },
    );

    test(
      'getVoidedSalesForShift filters the local void-scoping rule',
      () async {
        final rows = [
          saleRow(id: 'a', voidedShiftId: 'sh1', status: 'VOIDED'),
          saleRow(
            id: 'b',
            voidedShiftId: null,
            shiftId: 'sh1',
            status: 'VOIDED',
          ),
          saleRow(
            id: 'c',
            voidedShiftId: 'sh2',
            shiftId: 'sh2',
            status: 'VOIDED',
          ),
        ];
        final rec = _Recorder()
          ..reply = (_) =>
              http.Response(jsonEncode({'ok': true, 'sales': rows}), 200);
        final repo = CloudSaleRepository(_clientWith(rec));
        final voids = await repo.getVoidedSalesForShift('sh1');
        expect(voids.map((s) => s.id).toSet(), {'a', 'b'});
        expect(rec.body!['status'], 'VOIDED');
      },
    );
  });

  group('CloudFinanceRepository', () {
    test('getCategories maps FinanceCategory rows', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response(
          jsonEncode({
            'ok': true,
            'categories': [
              {
                'id': 'c1',
                'name': 'Bank X',
                'created_at': '2026-01-01T00:00:00.000',
                'updated_at': '2026-01-01T00:00:00.000',
              },
            ],
          }),
          200,
        );
      final repo = CloudFinanceRepository(_clientWith(rec));
      final cats = await repo.getCategories('u1');
      expect(cats, hasLength(1));
      expect(cats.first.name, 'Bank X');
      expect(rec.body!['action'], 'finance_categories');
    });

    test('addEntry returns the hydrated FinanceEntry', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response(
          jsonEncode({
            'ok': true,
            'entry': {
              'id': 'e1',
              'category_id': 'c1',
              'source': 'Bank X',
              'amount_minor_units': 50000,
              'description': 'Draw',
              'status': 'PENDING',
              'entry_date': '2026-01-01T00:00:00.000',
              'created_at': '2026-01-01T00:00:00.000',
              'created_by': 'u1',
              'completed_at': null,
              'completed_by': null,
              'updated_at': '2026-01-01T00:00:00.000',
              'category_name': 'Bank X',
            },
          }),
          200,
        );
      final repo = CloudFinanceRepository(_clientWith(rec));
      final entry = await repo.addEntry(
        ownerId: 'u1',
        categoryId: 'c1',
        source: 'Bank X',
        amountMinorUnits: 50000,
        description: 'Draw',
      );
      expect(entry.id, 'e1');
      expect(entry.amountMinorUnits, 50000);
      expect(entry.isCompleted, isFalse);
      expect(entry.categoryName, 'Bank X');
      expect(rec.body!['action'], 'finance_add_entry');
      expect(rec.body!['amount_minor_units'], 50000);
    });

    test('searchEntries forwards only the filters that are set', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response('{"ok":true,"entries":[]}', 200);
      final repo = CloudFinanceRepository(_clientWith(rec));
      await repo.searchEntries(
        ownerId: 'u1',
        categoryId: 'c1',
        status: 'ALL',
        searchQuery: '  ',
      );
      expect(rec.body!['action'], 'finance_search_entries');
      expect(rec.body!['category_id'], 'c1');
      expect(rec.body!.containsKey('status'), isFalse);
      expect(rec.body!.containsKey('search_query'), isFalse);
    });

    test('getPersonTotals maps the server totals keys', () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response(
          jsonEncode({
            'ok': true,
            'totals': {'pending_total': 100, 'completed_total': 200},
          }),
          200,
        );
      final repo = CloudFinanceRepository(_clientWith(rec));
      final totals = await repo.getPersonTotals('u1', 'c1');
      expect(totals['pending_total'], 100);
      expect(totals['completed_total'], 200);
    });
  });

  group('CloudInventoryRepository', () {
    test('createProductWithStock sends the selected image to pos-api',
        () async {
      final rec = _Recorder()
        ..reply = (_) => http.Response('{"ok":true,"product_id":"p1"}', 200);
      final repo = CloudInventoryRepository(_clientWith(rec));
      final product = Product(
        id: 'p1',
        name: 'Sugar 50kg',
        code: 'SGR50',
        unit: 'bag',
        sellingPriceMinorUnits: 45000,
        boughtPriceMinorUnits: 30000,
        imageData: 'aGVsbG8=',
        createdAt: DateTime.parse('2026-01-01T00:00:00.000'),
        updatedAt: DateTime.parse('2026-01-01T00:00:00.000'),
      );

      await repo.createProductWithStock(
        product: product,
        storeId: 'store-1',
        onHandMilliunits: 10000,
        reorderMilliunits: 2000,
      );

      expect(rec.body!['action'], 'create_inventory_product');
      final sent = rec.body!['product'] as Map<String, dynamic>;
      expect(sent['image_data'], 'aGVsbG8=');
      expect(sent['bought_price_minor_units'], 30000);
    });
  });
}
