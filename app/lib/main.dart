import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'core/database/local_database.dart';
import 'core/auth/session_store.dart';
import 'core/licensing/license_validator.dart';
import 'core/models/user.dart';
import 'core/repositories/finance_repository.dart';
import 'core/repositories/product_repository.dart';
import 'core/repositories/sale_repository.dart';
import 'core/repositories/shift_repository.dart';
import 'core/repositories/user_repository.dart';
import 'core/sync/sync_outbox_repository.dart';
import 'core/sync/sync_service.dart';
import 'core/sync/supabase_sync_backend.dart';
import 'core/theme/app_theme.dart';
import 'features/audit/audit_log_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/finance/finance_overview_screen.dart';
import 'features/licensing/activation_screen.dart';
import 'features/products/product_list_screen.dart';
import 'features/register/register_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/sales/sales_history_screen.dart';
import 'features/sales/sales_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/users/user_management_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = await LocalDatabase.open();
  final productRepository = ProductRepository(db);
  final saleRepository = SaleRepository(db);
  final userRepository = UserRepository(db);
  final shiftRepository = ShiftRepository(db);
  final financeRepository = FinanceRepository(db);

  final deviceId = await LocalDatabase.registerCurrentDevice(db);
  final themeSetting = await LocalDatabase.getSetting(
    db,
    LocalDatabase.themeSettingKey,
  );

  // Cloud sync. Inert unless built with --dart-define=SUPABASE_URL/KEY: with no
  // backend configured this stays the offline no-op and never starts a timer.
  final syncBackend = SupabaseSyncBackend.fromEnvironment();
  if (syncBackend.isConfigured) {
    final outbox = SyncOutboxRepository(db);
    _startSyncLoop(SyncService(outbox, syncBackend), outbox);
  }

  runApp(
    WholesalePosApp(
      db: db,
      productRepository: productRepository,
      saleRepository: saleRepository,
      userRepository: userRepository,
      shiftRepository: shiftRepository,
      financeRepository: financeRepository,
      deviceId: deviceId,
      initialDarkMode: themeSetting == 'dark',
    ),
  );
}

/// Drains the outbox to the cloud on a timer. The first attempt runs on
/// startup (to catch anything queued while offline); then every 30 seconds.
/// Any error (offline, backend down) is swallowed: rows stay queued and the
/// next tick retries, so syncing can never crash the register.
void _startSyncLoop(SyncService service, SyncOutboxRepository outbox) {
  Future<void> drain() async {
    try {
      await service.syncNow();
      await outbox.pruneSynced();
    } catch (_) {
      // Leave everything queued; retried on the next tick.
    }
  }

  drain();
  // The event loop holds the repeating timer for the life of the process.
  Timer.periodic(const Duration(seconds: 30), (_) => drain());
}

class WholesalePosApp extends StatefulWidget {
  final Database db;
  final ProductRepository productRepository;
  final SaleRepository saleRepository;
  final UserRepository userRepository;
  final ShiftRepository shiftRepository;
  final FinanceRepository financeRepository;
  final String deviceId;
  final bool initialDarkMode;

  const WholesalePosApp({
    super.key,
    required this.db,
    required this.productRepository,
    required this.saleRepository,
    required this.userRepository,
    required this.shiftRepository,
    required this.financeRepository,
    required this.deviceId,
    required this.initialDarkMode,
  });

  @override
  State<WholesalePosApp> createState() => _WholesalePosAppState();
}

class _WholesalePosAppState extends State<WholesalePosApp> {
  late ThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.initialDarkMode ? ThemeMode.dark : ThemeMode.light;
  }

  Future<void> _toggleTheme(bool isDark) async {
    setState(() => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light);
    // Await the write so the choice is persisted even if the app is closed
    // immediately after toggling.
    await LocalDatabase.setSetting(
      widget.db,
      LocalDatabase.themeSettingKey,
      isDark ? 'dark' : 'light',
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wholesale POS',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      home: LicenseWrapper(
        db: widget.db,
        productRepository: widget.productRepository,
        saleRepository: widget.saleRepository,
        userRepository: widget.userRepository,
        shiftRepository: widget.shiftRepository,
        financeRepository: widget.financeRepository,
        deviceId: widget.deviceId,
        isDarkMode: _themeMode == ThemeMode.dark,
        onToggleTheme: () => _toggleTheme(_themeMode == ThemeMode.light),
      ),
    );
  }
}

