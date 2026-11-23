import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:pos_local_engine/pos_local_engine.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
  });
  tearDown(() async => db.close());

  group('DeviceFingerprint', () {
    test('returns the same value across repeated calls (idempotent)', () async {
      final a = await DeviceFingerprint.get(db);
      final b = await DeviceFingerprint.get(db);
      expect(a, b);
    });

    test('is 64 hex chars (SHA-256 output)', () async {
      final fp = await DeviceFingerprint.get(db);
      expect(fp.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(fp), isTrue);
    });

    test('forTesting() is stable per seed and distinct across seeds', () {
      expect(
        DeviceFingerprint.forTesting('a'),
        DeviceFingerprint.forTesting('a'),
      );
      expect(
        DeviceFingerprint.forTesting('a'),
        isNot(DeviceFingerprint.forTesting('b')),
      );
    });
  });
}
