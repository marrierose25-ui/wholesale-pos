import 'package:cupertino_ui/cupertino_ui.dart';

/// A single tickable feature-tab permission. Both application shells build
/// their navigation from [kFeatures] filtered by `User.can(key)`, so this
/// registry is the one place a destination becomes grant-able to a staff
/// account. Adding a tab here is enough to make it appear in the Add /
/// Edit-permissions checkbox grid and in the nav build filter.
class FeatureDef {
  final String key;
  final String label;
  final IconData icon;

  /// Surfaces no tick may ever grant. Empty today — Money Tracking used to be
  /// the one entry, and is now an ordinary tick — but kept so a future
  /// genuinely owner-only surface has a home that the tick grid already
  /// respects.
  final bool ownerOnly;

  const FeatureDef(this.key, this.label, this.icon, {this.ownerOnly = false});

  /// Warehouse Picklists (Digital Fulfillment). Named as a constant so the
  /// Dart nav filter, the cloud `pos-api` FEATURE_KEYS set, and any code that
  /// checks `User.can('warehouse')` agree on one spelling.
  ///
  /// Two separate jobs, two separate ticks: `warehouse` is the shop worker
  /// creating a list, `warehouseFill` is the warehouse worker pulling stock.
  /// The Warehouse tab appears when either is granted, and the screen renders
  /// only the job the account holds (the owner sees both, with a switch).
  static const String warehouse = 'warehouse';
  static const String warehouseFill = 'warehouse_fill';
}

/// Ordered exactly as the navigation renders them. Settings is deliberately
/// absent: it is always visible so every account can reach logout / theme
/// regardless of its ticks. 'register_history' is no longer a nav tab — it
/// ticks the "Register History" button that lives inside the Register screen.
const List<FeatureDef> kFeatures = [
  FeatureDef('dashboard', 'Dashboard', CupertinoIcons.square_grid_2x2),
  FeatureDef('pos', 'POS', CupertinoIcons.cart),
  FeatureDef('register', 'Register', CupertinoIcons.creditcard),
  // Tickable, but deliberately absent from [kDefaultStaffPermissions]: the
  // owner hands out this area one account at a time, never as a default.
  FeatureDef('finance', 'Money Tracking', CupertinoIcons.money_dollar_circle),
  // Independent fulfillment feature (Warehouse Picklists). Ticked per account
  // like any other staff surface; deliberately not a default, so an upgrade
  // never hands a cashier a tab they did not have before.
  FeatureDef(FeatureDef.warehouse, 'Warehouse', CupertinoIcons.cube_box),
  FeatureDef(
    FeatureDef.warehouseFill,
    'Warehouse Filling',
    CupertinoIcons.checkmark_rectangle,
  ),
  // Inventory foundation: stores + per-store product stock. One tickable
  // feature — the Inventory tab renders only when the account holds it.
  FeatureDef('inventory', 'Inventory', CupertinoIcons.cube),
  FeatureDef('reports', 'Reports', CupertinoIcons.chart_bar),
  FeatureDef('users', 'Users', CupertinoIcons.person_2),
  FeatureDef('audit', 'Audit Logs', CupertinoIcons.lock_shield),
  FeatureDef('register_history', 'Register History', CupertinoIcons.arrow_branch),
  FeatureDef('history', 'Sales History', CupertinoIcons.time),
];

/// The features a brand-new staff account receives when the owner adds it
/// without ticking anything. Mirrors the historic CASHIER nav matrix (the
/// old History tab is gone; Reports keeps a cashier's sales visibility).
const List<String> kDefaultStaffPermissions = ['pos', 'register', 'reports'];

/// The subset of [kFeatures] the owner can hand to a staff account. Today that
/// is every tab (Money Tracking included); an [FeatureDef.ownerOnly] surface
/// would be filtered out here and stay invisible to the tick grid.
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
