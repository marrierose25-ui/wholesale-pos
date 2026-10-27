import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'core/auth/session_store.dart';
import 'core/backend/app_backend.dart';
import 'core/models/user.dart';
import 'core/theme/app_design.dart';
import 'core/theme/app_theme.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/finance/finance_overview_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/register/cash_history_screen.dart';
import 'features/register/register_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/sales/sale.dart';
import 'features/sales/sale_item.dart';
import 'features/sales/sales_history_screen.dart';
import 'features/sales/sales_screen.dart';
import 'features/users/user_management_screen.dart';
import 'features/audit/audit_log_screen.dart';

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
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<RegisterScreenState> _registerKey =
      GlobalKey<RegisterScreenState>();
  final GlobalKey<DashboardScreenState> _dashboardKey =
      GlobalKey<DashboardScreenState>();
  final GlobalKey<ReportsScreenState> _reportsKey =
      GlobalKey<ReportsScreenState>();
  final GlobalKey<SalesScreenState> _salesKey = GlobalKey<SalesScreenState>();
  final GlobalKey<SalesHistoryScreenState> _historyKey =
      GlobalKey<SalesHistoryScreenState>();
  final GlobalKey<FinanceOverviewScreenState> _financeKey =
      GlobalKey<FinanceOverviewScreenState>();
  final GlobalKey<CashHistoryScreenState> _cashHistoryKey =
      GlobalKey<CashHistoryScreenState>();

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
      );
      var done = 0;
      for (var i = 0; i < count; i++) {
        final p = _devSeedProducts[i % _devSeedProducts.length];
        final qtyMilli = (1 + (i % 4)) * 1000; // 1..4 whole units
        final lineTotal = (p.unitPriceMinor * qtyMilli / 1000).round();
        final saleId = uid.v4();
        final receipt = await widget.backend.sales.nextReceiptNumber();
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
      // ignore: avoid_print
      print('[dev-seed] created $done/$count sample sales');
      if (mounted) _refreshDataScreens();
    } catch (e) {
      // ignore: avoid_print
      print('[dev-seed] aborted: $e');
    }
  }

  /// Silent background refreshes so every data screen shows the latest
  /// figures the moment it is looked at — no manual refresh needed.
  void _refreshDataScreens() {
    for (final i in {0, 1, 2, 3, 4, 5, 9}) {
      _loadScreen(i, silent: true);
    }
  }

  /// Reloads one data screen by nav index; unknown/no-op indexes are ignored
  /// (a null key means the screen is not built for the current role).
  void _loadScreen(int index, {bool silent = false}) {
    switch (index) {
      case 0:
        _dashboardKey.currentState?.loadDashboard(silent: silent);
      case 1:
        _salesKey.currentState?.loadShift();
      case 2:
        _registerKey.currentState?.loadData(silent: silent);
      case 3:
        _financeKey.currentState?.load(silent: silent);
      case 4:
        _historyKey.currentState?.loadSales(silent: silent);
      case 5:
        _reportsKey.currentState?.loadReports();
      case 9:
        _cashHistoryKey.currentState?.load(silent: silent);
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
    final isOwner = widget.currentUser.role == 'OWNER';
    final registerIndex = isOwner ? 2 : 1;

    // Completing a sale refreshes every data screen and lands the shell on the
    // Register tab, so the drawer balance is the next thing the cashier sees.
    void onSaleCompleted() {
      _refreshDataScreens();
      _selectTab(registerIndex);
    }

    final salesScreen = SalesScreen(
      key: _salesKey,
      saleRepository: backend.sales,
      shiftRepository: backend.shifts,
      deviceId: backend.deviceId,
      currentUser: widget.currentUser,
      onSaleCompleted: onSaleCompleted,
    );
    final historyScreen = SalesHistoryScreen(
      key: _historyKey,
      saleRepository: backend.sales,
      currentUser: widget.currentUser,
      onSaleVoided: _refreshDataScreens,
    );
    final registerScreen = RegisterScreen(
      key: _registerKey,
      onShiftUpdated: _refreshDataScreens,
      currentUser: widget.currentUser,
      shiftRepository: backend.shifts,
      saleRepository: backend.sales,
    );
    final settingsScreen = backend.settingsScreen(
      currentUser: widget.currentUser,
      onLogout: widget.onLogout,
      isDarkMode: widget.isDarkMode,
      onToggleTheme: widget.onToggleTheme,
    );

    // Role-specific ordering. Owner: Dashboard / POS / Register / Money
    // Tracking lead the pill and History / Reports / Users / Audit / Settings
    // live in the drawer. Cashier: POS / Register lead, History / Settings in
    // the drawer.
    final screens = <Widget>[
      if (isOwner) ...[
        DashboardScreen(key: _dashboardKey, saleRepository: backend.sales),
        salesScreen,
        registerScreen,
        FinanceOverviewScreen(
          key: _financeKey,
          financeRepository: backend.finance,
          currentUser: widget.currentUser,
        ),
        historyScreen,
        ReportsScreen(key: _reportsKey, saleRepository: backend.sales),
        UserManagementScreen(
          userRepository: backend.users,
          currentUser: widget.currentUser,
        ),
        AuditLogScreen(saleRepository: backend.sales),
        CashHistoryScreen(
          key: _cashHistoryKey,
          shiftRepository: backend.shifts,
        ),
        settingsScreen,
      ] else ...[
        salesScreen,
        registerScreen,
        historyScreen,
        settingsScreen,
      ],
    ];

    if (_selectedIndex >= screens.length) _selectedIndex = 0;
    final settingsIndex = screens.length - 1;

    final allNavItems = <_NavItem>[
      if (isOwner) ...[
        const _NavItem(0, Icons.dashboard, 'Dashboard'),
        const _NavItem(1, Icons.shopping_cart, 'POS'),
        const _NavItem(2, Icons.point_of_sale, 'Register'),
        const _NavItem(3, Icons.account_balance_wallet, 'Money Tracking'),
        const _NavItem(4, Icons.history, 'History'),
        const _NavItem(5, Icons.bar_chart, 'Reports'),
        const _NavItem(6, Icons.people, 'Users'),
        const _NavItem(7, Icons.security, 'Audit Logs'),
        const _NavItem(8, Icons.account_tree, 'Register History'),
        const _NavItem(9, Icons.settings, 'Settings'),
      ] else ...[
        const _NavItem(0, Icons.shopping_cart, 'POS'),
        const _NavItem(1, Icons.point_of_sale, 'Register'),
        const _NavItem(2, Icons.history, 'History'),
        const _NavItem(3, Icons.settings, 'Settings'),
      ],
    ];
    // The first [pillCount] destinations lead the bottom pill (owner 4, cashier
    // 2); the rest live in the hamburger drawer.
    final pillCount = isOwner ? 4 : 2;
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
                    _NavItem(settingsIndex, Icons.settings, 'Settings'),
              )
              .label;
          return Scaffold(
            key: _scaffoldKey,
            backgroundColor: AppDesign.bg,
            extendBody: false,
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
              title: Text(title),
            ),
            drawer: _buildDrawer(context, drawerItems),
            body: _tabSwitcher(screens),
            bottomNavigationBar: _mobilePillNav(pillItems),
          );
        }

        final sidebarWidth = constraints.maxWidth < 900 ? 200.0 : 250.0;
        return Scaffold(
          body: Row(
            children: [
              Container(
                width: sidebarWidth,
                decoration: BoxDecoration(
                  color: AppDesign.bgElevated,
                  border: Border(
                    right: BorderSide(color: AppDesign.stroke, width: 1),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              gradient: AppDesign.buttonGradient,
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [
                                AppDesign.blueGlow(alpha: 0.5, blur: 16),
                              ],
                            ),
                            child: const Icon(
                              Icons.storefront,
                              color: AppDesign.onBlue,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              'Wholesale POS',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                                letterSpacing: -0.5,
                                color: Theme.of(context).colorScheme.onSurface,
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
                    const Divider(),
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
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: AppDesign.buttonGradient,
                              ),
                              child: Center(
                                child: Text(
                                  widget.currentUser.username.isEmpty
                                      ? '?'
                                      : widget.currentUser.username[0]
                                            .toUpperCase(),
                                  style: const TextStyle(
                                    color: AppDesign.onBlue,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
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
                                      fontSize: 13,
                                      color: AppDesign.textHi,
                                    ),
                                  ),
                                  Text(
                                    widget.currentUser.role,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: AppDesign.textLo,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.settings,
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
        // Extra bottom clearance lifts the pill above the phone's home-indicator
        // / gesture zone (and any mobile-browser bottom bar), so its buttons
        // stay tappable instead of having taps swallowed by the OS.
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Container(
          height: 62,
          decoration: BoxDecoration(
            color: AppDesign.bgElevated.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(AppDesign.radiusPill),
            border: Border.all(color: AppDesign.strokeStrong),
            boxShadow: AppDesign.cardShadow(),
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(AppDesign.radiusPill),
            child: Row(
              children: [
                for (final it in items) Expanded(child: _pillItem(it)),
              ],
            ),
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
            color: sel ? AppDesign.blueBright : AppDesign.textLo,
          ),
          const SizedBox(height: 3),
          Text(
            it.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
              color: sel ? AppDesign.textHi : AppDesign.textLo,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
    final isSelected = _selectedIndex == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () => _selectTab(index),
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: isSelected
                ? AppDesign.blue.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? AppDesign.blue.withValues(alpha: 0.35)
                  : Colors.transparent,
            ),
            boxShadow: isSelected
                ? [AppDesign.blueGlow(alpha: 0.18, blur: 16)]
                : null,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 19,
                color: isSelected ? AppDesign.blueBright : AppDesign.textLo,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected ? AppDesign.textHi : AppDesign.textLo,
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
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: Text(
                      widget.currentUser.username.isEmpty
                          ? '?'
                          : widget.currentUser.username[0].toUpperCase(),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary,
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
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          widget.currentUser.role,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).textTheme.bodySmall?.color,
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
                      selectedTileColor: Theme.of(context).colorScheme.surface,
                      leading: Icon(item.icon, size: 20),
                      title: Text(item.label),
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

/// A navigation destination shared by the desktop sidebar and the mobile drawer.
class _NavItem {
  final int index;
  final IconData icon;
  final String label;

  const _NavItem(this.index, this.icon, this.label);
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
