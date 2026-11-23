// LIVE, bidirectional sync matrix — the proof required before a release ships.
//
// Every other test in this suite is hermetic: fakes, in-memory pages, no wire.
// This one is the opposite. It runs the REAL native Dart code path (the same
// repositories, outbox, gateway backend and pull applier a till uses) against
// the REAL Supabase project, and reads the result back through the REAL web
// client surface (`pos-api`, which is exactly what the PWA calls). So one run
// covers all three platforms at once:
//
//   * "Windows"  = an in-memory SQLite till driven by Dart
//   * "Android"  = a second, independent in-memory SQLite till
//   * "Web"      = HTTP calls to `pos-api` with a PWA session token
//
// It is opt-in because it needs live credentials and it WRITES to the tenant:
// set the MATRIX_* environment variables and it runs; without them every test
// here is skipped, so `flutter test` stays offline-safe and CI stays green.
//
//   $env:MATRIX_CODE   = '<activation code>'
//   $env:MATRIX_USER   = '<owner phone>'
//   $env:MATRIX_PASS   = '<owner password>'
//   flutter test test/integration/sync_matrix_live_test.dart
//
// Optional overrides (the shipped URLs are the default):
//   MATRIX_LICENSE_URL / MATRIX_API_URL / MATRIX_SYNC_URL
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_core/pos_core.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_cloud_engine/pos_cloud_engine.dart';
import 'package:wholesale_pos_app/core/sync/sync_service.dart';

const _host = 'https://trcthxyyuapwavzeisvm.supabase.co/functions/v1';

/// 100.00 Br, in the minor units every money column in this app uses.
const _br100 = 10000;

/// A live run is bounded by the wire and by PBKDF2 (210k iterations per
/// password check), not by the code under test, so the default 30 s is far too
/// short to mean anything.
const _hopTimeout = Timeout(Duration(minutes: 8));

class _Config {
  const _Config({
    required this.licensingUrl,
    required this.apiUrl,
    required this.syncUrl,
    required this.code,
    required this.user,
    required this.password,
  });

  final String licensingUrl;
  final String apiUrl;
  final String syncUrl;
  final String code;
  final String user;
  final String password;

  /// Null when the credentials are absent — the whole group then skips, so a
  /// live run can never be mistaken for a passing offline suite.
  static _Config? fromEnvironment() {
    final env = Platform.environment;
    String read(String key, String fallback) {
      final value = (env[key] ?? '').trim();
      return value.isEmpty ? fallback : value;
    }

    final code = read('MATRIX_CODE', '');
    final user = read('MATRIX_USER', '');
    final password = read('MATRIX_PASS', '');
    if (code.isEmpty || user.isEmpty || password.isEmpty) return null;
    return _Config(
      licensingUrl: read('MATRIX_LICENSE_URL', '$_host/licensing'),
      apiUrl: read('MATRIX_API_URL', '$_host/pos-api'),
      syncUrl: read('MATRIX_SYNC_URL', '$_host/sync'),
      code: code,
      user: user,
      password: password,
    );
  }
}

/// One Edge Function endpoint. [_post] fails the test on any `ok:false`, so a
/// refusal is reported with the server's own words instead of a bare assert.
class _Endpoint {
  _Endpoint(this.url, this.client);

  final String url;
  final http.Client client;
  String? token;

  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic>? body,
  ]) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null) headers['Authorization'] = 'Bearer $token';
    final payload = jsonEncode(<String, dynamic>{'action': action, ...?body});
    // A flaky link or a cold Edge Function is not a sync bug, and every action
    // here is idempotent (a push re-stages by entity, the apply pass replays by
    // id), so the run retries the transport instead of reporting a false fail.
    http.Response? res;
    for (var attempt = 1; ; attempt++) {
      try {
        res = await client
            .post(Uri.parse(url), headers: headers, body: payload)
            .timeout(const Duration(seconds: 90));
        break;
      } on http.ClientException catch (e) {
        if (attempt >= 4) rethrow;
        print('RETRY  $action (attempt $attempt): ${e.message}');
        await Future<void>.delayed(Duration(seconds: attempt));
      } on TimeoutException {
        if (attempt >= 4) rethrow;
        print('RETRY  $action (attempt $attempt): timed out after 90 s');
      }
    }
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw StateError('$action returned non-JSON (HTTP ${res.statusCode})');
    }
    expect(
      json['ok'],
      isTrue,
      reason:
          '$action refused: HTTP ${res.statusCode} ${json['error']} '
          '(endpoint $url)',
    );
    return json;
  }
}