class LicenseWrapper extends StatefulWidget {
  final Database db;
  final ProductRepository productRepository;
  final SaleRepository saleRepository;
  final UserRepository userRepository;
  final ShiftRepository shiftRepository;
  final FinanceRepository financeRepository;
  final String deviceId;
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const LicenseWrapper({
    super.key,
    required this.db,
    required this.productRepository,
    required this.saleRepository,
    required this.userRepository,
    required this.shiftRepository,
    required this.financeRepository,
    required this.deviceId,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<LicenseWrapper> createState() => _LicenseWrapperState();
}

class _LicenseWrapperState extends State<LicenseWrapper> {
  /// Settings key holding a mobile device's entered license code. Desktop keeps
  /// using the `license.key` file; phones have no such file, so the code typed
  /// into the activation screen is persisted here (app-private on mobile).
  static const String _licenseCodeKey = 'license_code';

  bool _isChecking = true;
  bool _isLicensed = false;
  String? _error;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _checkLicense();
  }

  Future<void> _checkLicense() async {
    setState(() => _isChecking = true);
    // On mobile, validate the code persisted in settings (null on first run,
    // which simply shows the activation screen). Desktop reads license.key.
    final storedCode = _isMobile
        ? await LocalDatabase.getSetting(widget.db, _licenseCodeKey)
        : null;
    final license = await LicenseValidator.validateLicense(
      licenseText: storedCode,
    );
    if (!mounted) return;

    setState(() {
      if (license != null && license['error'] != null) {
        _isLicensed = false;
        // On mobile with nothing entered yet, suppress the desktop-specific
        // "license.key not found" text; the code-entry UI has its own guidance.
        _error = _isMobile && (storedCode == null || storedCode.isEmpty)
            ? null
            : license['error'] as String?;
      } else {
        _isLicensed = license != null;
        _error = null;
      }
      _isChecking = false;
    });
  }

  /// Validates a code the user typed/pasted. On success it is persisted so the
  /// app stays activated on later launches; on failure the error is returned to
  /// the activation screen (nothing is saved).
  Future<String?> _activateWithCode(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return 'Enter the license code.';
    final result = await LicenseValidator.validateLicense(licenseText: trimmed);
    if (result == null || result['error'] != null) {
      return result?['error'] as String? ?? 'Invalid license code.';
    }
    await LocalDatabase.setSetting(widget.db, _licenseCodeKey, trimmed);
    if (!mounted) return null;
    setState(() {
      _isLicensed = true;
      _error = null;
      _isChecking = false;
    });
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_isLicensed) {
      return ActivationScreen(
        onActivated: _checkLicense,
        errorMessage: _error,
        onActivateWithCode: _activateWithCode,
        showCodeEntry: _isMobile,
      );
    }

    return AuthWrapper(
      db: widget.db,
      productRepository: widget.productRepository,
      saleRepository: widget.saleRepository,
      userRepository: widget.userRepository,
      shiftRepository: widget.shiftRepository,
      financeRepository: widget.financeRepository,
      deviceId: widget.deviceId,
      isDarkMode: widget.isDarkMode,
      onToggleTheme: widget.onToggleTheme,
    );
  }
}

