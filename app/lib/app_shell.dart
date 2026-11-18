import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'core/auth/features.dart';
import 'core/auth/session_store.dart';
import 'core/backend/app_backend.dart';
import 'core/models/user.dart';
import 'core/theme/app_design.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/app_logger.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/finance/finance_overview_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/register/register_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/sales/sale.dart';
import 'features/sales/sale_item.dart';
import 'features/sales/sales_screen.dart';
import 'features/users/user_management_screen.dart';
import 'features/audit/audit_log_screen.dart';
import 'features/warehouse/warehouse_screen.dart';

/// The adaptive, storage-agnostic application shell shared by the native and
/// web builds. It owns only theming + the auth gate + the navigation layout;
/// every data read/write goes through the [AppBackend] seam, and the
/// platform-specific Settings / activation screens are supplied by that seam so
/// nothing here imports a `dart:io`-coupled widget.
///
/// The native entry (`main.dart`) wraps this in its device-license gate before
/// handing it a [NativeBackend]; the web entry (`main_web.dart`) hands it a
/// [CloudBackend] directly (its activation code is captured by the seam's
/// [AppBackend.buildActivationGate]).
/// Dev-only sample-data seeder. When the app is launched with
/// `--dart-define=SEED_SALES=<n>`, the signed-in shell creates `n` one-item
/// sales through the normal [AppBackend.sales] save path (cloud `insert_sale`
/// on web, SQLite on native) so the dashboard / register / history can be
/// eyeballed with real rows. Default 0 => completely inert in normal builds.
const int _devSeedSales = int.fromEnvironment('SEED_SALES', defaultValue: 0);
bool _devSeedStarted = false;

const List<({String name, String unit, int unitPriceMinor})> _devSeedProducts =
    [
      (name: 'Teff (Berbere) 1kg', unit: 'kg', unitPriceMinor: 12000),
      (name: 'Wheat Flour Bag 25kg', unit: 'bag', unitPriceMinor: 550000),
      (name: 'Cooking Oil 5L', unit: 'bottle', unitPriceMinor: 980000),
      (name: 'Sugar 1kg', unit: 'kg', unitPriceMinor: 11000),
      (name: 'Rice 5kg', unit: 'pack', unitPriceMinor: 1450000),
      (name: 'Salt 1kg', unit: 'kg', unitPriceMinor: 4500),
      (name: 'Pasta 500g', unit: 'pack', unitPriceMinor: 78000),
      (name: 'Tomato Paste Tin', unit: 'tin', unitPriceMinor: 65000),
    ];

class PosRoot extends StatefulWidget {
  final AppBackend backend;
  final bool initialDarkMode;

  const PosRoot({
    super.key,
    required this.backend,
    required this.initialDarkMode,
  });

  @override
  State<PosRoot> createState() => _PosRootState();
}

class _PosRootState extends State<PosRoot> {
  late ThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.initialDarkMode ? ThemeMode.dark : ThemeMode.light;
  }

  Future<void> _toggleTheme(bool isDark) async {
    setState(() => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light);
    // Await the write so the choice persists even if the app closes instantly.
    await widget.backend.setSetting(
      AppBackend.themeSettingKey,
      isDark ? 'dark' : 'light',
    );
  }

  @override
  Widget build(BuildContext context) {
    // Point the shared design tokens at the palette matching the active
    // brightness BEFORE building the tree, so every `AppDesign.xxx` colour the
    // screens read resolves to the right theme this frame.
    AppDesign.setMode(
      _themeMode == ThemeMode.light ? Brightness.light : Brightness.dark,
    );
    return MaterialApp(
      title: 'Wholesale POS',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      home: AuthGate(
        backend: widget.backend,
        isDarkMode: _themeMode == ThemeMode.dark,
        onToggleTheme: () => _toggleTheme(_themeMode == ThemeMode.light),
      ),
    );
  }
}

