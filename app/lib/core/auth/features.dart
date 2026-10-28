import 'package:flutter/material.dart';

/// A single tickable feature-tab permission. Both application shells build
/// their navigation from [kFeatures] filtered by `User.can(key)`, so this
/// registry is the one place a destination becomes grant-able to a staff
/// account. Adding a tab here is enough to make it appear in the Add /
/// Edit-permissions checkbox grid and in the nav build filter.
class FeatureDef {
  final String key;
  final String label;
  final IconData icon;

  /// Owner-administered surface. Mirrors the server's OWNER_ONLY set, so it is
  /// absent from the tick grid and can never be held by a staff account — the
  /// finance tab is owner-only in the native repository and in pos-api.
  final bool ownerOnly;

  const FeatureDef(this.key, this.label, this.icon, {this.ownerOnly = false});
}

/// Ordered exactly as the navigation renders them. Settings is deliberately
/// absent: it is always visible so every account can reach logout / theme
/// regardless of its ticks. 'register_history' is no longer a nav tab — it
/// ticks the "Register History" button that lives inside the Register screen.
const List<FeatureDef> kFeatures = [
  FeatureDef('dashboard', 'Dashboard', Icons.dashboard),
  FeatureDef('pos', 'POS', Icons.shopping_cart),
  FeatureDef('register', 'Register', Icons.point_of_sale),
  FeatureDef(
    'finance',
    'Money Tracking',
    Icons.account_balance_wallet,
    ownerOnly: true,
  ),
  FeatureDef('reports', 'Reports', Icons.bar_chart),
  FeatureDef('users', 'Users', Icons.people),
  FeatureDef('audit', 'Audit Logs', Icons.security),
  FeatureDef('register_history', 'Register History', Icons.account_tree),
];

/// The features a brand-new staff account receives when the owner adds it
/// without ticking anything. Mirrors the historic CASHIER nav matrix (the
/// old History tab is gone; Reports keeps a cashier's sales visibility).
const List<String> kDefaultStaffPermissions = ['pos', 'register', 'reports'];

/// The subset of [kFeatures] the owner can hand to a staff account. Owner-only
/// surfaces are rendered top-level for the OWNER and never offered as a tick.
List<FeatureDef> get kGrantableFeatures =>
    kFeatures.where((f) => !f.ownerOnly).toList();

/// Owner accounts bypass the tick list entirely, so they store no permissions.
const List<String> kOwnerPermissions = <String>[];

/// True when [key] names a real feature. Used to reject crafted permission
/// lists at the repository boundary.
bool isValidFeatureKey(String key) => kFeatures.any((f) => f.key == key);

/// True when [key] may be granted to a staff account. Owner-only surfaces are
/// real features that a staff list must never contain.
bool isGrantableFeatureKey(String key) =>
    kFeatures.any((f) => f.key == key && !f.ownerOnly);

/// Keeps only grantable keys, drops duplicates, and preserves [kFeatures]
/// ordering so a stored list reads consistently everywhere.
List<String> normalizeFeatureKeys(Iterable<String> keys) {
  final seen = <String>{};
  for (final key in keys) {
    if (isGrantableFeatureKey(key)) seen.add(key);
  }
  return [
    for (final f in kFeatures)
      if (seen.contains(f.key)) f.key,
  ];
}
