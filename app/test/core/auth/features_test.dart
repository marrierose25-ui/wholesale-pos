import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/auth/features.dart';
import 'package:wholesale_pos_app/core/models/user.dart';

/// Mirrors how both shells build their navigation: the registry filtered by
/// `User.can(key)` with Settings always appended last (never tickable).
List<String> buildNavLabels(User user) => [
  for (final f in kFeatures)
    if (user.can(f.key)) f.label,
  'Settings',
];

User _staff(List<String> permissions) => User(
  id: 'u1',
  username: 'sam',
  passwordHash: 'h',
  salt: 's',
  role: 'CASHIER',
  permissions: permissions,
);

void main() {
  group('User.can', () {
    test('OWNER bypasses the tick list even with no permissions', () {
      final owner = User(
        id: 'o1',
        username: 'owner',
        passwordHash: 'h',
        salt: 's',
        role: 'OWNER',
      );
      for (final f in kFeatures) {
        expect(owner.can(f.key), isTrue, reason: f.key);
      }
    });

    test('staff is limited to the exact ticked set', () {
      final user = _staff(['pos', 'reports']);
      expect(user.can('pos'), isTrue);
      expect(user.can('reports'), isTrue);
      expect(user.can('users'), isFalse);
      expect(user.can('audit'), isFalse);
      // Unknown keys never resolve.
      expect(user.can('settings'), isFalse);
    });
  });

  group('feature-driven navigation (shell contract)', () {
    test('staff with {pos, register} sees exactly POS, Register, Settings', () {
      expect(buildNavLabels(_staff(['pos', 'register'])), [
        'POS',
        'Register',
        'Settings',
      ]);
    });

    test('all-ticked staff equals the owner nav', () {
      final all = _staff(kFeatures.map((f) => f.key).toList());
      final owner = User(
        id: 'o1',
        username: 'owner',
        passwordHash: 'h',
        salt: 's',
        role: 'OWNER',
      );
      expect(buildNavLabels(all), buildNavLabels(owner));
      expect(buildNavLabels(owner).length, kFeatures.length + 1);
    });

    test('Settings is always present, even with zero ticks', () {
      expect(buildNavLabels(_staff([])), ['Settings']);
    });
  });

  group('money tracking is a tick', () {
    test('the owner can grant it, and it renders the tab for that account', () {
      expect(isGrantableFeatureKey('finance'), isTrue);
      expect(normalizeFeatureKeys(['finance']), ['finance']);
      expect(buildNavLabels(_staff(['pos', 'finance'])), [
        'POS',
        'Money Tracking',
        'Settings',
      ]);
    });

    test('it is never granted by default', () {
      expect(kDefaultStaffPermissions, isNot(contains('finance')));
      expect(
        buildNavLabels(_staff(kDefaultStaffPermissions)),
        isNot(contains('Money Tracking')),
      );
    });

    test('taking the tick away removes the tab again', () {
      final granted = _staff(['pos', 'finance']);
      final revoked = User.fromMap(
        granted.toMap()..['permissions'] = jsonEncode(['pos']),
      );
      expect(granted.can('finance'), isTrue);
      expect(revoked.can('finance'), isFalse);
    });
  });

  group('normalizeFeatureKeys', () {
    test('drops unknown keys, dedupes, and preserves registry order', () {
      expect(
        normalizeFeatureKeys(['reports', 'pos', 'pos', 'settings', 'bogus']),
        ['pos', 'reports'],
      );
    });

    test('empty input yields an empty list', () {
      expect(normalizeFeatureKeys(const []), isEmpty);
    });
  });

  group('User.decodePermissions', () {
    test('null / empty / malformed all yield const []', () {
      expect(User.decodePermissions(null), isEmpty);
      expect(User.decodePermissions(''), isEmpty);
      expect(User.decodePermissions('not json'), isEmpty);
      expect(User.decodePermissions('{"a":1}'), isEmpty);
    });

    test('decodes a native JSON TEXT column', () {
      expect(User.decodePermissions(jsonEncode(['pos', 'register'])), [
        'pos',
        'register',
      ]);
    });

    test('passes a decoded cloud jsonb list through', () {
      expect(User.decodePermissions(['pos', 'audit']), ['pos', 'audit']);
    });
  });

  group('User map round-trip', () {
    test('toMap/fromMap carries permissions through the JSON column', () {
      final original = _staff(['finance', 'register_history']);
      final restored = User.fromMap(original.toMap());
      expect(restored.permissions, ['finance', 'register_history']);
      expect(restored.can('finance'), isTrue);
      expect(restored.can('pos'), isFalse);
    });

    test('fromMap tolerates a legacy row without the column', () {
      final map = _staff(['pos']).toMap()..remove('permissions');
      expect(User.fromMap(map).permissions, isEmpty);
    });
  });

  group('registry defaults', () {
    test('default staff set contains only valid feature keys', () {
      for (final key in kDefaultStaffPermissions) {
        expect(isValidFeatureKey(key), isTrue, reason: key);
      }
      expect(kDefaultStaffPermissions, ['pos', 'register', 'reports']);
    });

    test('owner stores no ticks', () {
      expect(kOwnerPermissions, isEmpty);
    });

    test('feature keys are unique', () {
      expect(kFeatures.map((f) => f.key).toSet().length, kFeatures.length);
    });
  });
}
