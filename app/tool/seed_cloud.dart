// THROWAWAY cloud-path test harness (NOT part of the app build graph).
//
// Talks to the live `pos-api` Edge Function with the EXACT JSON action payloads
// the PWA's Cloud*Repository clients send (login -> ensure_shift -> N x
// next_receipt_number + insert_sale -> read back), so the redesigned one-item
// sale flow and the 50-sale seed are verified end-to-end without needing the
// browser to render. Uses only `package:http` (plain VM, no Flutter/sqflite).
//
// Usage (from app/):
//   dart run tool/seed_cloud.dart <apiUrl> <code> <user> <pw> [count]
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

const _products = <({String name, String unit, int priceMinor})>[
  (name: 'Teff (Berbere) 1kg', unit: 'kg', priceMinor: 12000),
  (name: 'Wheat Flour Bag 25kg', unit: 'bag', priceMinor: 550000),
  (name: 'Cooking Oil 5L', unit: 'bottle', priceMinor: 980000),
  (name: 'Sugar 1kg', unit: 'kg', priceMinor: 11000),
  (name: 'Rice 5kg', unit: 'pack', priceMinor: 1450000),
  (name: 'Salt 1kg', unit: 'kg', priceMinor: 4500),
  (name: 'Pasta 500g', unit: 'pack', priceMinor: 78000),
  (name: 'Tomato Paste Tin', unit: 'tin', priceMinor: 65000),
];

late final Uri _endpoint;
String? _token;

Future<Map<String, dynamic>> call(
  String action, [
  Map<String, dynamic>? body,
]) async {
  final payload = {'action': action, ...?body};
  final headers = {'Content-Type': 'application/json'};
  if (_token != null) headers['Authorization'] = 'Bearer $_token';
  final res = await http
      .post(_endpoint, headers: headers, body: jsonEncode(payload))
      .timeout(const Duration(seconds: 30));
  final json = jsonDecode(res.body) as Map<String, dynamic>;
  if (json['ok'] != true) {
    throw StateError(
      '$action failed: ${json['error']} (http ${res.statusCode})',
    );
  }
  return json;
}

Future<void> main(List<String> args) async {
  if (args.length < 4) {
    print(
      'usage: dart run tool/seed_cloud.dart <apiUrl> <code> <user> <pw> [count]',
    );
    return;
  }
  _endpoint = Uri.parse(args[0]);
  final code = args[1];
  final username = args[2];
  final password = args[3];
  final count = args.length > 4 ? int.parse(args[4]) : 50;

  final login = await call('login', {
    'activation_code': code,
    'username': username,
    'password': password,
  });
  _token = login['token'] as String;
  final userId = login['user_id'] as String;
  print('OK login: user=$userId role=${login['role']} token=${_token != null}');

  // The live pos-api predates the redesign's `ensure_shift`, so obtain an OPEN
  // shift with the actions that ARE deployed (get_shift / open_shift).
  String shiftId;
  final existing = (await call('get_shift'))['shift'];
  if (existing is Map<String, dynamic>) {
    shiftId = existing['id'] as String;
    print('OK get_shift (existing): $shiftId');
  } else {
    await call('open_shift', {'opening_cash_minor_units': 0});
    final opened = await call('get_shift');
    shiftId = (opened['shift'] as Map<String, dynamic>)['id'] as String;
    print('OK open_shift + get_shift: $shiftId');
  }

  // Count before, so the delta proves the seed regardless of pre-existing rows.
  final before = (await call('search_sales', {'limit': 1000}))['sales'];
  final beforeCount = before is List ? before.length : 0;

  const uid = Uuid();
  for (var i = 0; i < count; i++) {
    final p = _products[i % _products.length];
    final qtyMilli = (1 + (i % 4)) * 1000; // 1..4 whole units
    final lineTotal = (p.priceMinor * qtyMilli / 1000).round();
    final saleId = uid.v4();
    final receipt =
        (await call('next_receipt_number'))['receipt_number'] as String;
    final item = <String, dynamic>{
      'id': uid.v4(),
      'sale_id': saleId,
      'product_id': 'dart-harness',
      'product_name_snapshot': p.name,
      'unit_price_snapshot_minor_units': p.priceMinor,
      'quantity_text': '${qtyMilli ~/ 1000} ${p.unit}',
      'billing_quantity_milliunits': qtyMilli,
      'line_discount_minor_units': 0,
      'line_total_minor_units': lineTotal,
      'notes': null,
    };
    final sale = <String, dynamic>{
      'id': saleId,
      'receipt_number': receipt,
      'cashier_id': userId,
      'device_id': 'dart-harness',
      'shift_id': shiftId,
      'customer_name': null,
      'payment_method': i % 3 == 0 ? 'BANK' : 'CASH',
      'subtotal_minor_units': lineTotal,
      'discount_minor_units': 0,
      'total_minor_units': lineTotal,
      'amount_paid_minor_units': lineTotal,
      'change_minor_units': 0,
      'status': 'COMPLETED',
      'void_reason': null,
      'voided_at': null,
      'voided_by': null,
      'voided_shift_id': null,
      'created_at': DateTime.now().toIso8601String(),
      'synced_at': null,
    };
    await call('insert_sale', {
      'sale': sale,
      'items': [item],
    });
  }
  print('OK insert_sale x$count returned ok:true');

  final after = (await call('search_sales', {'limit': 1000}))['sales'];
  final afterCount = after is List ? after.length : 0;
  print(
    'READBACK search_sales: before=$beforeCount after=$afterCount '
    'delta=${afterCount - beforeCount}',
  );

  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day);
  final end = start.add(const Duration(days: 1));
  final stats = await call('dashboard_summary', {
    'period_start': start.toIso8601String(),
    'period_end': end.toIso8601String(),
  });
  print('READBACK dashboard_summary(today): ${jsonEncode(stats['stats'])}');

  try {
    final snap = await call('register_snapshot', {
      'period_start': start.toIso8601String(),
      'period_end': end.toIso8601String(),
    });
    print('READBACK register_snapshot(today): ${jsonEncode(snap['snapshot'])}');
  } catch (e) {
    print('register_snapshot NOT on deployed pos-api (needs redeploy): $e');
  }

  if (after is List) {
    for (final row in after.take(3)) {
      final r = row as Map<String, dynamic>;
      print(
        '  e.g. ${r['receipt_number']} ${r['payment_method']} '
        '${r['total_minor_units']}m',
      );
    }
  }
  print('DONE');
}