/// Decides between the activation step (web only), the login screen, and the
/// signed-in shell, and owns the "stay signed in" resume.
class AuthGate extends StatefulWidget {
  final AppBackend backend;
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const AuthGate({
    super.key,
    required this.backend,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  User? _currentUser;
  bool _restoring = true;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  /// On launch, resume the previous sign-in unless the user explicitly opted
  /// OUT (a stored '0'). Persistent sign-in is ON by default so a till that is
  /// simply closed and reopened does not demand the password again. A successful
  /// resume slides the session window forward.
  ///
  /// The whole resume is guarded: the `getById` check is a live `pos-api` call,
  /// so an expired/invalid session, a revoked account, or a flaky/offline
  /// network would otherwise throw out of this async body BEFORE `_restoring`
  /// is cleared — leaving the app stuck on an infinite loading spinner after a
  /// reopen. Any failure (or a hang, via the timeout) falls through to the
  /// login screen instead. The persisted session is left intact so a later
  /// launch can retry; a successful login overwrites it with a fresh token.
  Future<void> _restoreSession() async {
    User? restored;
    try {
      final remember = await widget.backend.getSetting(
        SessionStore.rememberKey,
      );
      if (remember != '0') {
        final session = await widget.backend.session.load();
        if (session != null) {
          restored = await widget.backend.users
              .getById(session.userId)
              .timeout(const Duration(seconds: 12));
          if (restored != null) {
            await widget.backend.session.save(
              SessionData.create(
                restored.id,
                lifetime: SessionStore.defaultLifetime,
              ),
            );
          }
        }
      }
    } catch (_) {
      restored = null;
    }
    if (!mounted) return;
    setState(() {
      _currentUser = restored;
      _restoring = false;
    });
  }

  Future<void> _onLoginSuccess(User user) async {
    setState(() => _currentUser = user);
    final remember = await widget.backend.getSetting(SessionStore.rememberKey);
    if (remember != '0') {
      await widget.backend.session.save(
        SessionData.create(user.id, lifetime: SessionStore.defaultLifetime),
      );
    } else {
      // Remember-off: never leave a stale session that could auto-resume.
      await widget.backend.session.clear();
    }
  }

  Future<void> _onLogout() async {
    await widget.backend.session.clear();
    if (!mounted) return;
    setState(() => _currentUser = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_restoring) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // Web must capture the shop's activation code (its tenant identity) before
    // any login attempt; native tills are already licensed when we get here.
    if (!widget.backend.isProvisioned) {
      return widget.backend.buildActivationGate(onReady: () => setState(() {}));
    }
    if (_currentUser == null) {
      return LoginScreen(
        userRepository: widget.backend.users,
        onLoginSuccess: _onLoginSuccess,
      );
    }

    return MainScaffold(
      backend: widget.backend,
      currentUser: _currentUser!,
      onLogout: _onLogout,
      isDarkMode: widget.isDarkMode,
      onToggleTheme: widget.onToggleTheme,
    );
  }
}

/// The signed-in navigation shell: an adaptive sidebar (wide) / drawer + pill
/// (phone) hosting every screen. Screens take repositories from the seam, so
/// this widget is identical for SQLite and cloud data.
class MainScaffold extends StatefulWidget {
  final AppBackend backend;
  final User currentUser;
  final VoidCallback onLogout;
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const MainScaffold({
    super.key,
    required this.backend,
    required this.currentUser,
    required this.onLogout,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold>
    with SingleTickerProviderStateMixin {
  int _selectedIndex = 0;

  /// Feature key at each nav position, rebuilt every frame from the account's
  /// ticks. Lets tab-change / sale-complete handlers resolve the current screen
  /// without hard-coded indexes (the visible set differs per account).
  List<String> _navFeatureKeys = const [];

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<RegisterScreenState> _registerKey =
      GlobalKey<RegisterScreenState>();
  final GlobalKey<DashboardScreenState> _dashboardKey =
      GlobalKey<DashboardScreenState>();
  final GlobalKey<ReportsScreenState> _reportsKey =
      GlobalKey<ReportsScreenState>();
  final GlobalKey<SalesScreenState> _salesKey = GlobalKey<SalesScreenState>();
  final GlobalKey<FinanceOverviewScreenState> _financeKey =
      GlobalKey<FinanceOverviewScreenState>();

  /// Warehouse tab handle. Only mounted when the seam supplies a repository
  /// (native); the browser build leaves it null, so this GlobalKey's
  /// currentState is always null there and every hook below is a no-op.
  final GlobalKey<WarehouseScreenState> _warehouseKey =
      GlobalKey<WarehouseScreenState>();

  /// Drives the quick fade-in that plays whenever a tab becomes visible.
  late final AnimationController _tabFadeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );
  final Curve _tabFadeCurve = Curves.easeOut;

  @override
  void dispose() {
    _tabFadeController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _maybeRunDevSeed();
  }

  void _maybeRunDevSeed() {
    if (_devSeedSales <= 0 || _devSeedStarted) return;
    _devSeedStarted = true;
    unawaited(_runDevSeed(_devSeedSales));
  }

  /// Creates [count] one-item sales via the backend's normal save path so the
  /// redesigned screens can be tested with real data. Best-effort: any failure
  /// (offline, unauthenticated) is logged and swallowed, never crash the shell.
  Future<void> _runDevSeed(int count) async {
    const uid = Uuid();
    try {
      final shift = await widget.backend.shifts.ensureActiveShift(
        widget.currentUser.id,
        userId: widget.currentUser.id,
      );
      var done = 0;
      for (var i = 0; i < count; i++) {
        final p = _devSeedProducts[i % _devSeedProducts.length];
        final qtyMilli = (1 + (i % 4)) * 1000; // 1..4 whole units
        final lineTotal = (p.unitPriceMinor * qtyMilli / 1000).round();
        final saleId = uid.v4();
        final receipt = await widget.backend.sales.nextReceiptNumber(
          userId: widget.currentUser.id,
        );
        final item = SaleItem(
          id: uid.v4(),
          saleId: saleId,
          productId: 'dev-seed',
          productNameSnapshot: p.name,
          unitPriceSnapshotMinorUnits: p.unitPriceMinor,
          quantityText: '${qtyMilli ~/ 1000} ${p.unit}',
          billingQuantityMilliunits: qtyMilli,
          lineDiscountMinorUnits: 0,
          lineTotalMinorUnits: lineTotal,
        );
        final sale = Sale(
          id: saleId,
          receiptNumber: receipt,
          cashierId: widget.currentUser.id,
          deviceId: widget.backend.deviceId,
          shiftId: shift.id,
          paymentMethod: i % 3 == 0 ? 'BANK' : 'CASH',
          subtotalMinorUnits: lineTotal,
          discountMinorUnits: 0,
          totalMinorUnits: lineTotal,
          amountPaidMinorUnits: lineTotal,
          changeMinorUnits: 0,
          createdAt: DateTime.now(),
          items: [item],
        );
        await widget.backend.sales.saveSale(sale);
        done++;
      }
      AppLogger.info('[dev-seed] created $done/$count sample sales');
      if (mounted) _refreshDataScreens();
    } catch (e) {
      AppLogger.warn('[dev-seed] aborted: $e');
    }
  }

  /// Silent background refreshes so every data screen shows the latest
  /// figures the moment it is looked at — no manual refresh needed. Each loader
  /// is guarded by its GlobalKey, so a screen the account can't open (null
  /// currentState) is simply skipped.
  void _refreshDataScreens() {
    _dashboardKey.currentState?.loadDashboard(silent: true);
    _salesKey.currentState?.loadShift();
    _registerKey.currentState?.loadData(silent: true);
    _financeKey.currentState?.load(silent: true);
    _warehouseKey.currentState?.refresh(silent: true);
    _reportsKey.currentState?.loadReports();
  }

  /// Reloads the screen at a nav position, resolved through the current
  /// feature-key mapping. Unknown / unmounted positions are ignored.
  void _loadScreen(int index, {bool silent = false}) {
    if (index < 0 || index >= _navFeatureKeys.length) return;
    switch (_navFeatureKeys[index]) {
      case 'dashboard':
        _dashboardKey.currentState?.loadDashboard(silent: silent);
      case 'pos':
        _salesKey.currentState?.loadShift();
      case 'register':
        _registerKey.currentState?.loadData(silent: silent);
      case 'finance':
        _financeKey.currentState?.load(silent: silent);
      case 'warehouse':
        _warehouseKey.currentState?.refresh(silent: silent);
      case 'reports':
        _reportsKey.currentState?.loadReports();
    }
  }

  /// Single funnel for every tab change: switch, then silently re-pull that
  /// screen's data so it is never stale when landed on.
  void _selectTab(int index) {
    setState(() => _selectedIndex = index);
    _loadScreen(index, silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final backend = widget.backend;
    final user = widget.currentUser;

    // Completing a sale refreshes every data screen and lands the shell on the
    // Register tab when this account has it. The index is resolved through the
    // live feature mapping at call time, so it stays correct however the
    // visible tabs are ticked out for the signed-in account.
    void onSaleCompleted() {
      _refreshDataScreens();
      final registerIndex = _navFeatureKeys.indexOf('register');
      if (registerIndex >= 0) _selectTab(registerIndex);
    }

    final salesScreen = SalesScreen(
      key: _salesKey,
      saleRepository: backend.sales,
      shiftRepository: backend.shifts,
      deviceId: backend.deviceId,
      currentUser: user,
      onSaleCompleted: onSaleCompleted,
    );
    final registerScreen = RegisterScreen(
      key: _registerKey,
      onShiftUpdated: _refreshDataScreens,
      currentUser: user,
      shiftRepository: backend.shifts,
      saleRepository: backend.sales,
    );
    final settingsScreen = backend.settingsScreen(
      currentUser: user,
      onLogout: widget.onLogout,
      isDarkMode: widget.isDarkMode,
      onToggleTheme: widget.onToggleTheme,
    );

    // One destination per feature the account is ticked for, in registry order.
    // Owner bypasses the ticks (User.can returns true for everything). Settings
    // is always appended last so every account can log out / change theme.
    final entries = <_ShellDestination>[];
    void add(String key, Widget screen) {
      if (!user.can(key)) return;
      final def = kFeatures.firstWhere((f) => f.key == key);
      entries.add(_ShellDestination(key, def.label, def.icon, screen));
    }

    add(
      'dashboard',
      DashboardScreen(
        key: _dashboardKey,
        saleRepository: backend.sales,
        currentUser: user,
      ),
    );
    add('pos', salesScreen);
    add('register', registerScreen);
    add(
      'finance',
      FinanceOverviewScreen(
        key: _financeKey,
        financeRepository: backend.finance,
        currentUser: user,
      ),
    );
    // Warehouse Picklists. Only rendered when the backend seam exposes a
    // repository. The tab is shown when the account holds either warehouse
    // tick (create or fill); the screen itself renders only the job that
    // account is allowed to do.
    final picklists = backend.picklists;
    if (picklists != null &&
        (user.can(FeatureDef.warehouse) ||
            user.can(FeatureDef.warehouseFill))) {
      final def = kFeatures.firstWhere((f) => f.key == FeatureDef.warehouse);
      entries.add(
        _ShellDestination(
          FeatureDef.warehouse,
          def.label,
          def.icon,
          WarehouseScreen(
            key: _warehouseKey,
            repository: picklists,
            currentUser: user,
          ),
        ),
      );
    }
    add(
      'reports',
      ReportsScreen(
        key: _reportsKey,
        saleRepository: backend.sales,
        currentUser: user,
      ),
    );
    add(
      'users',
      UserManagementScreen(userRepository: backend.users, currentUser: user),
    );
    add(
      'audit',
      AuditLogScreen(saleRepository: backend.sales, currentUser: user),
    );
    // Settings is always visible regardless of ticks (logout / theme).
    entries.add(
      _ShellDestination(
        'settings',
        'Settings',
        CupertinoIcons.gear,
        settingsScreen,
      ),
    );

    _navFeatureKeys = [for (final e in entries) e.key];
    final screens = [for (final e in entries) e.screen];
    if (_selectedIndex >= screens.length) _selectedIndex = 0;
    final settingsIndex = screens.length - 1;

    final allNavItems = [
      for (var i = 0; i < entries.length; i++)
        _NavItem(i, entries[i].icon, entries[i].label),
    ];
    // The first [pillCount] destinations lead the bottom pill; the rest live in
    // the hamburger drawer. At most 5, but never more than the visible count.
    final pillCount = entries.length < 5 ? entries.length : 5;
    final pillItems = allNavItems.take(pillCount).toList();
    final drawerItems = allNavItems.skip(pillCount).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 600;
        if (isCompact) {
          final title = allNavItems
              .firstWhere(
                (i) => i.index == _selectedIndex,
                orElse: () =>
                    _NavItem(settingsIndex, CupertinoIcons.gear, 'Settings'),
              )
              .label;
          return Scaffold(
            key: _scaffoldKey,
            backgroundColor: AppDesign.bg,
            extendBody: false,
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(CupertinoIcons.line_horizontal_3),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
              title: Text(title),
            ),
            drawer: _buildDrawer(context, drawerItems),
            body: _tabSwitcher(screens),
            bottomNavigationBar: _mobilePillNav(pillItems),
          );
        }

        // Linear sidebar: 220–240px, white surface, #E5E7EB hairline divider.
        final sidebarWidth = constraints.maxWidth < 900 ? 220.0 : 240.0;
        return Scaffold(
          body: Row(
            children: [
              Container(
                width: sidebarWidth,
                decoration: BoxDecoration(color: AppDesign.bgElevated),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Row(
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: AppDesign.blue,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Center(
                              child: Text(
                                'W',
                                style: TextStyle(
                                  color: AppDesign.onBlue,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              'Wholesale POS',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                letterSpacing: -0.3,
                                color: AppDesign.textHi,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          for (final it in allNavItems)
                            _buildNavItem(it.index, it.icon, it.label),
                        ],
                      ),
                    ),
                    Divider(
                      color: AppDesign.stroke,
                      thickness: 1,
                    ),
                    InkWell(
                      onTap: () => _selectTab(settingsIndex),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppDesign.blue,
                              ),
                              child: Center(
                                child: _AvatarContent(
                                  identity: widget.currentUser.username,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.currentUser.username,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12.5,
                                      color: AppDesign.textHi,
                                    ),
                                  ),
                                  Text(
                                    widget.currentUser.role,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: AppDesign.textLo,
                                      fontFamily: AppDesign.fontData,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              CupertinoIcons.gear,
                              size: 16,
                              color: AppDesign.textLo,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _tabSwitcher(screens)),
            ],
          ),
        );
      },
    );
  }

  /// Fades each tab in as it becomes visible. Deliberately NOT an
  /// AnimatedSwitcher: that keeps the old and new subtree alive at once, and
  /// both would mount the same GlobalKeys ("Multiple widgets used the same
  /// GlobalKey"). A single IndexedStack + fade keeps every screen mounted
  /// exactly once while still feeling smooth.
  Widget _tabSwitcher(List<Widget> screens) {
    return _TabFadeTransition(
      controller: _tabFadeController,
      curve: _tabFadeCurve,
      child: KeyedSubtree(
        key: ValueKey(_selectedIndex),
        child: IndexedStack(index: _selectedIndex, children: screens),
      ),
    );
  }

  /// Floating frosted-glass pill bottom nav for phones. Renders exactly the
  /// role's primary destinations; everything else lives behind the app-bar
  /// menu icon that opens the drawer.
  Widget _mobilePillNav(List<_NavItem> items) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Container(
          height: 62,
          decoration: BoxDecoration(
            color: AppDesign.bgElevated,
            borderRadius: BorderRadius.circular(AppDesign.radiusPill),
            border: Border.all(
              color: AppDesign.stroke.withValues(alpha: 0.3),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              for (final it in items) Expanded(child: _pillItem(it)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pillItem(_NavItem it) {
    final sel = _selectedIndex == it.index;
    return InkWell(
      onTap: () => _selectTab(it.index),
      borderRadius: BorderRadius.circular(AppDesign.radiusPill),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            it.icon,
            size: 22,
            color: sel ? AppDesign.accent : AppDesign.textLo,
          ),
          const SizedBox(height: 3),
          Text(
            it.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
              color: sel ? AppDesign.accent : AppDesign.textLo,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
    final isSelected = _selectedIndex == index;
    final accent = AppDesign.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Pressable(
        onTap: () => _selectTab(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: isSelected
                ? AppDesign.blue.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected ? accent : AppDesign.textLo,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: isSelected ? accent : AppDesign.textLo,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Slide-out navigation for compact (phone) widths. Mirrors the sidebar's
  /// destinations; selecting one also closes the drawer.
  Widget _buildDrawer(BuildContext context, List<_NavItem> drawerItems) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppDesign.blue,
                    ),
                    child: Center(
                      child: _AvatarContent(
                        identity: widget.currentUser.username,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.currentUser.username,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12.5,
                            color: AppDesign.textHi,
                          ),
                        ),
                        Text(
                          widget.currentUser.role,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: AppDesign.textLo,
                            fontFamily: AppDesign.fontData,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                children: [
                  for (final item in drawerItems)
                    ListTile(
                      selected: _selectedIndex == item.index,
                      selectedTileColor: AppDesign.blue.withValues(alpha: 0.08),
                      selectedColor: AppDesign.accent,
                      leading: Icon(item.icon, size: 18, color: _selectedIndex == item.index ? AppDesign.accent : AppDesign.textLo),
                      title: Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: _selectedIndex == item.index ? FontWeight.w600 : FontWeight.w500,
                          color: _selectedIndex == item.index ? AppDesign.accent : AppDesign.textLo,
                        ),
                      ),
                      onTap: () {
                        _selectTab(item.index);
                        Navigator.of(context).pop();
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The letter shown inside an account avatar.
///
/// Till identities are phone numbers, so the first character is usually a
/// digit -- "0" reads as a broken counter, not a person. Digits and the
/// punctuation of a formatted phone number fall back to a person glyph; any
/// real letter (Amharic included) is a meaningful initial.
class _AvatarContent extends StatelessWidget {
  final String identity;
  final double fontSize;

  const _AvatarContent({required this.identity, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    final trimmed = identity.trim();
    // A phone login starts with a digit (or +, -, "(" from a formatted
    // number); none of those make a meaningful initial in any script.
    final first = trimmed.isEmpty ? '' : trimmed[0];
    final initial = RegExp(r'[0-9+\-()\s]').hasMatch(first)
        ? null
        : first.toUpperCase();

    if (initial == null) {
      return Icon(
        CupertinoIcons.person_fill,
        size: fontSize + 4,
        color: AppDesign.onBlue,
      );
    }
    return Text(
      initial,
      style: TextStyle(
        color: AppDesign.onBlue,
        fontWeight: FontWeight.w700,
        fontSize: fontSize,
      ),
    );
  }
}

/// A navigation destination shared by the desktop sidebar and the mobile drawer.
class _NavItem {
  final int index;
  final IconData icon;
  final String label;

  const _NavItem(this.index, this.icon, this.label);
}

/// A feature-tab destination built per-account in [MainScaffold.build]: the
/// feature key (for tab-refresh + register-landing resolution), its nav label /
/// icon, and the already-constructed screen widget for the IndexedStack.
class _ShellDestination {
  final String key;
  final String label;
  final IconData icon;
  final Widget screen;

  const _ShellDestination(this.key, this.label, this.icon, this.screen);
}

/// Fades [child] in whenever its key changes (i.e. a different tab is shown),
/// driven by a shared controller owned by the shell. Only ever mounts one
/// subtree at a time, so screen GlobalKeys stay unique.
class _TabFadeTransition extends StatefulWidget {
  final AnimationController controller;
  final Curve curve;
  final Widget child;

  const _TabFadeTransition({
    required this.controller,
    required this.curve,
    required this.child,
  });

  @override
  State<_TabFadeTransition> createState() => _TabFadeTransitionState();
}

class _TabFadeTransitionState extends State<_TabFadeTransition> {
  late Object? _lastKey = widget.child.key;
  late final CurvedAnimation _animation = CurvedAnimation(
    parent: widget.controller,
    curve: widget.curve,
  );

  @override
  void initState() {
    super.initState();
    widget.controller
      ..value = 0
      ..forward();
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_TabFadeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.child.key != _lastKey) {
      _lastKey = widget.child.key;
      widget.controller
        ..value = 0
        ..forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _animation, child: widget.child);
  }
}