class AuthWrapper extends StatefulWidget {
  final Database db;
  final ProductRepository productRepository;
  final SaleRepository saleRepository;
  final UserRepository userRepository;
  final ShiftRepository shiftRepository;
  final FinanceRepository financeRepository;
  final String deviceId;
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const AuthWrapper({
    super.key,
    required this.db,
    required this.productRepository,
    required this.saleRepository,
    required this.userRepository,
    required this.shiftRepository,
    required this.financeRepository,
    required this.deviceId,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  User? _currentUser;
  bool _restoring = true;
  late final SessionStore _sessions = SettingsSessionStore(widget.db);

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  /// On launch, resume the previous sign-in only when the user opted into
  /// "stay signed in" on this device and a valid, non-expired session exists
  /// for an account that is still active. Otherwise the login screen shows.
  Future<void> _restoreSession() async {
    User? restored;
    final remember = await LocalDatabase.getSetting(
      widget.db,
      SessionStore.rememberKey,
    );
    if (remember == '1') {
      final session = await _sessions.load();
      if (session != null) {
        restored = await widget.userRepository.getById(session.userId);
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
    final remember = await LocalDatabase.getSetting(
      widget.db,
      SessionStore.rememberKey,
    );
    if (remember == '1') {
      await _sessions.save(
        SessionData.create(user.id, lifetime: SessionStore.defaultLifetime),
      );
    } else {
      // Remember-off: never leave a stale session that could auto-resume.
      await _sessions.clear();
    }
  }

  Future<void> _onLogout() async {
    await _sessions.clear();
    if (!mounted) return;
    setState(() => _currentUser = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_restoring) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_currentUser == null) {
      return LoginScreen(
        userRepository: widget.userRepository,
        onLoginSuccess: _onLoginSuccess,
      );
    }

    return MainLayout(
      db: widget.db,
      productRepository: widget.productRepository,
      saleRepository: widget.saleRepository,
      userRepository: widget.userRepository,
      shiftRepository: widget.shiftRepository,
      financeRepository: widget.financeRepository,
      deviceId: widget.deviceId,
      currentUser: _currentUser!,
      onLogout: _onLogout,
      isDarkMode: widget.isDarkMode,
      onToggleTheme: widget.onToggleTheme,
    );
  }
}

class MainLayout extends StatefulWidget {
  final Database db;
  final ProductRepository productRepository;
  final SaleRepository saleRepository;
  final UserRepository userRepository;
  final ShiftRepository shiftRepository;
  final FinanceRepository financeRepository;
  final String deviceId;
  final User currentUser;
  final VoidCallback onLogout;
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const MainLayout({
    super.key,
    required this.db,
    required this.productRepository,
    required this.saleRepository,
    required this.userRepository,
    required this.shiftRepository,
    required this.financeRepository,
    required this.deviceId,
    required this.currentUser,
    required this.onLogout,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
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
    final isOwner = widget.currentUser.role == 'OWNER';

    final screens = <Widget>[
      SalesScreen(
        key: _salesKey,
        saleRepository: widget.saleRepository,
        shiftRepository: widget.shiftRepository,
        productRepository: widget.productRepository,
        deviceId: widget.deviceId,
        currentUser: widget.currentUser,
        onSaleCompleted: _refreshDataScreens,
      ),
      SalesHistoryScreen(
        saleRepository: widget.saleRepository,
        currentUser: widget.currentUser,
        onSaleVoided: _refreshDataScreens,
      ),
      RegisterScreen(
        key: _registerKey,
        onShiftUpdated: _refreshDataScreens,
        currentUser: widget.currentUser,
        shiftRepository: widget.shiftRepository,
        saleRepository: widget.saleRepository,
      ),
      if (isOwner) ProductListScreen(repository: widget.productRepository),
      if (isOwner)
        DashboardScreen(
          key: _dashboardKey,
          saleRepository: widget.saleRepository,
        ),
      if (isOwner)
        ReportsScreen(key: _reportsKey, saleRepository: widget.saleRepository),
      if (isOwner)
        UserManagementScreen(
          userRepository: widget.userRepository,
          currentUser: widget.currentUser,
        ),
      if (isOwner) AuditLogScreen(saleRepository: widget.saleRepository),
      if (isOwner)
        FinanceOverviewScreen(
          financeRepository: widget.financeRepository,
          currentUser: widget.currentUser,
        ),
      SettingsScreen(
        currentUser: widget.currentUser,
        db: widget.db,
        userRepository: widget.userRepository,
        onLogout: widget.onLogout,
        isDarkMode: widget.isDarkMode,
        onToggleTheme: widget.onToggleTheme,
      ),
    ];

    if (_selectedIndex >= screens.length) _selectedIndex = 0;
    final settingsIndex = screens.length - 1;

    // Destination metadata for the compact (phone) navigation drawer. The wide
    // tablet/desktop layout keeps its fixed sidebar below.
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
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
              title: Text(title),
            ),
            drawer: _buildDrawer(context, isOwner, navItems),
            body: IndexedStack(index: _selectedIndex, children: screens),
          );
        }

        final sidebarWidth = constraints.maxWidth < 900 ? 200.0 : 250.0;
        return Scaffold(
          body: Row(
            children: [
              Container(
                width: sidebarWidth,
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  border: Border(
                    right: BorderSide(
                      color: Theme.of(context).dividerColor,
                      width: 1,
                    ),
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
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Icon(
                              Icons.storefront,
                              color: Theme.of(context).colorScheme.onPrimary,
                              size: 16,
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
                    ListTile(
                      onTap: () =>
                          setState(() => _selectedIndex = settingsIndex),
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        child: Text(
                          widget.currentUser.username.isEmpty
                              ? '?'
                              : widget.currentUser.username[0].toUpperCase(),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onPrimary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      title: Text(
                        widget.currentUser.username,
                        style: const TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                        ),
                      ),
                      subtitle: Text(
                        widget.currentUser.role,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                      trailing: Icon(
                        Icons.settings,
                        size: 16,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 4,
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

  Widget _buildNavItem(int index, IconData icon, String label) {
    final isSelected = _selectedIndex == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () => setState(() => _selectedIndex = index),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? Theme.of(context).colorScheme.surface
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: isSelected
                ? Border.all(color: Theme.of(context).dividerColor)
                : null,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected
                    ? Theme.of(context).colorScheme.onSurface
                    : Theme.of(context).textTheme.bodySmall?.color,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).textTheme.bodySmall?.color,
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
