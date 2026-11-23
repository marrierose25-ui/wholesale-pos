// Pure permission registry shared by the application and the local engine.
//
// This file intentionally contains no `sqflite`/`dart:io` import: the storage
// bound `requireFeature` gate lives in the implementation package
// (`pos_local_engine`) next to the database it queries.
//
// The key order, defaults and normalisation are extracted verbatim from the
// pre-Stage-6 `app/lib/core/auth/features.dart` so stored permission lists and
// navigation order do not change.

/// All grantable feature keys, in the order the navigation renders them.
///
/// Settings is deliberately absent: it is always visible so every account can
/// reach logout / theme regardless of its ticks.
const List<String> kFeatureOrder = [
  'dashboard',
  'pos',
  'register',
  'finance',
  'warehouse',
  'warehouse_fill',
  'reports',
  'users',
  'audit',
  'register_history',
  'history',
];

/// The features a brand-new staff account receives when the owner adds it
/// without ticking anything. Mirrors the historic CASHIER nav matrix (the old
/// History tab is gone; Reports keeps a cashier's sales visibility).
const List<String> kDefaultStaffPermissions = ['pos', 'register', 'reports'];

/// Owner accounts bypass the tick list entirely, so they store no permissions.
const List<String> kOwnerPermissions = <String>[];

/// True when [key] names a real feature. Used to reject crafted permission
/// lists at the repository boundary.
bool isValidFeatureKey(String key) => kFeatureOrder.contains(key);

/// True when [key] may be granted to a staff account. No surface is
/// owner-only today, so every real key is grantable.
bool isGrantableFeatureKey(String key) => isValidFeatureKey(key);

/// Keeps only grantable keys, drops duplicates, and preserves registry
/// ordering so a stored list reads consistently everywhere.
List<String> normalizeFeatureKeys(Iterable<String> keys) {
  final seen = <String>{};
  for (final key in keys) {
    if (isGrantableFeatureKey(key)) seen.add(key);
  }
  return [
    for (final key in kFeatureOrder)
      if (seen.contains(key)) key,
  ];
}
