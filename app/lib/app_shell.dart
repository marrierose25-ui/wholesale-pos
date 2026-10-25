import 'package:flutter/material.dart';

import 'core/auth/session_store.dart';
import 'core/backend/app_backend.dart';
import 'core/models/user.dart';
import 'core/theme/app_design.dart';
import 'core/theme/app_theme.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/finance/finance_overview_screen.dart';
import 'features/products/product_list_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/register/register_screen.dart';
import 'features/reports/reports_screen.dart';
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
  Future<void> _restoreSession() async {
    User? restored;
    final remember = await widget.backend.getSetting(SessionStore.rememberKey);
    if (remember != '0') {
      final session = await widget.backend.session.load();
      if (session != null) {
        restored = await widget.backend.users.getById(session.userId);
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

class _MainScaffoldState extends State<MainScaffold> {
  int _selectedIndex = 0;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<RegisterScreenState> _registerKey =
      GlobalKey<RegisterScreenState>();
  final GlobalKey<DashboardScreenState> _dashboardKey =
      GlobalKey<DashboardScreenState>();
  final GlobalKey<ReportsScreenState> _reportsKey =
      GlobalKey<ReportsScreenState>();
  final GlobalKey<SalesScreenState> _salesKey = GlobalKey<SalesScreenState>();

  void _refreshDataScreens() {
    _registerKey.currentState?.loadData();
    _dashboardKey.currentState?.loadDashboard();
    _reportsKey.currentState?.loadReports();
    _salesKey.currentState?.loadShift();
  }

  @override
  Widget build(BuildContext context) {
    final backend = widget.backend;
    final isOwner = widget.currentUser.role == 'OWNER';

    final screens = <Widget>[
      SalesScreen(
        key: _salesKey,
        saleRepository: backend.sales,
        shiftRepository: backend.shifts,
        productRepository: backend.products,
        deviceId: backend.deviceId,
        currentUser: widget.currentUser,
        onSaleCompleted: _refreshDataScreens,
      ),
      SalesHistoryScreen(
        saleRepository: backend.sales,
        currentUser: widget.currentUser,
        onSaleVoided: _refreshDataScreens,
      ),
      RegisterScreen(
        key: _registerKey,
        onShiftUpdated: _refreshDataScreens,
        currentUser: widget.currentUser,
        shiftRepository: backend.shifts,
        saleRepository: backend.sales,
      ),
      if (isOwner) ProductListScreen(repository: backend.products),
      if (isOwner)
        DashboardScreen(key: _dashboardKey, saleRepository: backend.sales),
      if (isOwner)
        ReportsScreen(key: _reportsKey, saleRepository: backend.sales),
      if (isOwner)
        UserManagementScreen(
          userRepository: backend.users,
          currentUser: widget.currentUser,
        ),
      if (isOwner) AuditLogScreen(saleRepository: backend.sales),
      if (isOwner)
        FinanceOverviewScreen(
          financeRepository: backend.finance,
          currentUser: widget.currentUser,
        ),
      backend.settingsScreen(
        currentUser: widget.currentUser,
        onLogout: widget.onLogout,
        isDarkMode: widget.isDarkMode,
        onToggleTheme: widget.onToggleTheme,
      ),
    ];

    if (_selectedIndex >= screens.length) _selectedIndex = 0;
    final settingsIndex = screens.length - 1;

    // Destination metadata for the compact (phone) navigation drawer. The wide
    // layout keeps its fixed sidebar below.
    final navItems = <_NavItem>[
      const _NavItem(0, Icons.shopping_cart, 'POS'),
      const _NavItem(1, Icons.history, 'History'),
      const _NavItem(2, Icons.point_of_sale, 'Register'),
      if (isOwner) ...[
        const _NavItem(3, Icons.label, 'Saved Names'),
        const _NavItem(4, Icons.dashboard, 'Dashboard'),
        const _NavItem(5, Icons.bar_chart, 'Reports'),
        const _NavItem(6, Icons.people, 'Users'),
        const _NavItem(7, Icons.security, 'Audit Logs'),
        const _NavItem(8, Icons.account_balance_wallet, 'Money Tracking'),
      ],
      _NavItem(settingsIndex, Icons.settings, 'Settings'),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 600;
        if (isCompact) {
          final title = navItems
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
            drawer: _buildDrawer(context, isOwner, navItems),
            body: IndexedStack(index: _selectedIndex, children: screens),
            bottomNavigationBar: _mobilePillNav(context, isOwner),
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
                          _buildNavItem(0, Icons.shopping_cart, 'POS'),
                          _buildNavItem(1, Icons.history, 'History'),
                          _buildNavItem(2, Icons.point_of_sale, 'Register'),
                          if (isOwner) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 24, 12, 8),
                              child: Text(
                                'ADMINISTRATION',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.color,
                                ),
                              ),
                            ),
                            _buildNavItem(3, Icons.label, 'Saved Names'),
                            _buildNavItem(4, Icons.dashboard, 'Dashboard'),
                            _buildNavItem(5, Icons.bar_chart, 'Reports'),
                            _buildNavItem(6, Icons.people, 'Users'),
                            _buildNavItem(7, Icons.security, 'Audit Logs'),
                            _buildNavItem(
                              8,
                              Icons.account_balance_wallet,
                              'Money Tracking',
                            ),
                          ],
                        ],
                      ),
                    ),
                    const Divider(),
                    InkWell(
                      onTap: () =>
                          setState(() => _selectedIndex = settingsIndex),
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
              Expanded(
                child: IndexedStack(index: _selectedIndex, children: screens),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Floating frosted-glass pill bottom nav for phones. Shows the primary
  /// destinations plus a "More" button that opens the full drawer.
  Widget _mobilePillNav(BuildContext context, bool isOwner) {
    final items = <_NavItem>[
      const _NavItem(0, Icons.shopping_cart_rounded, 'POS'),
      const _NavItem(1, Icons.history_rounded, 'History'),
      const _NavItem(2, Icons.point_of_sale_rounded, 'Register'),
      if (isOwner) const _NavItem(4, Icons.dashboard_rounded, 'Stats'),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
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
                _pillMore(),
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
      onTap: () => setState(() => _selectedIndex = it.index),
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

  Widget _pillMore() {
    final onMore = _selectedIndex >= 3 && _selectedIndex != 4;
    return InkWell(
      onTap: () => _scaffoldKey.currentState?.openDrawer(),
      borderRadius: BorderRadius.circular(AppDesign.radiusPill),
      child: SizedBox(
        width: 52,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.grid_view_rounded,
              size: 22,
              color: onMore ? AppDesign.blueBright : AppDesign.textLo,
            ),
            const SizedBox(height: 3),
            Text(
              'More',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: onMore ? FontWeight.w700 : FontWeight.w500,
                color: onMore ? AppDesign.textHi : AppDesign.textLo,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
    final isSelected = _selectedIndex == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () => setState(() => _selectedIndex = index),
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
  Widget _buildDrawer(
    BuildContext context,
    bool isOwner,
    List<_NavItem> navItems,
  ) {
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
                  for (final item in navItems) ...[
                    if (isOwner && item.index == 3)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
                        child: Text(
                          'ADMINISTRATION',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ),
                      ),
                    ListTile(
                      selected: _selectedIndex == item.index,
                      selectedTileColor: Theme.of(context).colorScheme.surface,
                      leading: Icon(item.icon, size: 20),
                      title: Text(item.label),
                      onTap: () {
                        setState(() => _selectedIndex = item.index);
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
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