/// One register: its own SQLite file, its own device seat and license, its own
/// sync loop. Nothing is shared between two tills except the cloud, which is
/// the point of the matrix.
class _Till {
  _Till({
    required this.label,
    required this.db,
    required this.deviceId,
    required this.service,
    required this.outbox,
    required this.users,
    required this.products,
    required this.sales,
    required this.shifts,
    required this.finance,
    required this.client,
  });

  final String label;
  final Database db;
  final String deviceId;
  final SyncService service;
  final SyncOutboxRepository outbox;
  final UserRepository users;
  final ProductRepository products;
  final SaleRepository sales;
  final ShiftRepository shifts;
  final FinanceRepository finance;
  final http.Client client;

  /// One full cycle: push everything this till queued, then download what the
  /// cloud holds. Returns the row count the download wrote.
  ///
  /// Retried like the real loop does: a 3-second tick that fails leaves the
  /// rows queued and the next tick sends them, so one dropped connection is
  /// not a sync failure — three in a row is.
  Future<SyncResult> cycle() async {
    SyncResult? last;
    for (var attempt = 1; attempt <= 4; attempt++) {
      last = await service.syncNow(forcePull: true);
      if (last.ok) return last;
      if (attempt < 4) {
        print('RETRY  $label cycle (attempt $attempt): ${last.error}');
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
    return last!;
  }

  Future<Map<String, Object?>?> row(String table, String id) async {
    final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dispose() async {
    await db.close();
    client.close();
  }
}

void main() {
  final live = _Config.fromEnvironment();
  if (live == null) {
    // Keep the file honest about what it did NOT verify: an offline run skips,
    // it never reports a pass.
    test(
      'live sync matrix needs MATRIX_CODE / MATRIX_USER / MATRIX_PASS',
      () {},
      skip: 'no live credentials supplied',
    );
    return;
  }
  final config = live;
  final client = http.Client();
  // Two registers must not share one database. `openInMemory()` cannot be used
  // here: under the FFI engine every `:memory:` handle in the isolate is the
  // SAME database, so both tills would get one device id, one outbox and one
  // cursor — and the matrix would prove nothing about two machines.
  final scratch = Directory.systemTemp.createTempSync('sync_matrix_');
  late _Endpoint licensing;
  late _Endpoint api;
  late _Till windows;
  late _Till android;
  // Every till that actually opened, so a boot that fails half way through
  // still cleans up (and never masks the real error with a late-field error).
  final tills = <_Till>[];
  late String ownerId;

  /// A label unique to this run, so a rerun never collides with the rows the
  /// last one left in the tenant (names and phone numbers are unique).
  final tag = DateTime.now().millisecondsSinceEpoch.remainder(100000000);
  final runId = const Uuid().v4().substring(0, 8);

  Future<_Till> openTill(String label) async {
    // A per-platform seat on the shop's own activation code. The fingerprint is
    // stable per label, so reruns refresh a seat instead of piling up new ones.
    final license = await licensing.call('activate_device', {
      'activation_code': config.code,
      'device_fingerprint': 'matrix-$label-$runId',
      'device_name': 'Matrix $label',
    });
    final licenseCode = license['license_code'] as String;

    final dbDir = Directory('${scratch.path}/$label')
      ..createSync(recursive: true);
    final db = await LocalDatabase.openAt(
      '${dbDir.path}/${LocalDatabase.databaseName}',
    );
    await LocalDatabase.setSetting(
      db,
      SyncGatewayBackend.licenseSettingKey,
      licenseCode,
    );
    final deviceId = await LocalDatabase.registerCurrentDevice(db);
    final backend = SyncGatewayBackend(
      fnUrl: config.syncUrl,
      licenseProvider: () =>
          LocalDatabase.getSetting(db, SyncGatewayBackend.licenseSettingKey),
      client: client,
    );
    final outbox = SqfliteSyncOutboxRepository(db);
    final till = _Till(
      label: label,
      db: db,
      deviceId: deviceId,
      service: SyncService(
        outbox,
        backend,
        puller: CloudSyncPuller(backend: backend, db: db),
        pullInterval: SyncIntervals.cycle,
      ),
      outbox: outbox,
      users: SqfliteUserRepository(db),
      products: SqfliteProductRepository(db),
      sales: SqfliteSaleRepository(db),
      shifts: SqfliteShiftRepository(db),
      finance: SqfliteFinanceRepository(db),
      client: http.Client(),
    );
    tills.add(till);
    return till;
  }

  /// Pushes from [from], then has [to] download, and returns how long the whole
  /// hop took — the number the 3-second cadence is supposed to deliver.
  Future<Duration> hop(_Till from, _Till to) async {
    final sw = Stopwatch()..start();
    final pushed = await from.cycle();
    expect(
      pushed.error,
      isNull,
      reason: '${from.label} cycle failed: ${pushed.error}',
    );
    final arrived = await to.cycle();
    expect(
      arrived.error,
      isNull,
      reason: '${to.label} pull failed: ${arrived.error}',
    );
    sw.stop();
    return sw.elapsed;
  }

  group('live sync matrix (Windows / Android / Web)', () {
    setUpAll(() async {
      final sw = Stopwatch()..start();
      licensing = _Endpoint(config.licensingUrl, client);
      api = _Endpoint(config.apiUrl, client);

      final login = await api.call('login', {
        'activation_code': config.code,
        'username': config.user,
        'password': config.password,
      });
      api.token = login['token'] as String;
      ownerId = login['user_id'] as String;
      print('WEB    signed in as ${login['role']} $ownerId');

      windows = await openTill('windows');
      android = await openTill('android');
      // Bootstrapping a till is the "join the shop" path: the first pull is
      // what puts the owner account in local SQLite so the register can sign
      // in and sell at all.
      for (final till in [windows, android]) {
        final result = await till.cycle();
        expect(
          result.error,
          isNull,
          reason: '${till.label} bootstrap failed: ${result.error}',
        );
        print(
          'TILL   ${till.label}: device ${till.deviceId}, '
          'pulled ${result.applied} cloud rows',
        );
      }
      expect(
        await windows.db.query(
          'users',
          where: "role = 'OWNER' AND is_active = 1",
        ),
        isNotEmpty,
        reason: 'the owner account must reach a till from the cloud',
      );
      print('BOOT   ready in ${sw.elapsedMilliseconds} ms');
    });

    tearDownAll(() async {
      for (final till in tills) {
        await till.dispose();
      }
      client.close();
      try {
        scratch.deleteSync(recursive: true);
      } catch (_) {
        // Windows can hold the sqlite handle open for a moment after close;
        // the folder lives in %TEMP% and is not worth failing the run over.
      }
    });

    test('A: a cashier created on Windows reaches Web and Android', () async {
      final phone = '09${tag.toString().padLeft(8, '0')}';
      const password = 'matrix-cashier-1';

      await windows.users.createUser(
        phone,
        password,
        'CASHIER',
        permissions: const ['pos'],
      );
      final elapsed = await hop(windows, android);

      // WEB: the browser's Users screen reads pos_users through pos-api.
      final cloud = (await api.call('list_users'))['users'] as List;
      final onWeb = cloud.where((u) => u['username'] == phone).toList();
      expect(
        onWeb,
        hasLength(1),
        reason:
            'the cashier must appear on the PWA in ${elapsed.inMilliseconds} ms',
      );
      expect(onWeb.first['role'], 'CASHIER');
      expect(onWeb.first['active'], isTrue);

      // ANDROID: the same account on the other register, same id, same ticks.
      final onAndroid = (await android.users.getAllUsers())
          .where((u) => u.username == phone)
          .toList();
      expect(onAndroid, hasLength(1));
      expect(onAndroid.single.id, onWeb.first['id']);
      expect(onAndroid.single.role, 'CASHIER');
      expect(onAndroid.single.permissions, contains('pos'));
      // The credential travels with the row, so the cashier can sign in on a
      // register that never created them.
      expect(
        await android.users.authenticate(phone, password),
        isNotNull,
        reason: 'the cloud credential must verify on another till',
      );

      print(
        'PASS A user Windows -> Web + Android in ${elapsed.inMilliseconds} ms',
      );
    }, timeout: _hopTimeout);

    test('B: a product created on Web reaches Windows and Android', () async {
      final name = 'Matrix Sugar $tag kg';
      final created = await api.call('save_product', {
        'product': {
          'name': name,
          'code': 'MTX$tag',
          'category': 'grocery',
          'unit': 'bag',
          'selling_price_minor_units': 250000,
        },
      });
      final productId = created['id'] as String;

      final sw = Stopwatch()..start();
      final onWindows = await windows.cycle();
      expect(onWindows.error, isNull, reason: onWindows.error);
      final onAndroid = await android.cycle();
      expect(onAndroid.error, isNull, reason: onAndroid.error);
      sw.stop();

      for (final till in [windows, android]) {
        final landed = await till.products.getById(productId);
        expect(
          landed,
          isA<Product>(),
          reason: '${till.label} must hold the saved name the browser created',
        );
        expect(landed!.name, name);
        expect(landed.sellingPriceMinorUnits, 250000);
        expect(landed.isActive, isTrue);
      }
      print(
        'PASS B product Web -> Windows + Android in '
        '${sw.elapsedMilliseconds} ms',
      );
    }, timeout: _hopTimeout);

    test('C: a sale opened and rung on Android reaches Web, and a Windows void '
        'reaches Android', () async {
      final shift = await android.shifts.ensureActiveShift(ownerId);
      final saleId = const Uuid().v4();
      final receipt = await android.sales.nextReceiptNumber();
      await android.sales.saveSale(
        Sale(
          id: saleId,
          receiptNumber: receipt,
          cashierId: ownerId,
          deviceId: android.deviceId,
          shiftId: shift.id,
          subtotalMinorUnits: _br100,
          discountMinorUnits: 0,
          totalMinorUnits: _br100,
          amountPaidMinorUnits: _br100,
          changeMinorUnits: 0,
          createdAt: DateTime.now(),
          items: [
            SaleItem(
              id: const Uuid().v4(),
              saleId: saleId,
              productId: 'matrix-harness',
              productNameSnapshot: 'Matrix Teff',
              unitPriceSnapshotMinorUnits: _br100,
              quantityText: '1 kg',
              billingQuantityMilliunits: 1000,
              lineTotalMinorUnits: _br100,
            ),
          ],
        ),
      );

      // ANDROID -> WEB. The dashboard reads the cloud's own aggregates, so a
      // sale that only staged in the mirror would not show up here.
      final toWeb = await hop(android, windows);
      final cloudSale = _findById(
        (await api.call('search_sales', {'limit': 1000}))['sales'] as List,
        saleId,
      );
      expect(
        cloudSale,
        isNotNull,
        reason:
            'the native sale must be on the PWA in ${toWeb.inMilliseconds} ms',
      );
      expect(cloudSale!['status'], 'COMPLETED');
      // The money is re-derived server-side; a device cannot dictate totals.
      expect(cloudSale['total_minor_units'], _br100);
      expect(cloudSale['payment_method'], 'CASH');

      final today = DateTime.now();
      final snapshot =
          (await api.call('register_snapshot', {
                'period_start': DateTime(
                  today.year,
                  today.month,
                  today.day,
                ).toIso8601String(),
                'period_end': DateTime(
                  today.year,
                  today.month,
                  today.day,
                ).add(const Duration(days: 1)).toIso8601String(),
              }))['snapshot']
              as Map<String, dynamic>;
      expect(
        (snapshot['today_cash_sales'] as num).toInt(),
        greaterThanOrEqualTo(_br100),
        reason: 'the register total must include the native sale: $snapshot',
      );

      // ANDROID -> WINDOWS: the till that never saw the transaction.
      final onWindows = await windows.row('sales', saleId);
      expect(
        onWindows,
        isNotNull,
        reason: 'the other register must have pulled the sale',
      );
      expect(onWindows!['status'], 'COMPLETED');
      expect(onWindows['total_minor_units'], _br100);
      expect(
        await windows.db.query(
          'sale_items',
          where: 'sale_id = ?',
          whereArgs: [saleId],
        ),
        hasLength(1),
        reason: 'a header without its lines is not a sale',
      );

      // WINDOWS -> ANDROID + WEB: the void is a state transition, so it cannot
      // ride the ledger replay; the gateway applies it through pos_void_sale.
      await windows.sales.voidSale(saleId, ownerId, 'Matrix C: wrong item');
      final toAndroid = await hop(windows, android);

      final voidedOnWeb = _findById(
        (await api.call('search_sales', {'limit': 1000}))['sales'] as List,
        saleId,
      );
      expect(
        voidedOnWeb!['status'],
        'VOIDED',
        reason: 'the PWA must show the void the desktop decided',
      );
      expect(voidedOnWeb['voided_by'], ownerId);

      final voidedOnAndroid = await android.row('sales', saleId);
      expect(
        voidedOnAndroid!['status'],
        'VOIDED',
        reason:
            'the till that rang it must show the void in '
            '${toAndroid.inMilliseconds} ms',
      );
      expect(voidedOnAndroid['void_reason'], 'Matrix C: wrong item');

      print(
        'PASS C sale Android -> Web + Windows in ${toWeb.inMilliseconds} ms, '
        'void Windows -> Android + Web in ${toAndroid.inMilliseconds} ms',
      );
    }, timeout: _hopTimeout);

    test('D: finance category (Windows), entry (Web), completion (Android) all '
        'converge', () async {
      final person = 'Matrix Person $tag';
      final category = await windows.finance.createCategory(
        ownerId: ownerId,
        name: person,
      );
      final toWeb = await hop(windows, android);

      expect(
        await android.db.query(
          'finance_categories',
          where: 'id = ?',
          whereArgs: [category.id],
        ),
        hasLength(1),
        reason: 'the person created on the desktop must exist on the phone',
      );
      final cloudCategories =
          (await api.call('finance_categories'))['categories'] as List;
      expect(
        _findById(cloudCategories, category.id),
        isNotNull,
        reason: 'the person must be on the PWA in ${toWeb.inMilliseconds} ms',
      );

      // The browser records a pending CASH collection against that person.
      final entry =
          (await api.call('finance_add_entry', {
                'category_id': category.id,
                'source': 'Matrix D collection',
                'amount_minor_units': _br100,
                'payment_method': 'CASH',
              }))['entry']
              as Map<String, dynamic>;
      final entryId = entry['id'] as String;
      expect(entry['status'], 'PENDING');

      // Nothing to push from a browser (it writes the cloud directly), so this
      // half of the hop is timed on the download alone.
      final webHop = Stopwatch()..start();
      final ontoAndroid = await android.cycle();
      expect(ontoAndroid.error, isNull, reason: ontoAndroid.error);
      webHop.stop();
      final toAndroid = webHop.elapsed;
      final pendingOnAndroid = await android.row('finance_entries', entryId);
      expect(
        pendingOnAndroid,
        isNotNull,
        reason: 'the entry created in the browser must reach the phone',
      );
      expect(pendingOnAndroid!['status'], 'PENDING');
      expect(pendingOnAndroid['payment_method'], 'CASH');

      // The phone takes the money: completing a CASH collection also deposits
      // it into the open register, which is a cash movement, not just a flag.
      await android.finance.markCompleted(ownerId: ownerId, entryId: entryId);
      // The id the phone booked the money under. It has to survive the round
      // trip: when the gateway minted its own uuid, the till kept UUID-1, the
      // pull added UUID-2 and the register paid one collection twice while the
      // browser — which only ever saw the cloud's single row — showed it once.
      final paidOnAndroid = await android.db.query(
        'cash_movements',
        where: 'source_finance_entry_id = ?',
        whereArgs: [entryId],
      );
      expect(
        paidOnAndroid,
        hasLength(1),
        reason: 'the phone pays one collection exactly once',
      );
      final movementId = paidOnAndroid.single['id'] as String;
      expect(paidOnAndroid.single['amount_minor_units'], _br100);

      final toWeb2 = await hop(android, windows);

      final completedOnWeb = _findById(
        (await api.call('finance_search_entries', {'limit': 500}))['entries']
            as List,
        entryId,
      );
      expect(completedOnWeb!['status'], 'COMPLETED');
      expect(completedOnWeb['completed_by'], ownerId);

      final snapshot =
          (await api.call('register_snapshot', {
                'period_start': DateTime.now()
                    .subtract(const Duration(hours: 12))
                    .toIso8601String(),
                'period_end': DateTime.now()
                    .add(const Duration(days: 1))
                    .toIso8601String(),
              }))['snapshot']
              as Map<String, dynamic>;
      expect(
        (snapshot['today_deposits'] as num).toInt(),
        greaterThanOrEqualTo(_br100),
        reason: 'the PWA register must show the deposit: $snapshot',
      );

      final onWindows = await windows.row('finance_entries', entryId);
      expect(
        onWindows!['status'],
        'COMPLETED',
        reason:
            'the desktop must see the phone took the money in '
            '${toWeb2.inMilliseconds} ms',
      );

      // Native/PWA parity, measured on the money rather than on a flag: the
      // browser's own ledger must hold ONE row for this collection, and it must
      // be the phone's row by id and by amount.
      final cloudMovements =
          (await api.call('list_cash_movements', {'limit': 500}))['movements']
              as List;
      final paidInCloud = cloudMovements
          .where((m) => (m as Map)['source_finance_entry_id'] == entryId)
          .toList();
      expect(
        paidInCloud,
        hasLength(1),
        reason: 'the PWA paid this collection once, not twice',
      );
      expect(
        (paidInCloud.single as Map)['id'],
        movementId,
        reason: 'the cloud adopted the id the cashier was already shown',
      );
      expect((paidInCloud.single as Map)['amount_minor_units'], _br100);

      final paidOnWindows = await windows.db.query(
        'cash_movements',
        where: 'source_finance_entry_id = ?',
        whereArgs: [entryId],
      );
      expect(
        paidOnWindows,
        hasLength(1),
        reason: 'the desktop pulled one copy of the phone money',
      );
      expect(
        paidOnWindows.single['id'],
        movementId,
        reason: 'same row, same id, on every surface',
      );

      print(
        'PASS D finance: Windows->Android+Web ${toWeb.inMilliseconds} ms, '
        'Web->Android ${toAndroid.inMilliseconds} ms, '
        'Android->Windows ${toWeb2.inMilliseconds} ms',
      );
    }, timeout: _hopTimeout);

    test('nothing is left queued on either register', () async {
      for (final till in [windows, android]) {
        final result = await till.cycle();
        expect(result.error, isNull, reason: '${till.label}: ${result.error}');
        expect(
          await till.outbox.pendingCount(),
          0,
          reason:
              '${till.label} still has unsent rows — the cloud refused '
              'something, which is exactly the bug class this matrix exists to '
              'catch',
        );
      }
      print('PASS E both outboxes drained, nothing rejected in the mirror');
    }, timeout: _hopTimeout);
  });
}

Map<String, dynamic>? _findById(List rows, String id) {
  for (final row in rows.whereType<Map<String, dynamic>>()) {
    if (row['id'] == id) return row;
  }
  return null;
}
