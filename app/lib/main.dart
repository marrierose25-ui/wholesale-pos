import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'core/database/local_database.dart';
import 'core/auth/features.dart';
import 'core/auth/session_store.dart';
import 'core/licensing/device_activation.dart';
import 'core/licensing/device_fingerprint.dart';
import 'core/licensing/license_validator.dart';
import 'core/models/user.dart';
import 'core/repositories/finance_repository.dart';
import 'core/repositories/product_repository.dart';
import 'core/repositories/sale_repository.dart';
import 'core/repositories/shift_repository.dart';
import 'core/repositories/user_repository.dart';
import 'core/sync/sync_gateway_backend.dart';
import 'core/sync/sync_outbox_repository.dart';
import 'core/sync/sync_pull_applier.dart';
import 'core/sync/sync_runtime.dart';
import 'core/sync/sync_service.dart';
import 'core/sync/sync_status.dart';
import 'core/theme/app_design.dart';
import 'core/theme/app_theme.dart';
import 'features/audit/audit_log_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/finance/finance_overview_screen.dart';
import 'features/licensing/activation_screen.dart';
import 'features/register/register_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/sales/sales_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/users/user_management_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await _startup();
  } catch (error, stackTrace) {
    // ignore: avoid_print
    print('STARTUP FAILURE: $error\n$stackTrace');
    runApp(_StartupErrorApp(error, stackTrace));
  }
}

Future<void> _startup() async {
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

  // Guarantee the permanent training account exists on every launch once an
  // owner is present. Guarded by hasUsers so a brand-new install still runs
  // first-owner setup cleanly; idempotent, so it is a no-op after the seed.
  if (await userRepository.hasUsers()) {
    await userRepository.ensureDemoUser();
  }

  // Cloud sync (Phase 18). Priority: legacy baked secret on the owner's own
  // desktop (locked back-office PC, direct PostgREST) → license-gated sync
  // gateway (every buyer build and every phone; carries only the signed
  // license, never a key) → Noop. The gateway URL is either baked via
  // --dart-define=WHOLESALE_POS_SYNC_FN_URL or derived from the licensing
  // function URL, so the release script's defines enable it automatically.
  // Rows queued before activation stay put and flow on the first drain after.
  final syncBackend = SyncGatewayBackend.selectBackend(
    gatewayUrl: SyncGatewayBackend.gatewayUrlFromEnvironment(),
    secretUrl: const String.fromEnvironment('SUPABASE_URL'),
    secretKey: const String.fromEnvironment('SUPABASE_KEY'),
    unsafeAllowEmbed: const bool.fromEnvironment(
      'WHOLESALE_POS_UNSAFE_EMBED_SYNC_SECRET',
    ),
    isMobile: !kIsWeb && Platform.isAndroid || !kIsWeb && Platform.isIOS,
    licenseProvider: () =>
        LocalDatabase.getSetting(db, SyncGatewayBackend.licenseSettingKey),
  );
  final outbox = SyncOutboxRepository(db);
  final puller = CloudSyncPuller(backend: syncBackend, db: db);
  final syncService = SyncService(
    outbox,
    syncBackend,
    puller: puller,
    pullInterval: SyncIntervals.cycle,
  );
  final runtime = SyncRuntime(service: syncService, puller: puller);
  if (syncBackend.isConfigured) {
    _startSyncLoop(syncService, outbox);
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
      // Dark is the flagship look; honour an explicit 'light' choice, but
      // default to dark on fresh installs / when unset.
      initialDarkMode: themeSetting != 'light',
      syncRuntime: runtime,
    ),
  );
}

/// Everything the UI needs from the sync engine (see [SyncRuntime]).
/// Drains the outbox to the cloud on a timer. The first attempt runs on
/// startup (to catch anything queued while offline); then every
/// [SyncIntervals.cycle] — which pushes and pulls on the same cadence, so a
/// sale recorded on one register is on every other screen within seconds.
///
/// The tick only *requests* a drain. [SyncService.syncNow] holds a
/// single-flight guard, so a cycle still running when the next tick arrives
/// returns idle instead of starting a second drain: two overlapping drains
/// would interleave SQLite writes on the same transaction and re-order the
/// outbox the queue exists to sequence. Errors are swallowed: rows stay queued
/// and the next tick retries, so syncing can never crash the register.
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
  Timer.periodic(SyncIntervals.cycle, (_) => drain());
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
  final SyncRuntime? syncRuntime;

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
    this.syncRuntime,
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
    // Point the shared design tokens at the palette matching the active
    // brightness BEFORE building the tree, so every `AppDesign.xxx` colour
    // getter the screens read resolves to the right theme this frame.
    AppDesign.setMode(
      _themeMode == ThemeMode.light ? Brightness.light : Brightness.dark,
    );
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
        syncRuntime: widget.syncRuntime,
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
  final SyncRuntime? syncRuntime;

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
    this.syncRuntime,
  });

  @override
  State<LicenseWrapper> createState() => _LicenseWrapperState();
}

class _LicenseWrapperState extends State<LicenseWrapper> {
  /// Settings key holding the signed license payload on ANY platform. Desktop
  /// additionally honours the legacy `license.key` file next to the exe if
  /// this is empty, so Umer's existing shop PCs keep working unchanged. The
  /// short activation code is written beside it by [DeviceActivation] so
  /// Settings can call the seat endpoints.
  static const String _licenseCodeKey = DeviceActivation.licenseCodeKey;

  bool _isChecking = true;
  bool _isLicensed = false;
  String? _error;
  String? _fingerprint;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Compute fingerprint (needs DB access on mobile) before the first
    // validateLicense call so a stored v2 license matches on startup.
    try {
      _fingerprint = await DeviceFingerprint.get(widget.db);
    } catch (_) {
      _fingerprint = null;
    }
    await _checkLicense();
  }

  Future<void> _checkLicense() async {
    if (mounted) setState(() => _isChecking = true);
    final storedCode = await LocalDatabase.getSetting(
      widget.db,
      _licenseCodeKey,
    );
    final license = await LicenseValidator.validateLicense(
      licenseText: storedCode,
      deviceFingerprint: _fingerprint,
    );

    // A device joining an existing shop has a valid license and an EMPTY
    // ledger. Pull the shop's accounts/history BEFORE the login gate decides
    // between "create the first owner" and "sign in", otherwise the second
    // till offers first-time setup and quietly creates a duplicate owner.
    if (license != null && license['error'] == null) {
      await _firstPullIfNewDevice();
    }
    if (!mounted) return;

    setState(() {
      if (license != null && license['error'] != null) {
        _isLicensed = false;
        // Fresh-install state (mobile, or desktop with no license.key file):
        // validator returns "license.key not found." — hide that behind the
        // code-entry UI so the buyer sees an obvious "paste your code here"
        // path instead of a scary file-missing error.
        final fresh =
            (storedCode == null || storedCode.isEmpty) &&
            license['error'] == 'license.key not found.';
        _error = fresh ? null : license['error'] as String?;
      } else {
        _isLicensed = license != null;
        _error = null;
      }
      _isChecking = false;
    });
  }

  /// Validates whatever the user typed on the activation screen and stores the
  /// resulting device-bound licence. The rules (short code redeemed against the
  /// licensing function, or a full signed payload verified locally) live in
  /// [DeviceActivation], shared with the "re-activate" action in Settings.
  Future<String?> _activateWithCode(String input) async {
    final result = await DeviceActivation.redeem(
      widget.db,
      input,
      deviceName: kIsWeb ? 'Web Browser' : Platform.localHostname,
    );
    if (!result.ok) return result.error;

    await _firstPullIfNewDevice();
    if (!mounted) return null;
    setState(() {
      _isLicensed = true;
      _error = null;
      _isChecking = false;
    });
    return null;
  }

  /// One best-effort pull on a device that has no accounts yet. Swallows every
  /// failure: offline is the normal state of a shop till, and the regular loop
  /// retries — the setup screen stays the fallback for a genuinely new shop.
  Future<void> _firstPullIfNewDevice() async {
    final runtime = widget.syncRuntime;
    if (runtime == null) return;
    try {
      if (await widget.userRepository.hasUsers()) return;
      await runtime.puller.pullNow();
    } catch (_) {
      // Ignored on purpose: nothing is lost, the next tick retries.
    }
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
        // Unified code-entry across Windows / Android / iOS. Legacy
        // license.key on desktop is still honoured silently at startup by
        // validateLicense's file fallback, so a shop PC with the file just
        // never reaches this screen.
        showCodeEntry: true,
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
      syncRuntime: widget.syncRuntime,
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
  final SyncRuntime? syncRuntime;

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
    this.syncRuntime,
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

  /// On launch, resume the previous sign-in unless the user explicitly opted
  /// OUT (a stored '0'). Persistent sign-in is ON by default so a shop till
  /// that is simply closed and reopened does not demand the password again.
  /// On a successful resume the session window is slid forward, so a till used
  /// at least once per validity period never expires in normal daily use.
  Future<void> _restoreSession() async {
    User? restored;
    try {
      final remember = await LocalDatabase.getSetting(
        widget.db,
        SessionStore.rememberKey,
      );
      if (remember != '0') {
        final session = await _sessions.load();
        if (session != null) {
          restored = await widget.userRepository.getById(session.userId);
          if (restored != null) {
            // Renew the token so continuous daily use keeps the sign-in alive.
            await _sessions.save(
              SessionData.create(
                restored.id,
                lifetime: SessionStore.defaultLifetime,
              ),
            );
          }
        }
      }
    } catch (_) {
      // A failed resume must never trap the app on the loading spinner; fall
      // back to the login screen and leave the stored session for a retry.
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
    // "Sign in and see the whole shop": refresh immediately instead of waiting
    // for the periodic tick. Fire-and-forget so a dead network can never hold
    // up a cashier who is standing at the till ready to sell.
    final runtime = widget.syncRuntime;
    if (runtime != null) {
      unawaited(
        runtime.service
            .syncNow(forcePull: true)
            .then<void>(
              (_) {},
              onError: (Object e) {
                // ignore: avoid_print
                print('Post-login sync failed: $e');
              },
            ),
      );
    }
    final remember = await LocalDatabase.getSetting(
      widget.db,
      SessionStore.rememberKey,
    );
    if (remember != '0') {
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
      syncRuntime: widget.syncRuntime,
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

  /// Drives the "Cloud Sync" row in Settings and refreshes the data screens
  /// when a pull lands another till's transactions.
  final SyncRuntime? syncRuntime;

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
    this.syncRuntime,
  });

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  int _selectedIndex = 0;

  ValueNotifier<SyncStatus>? _syncStatus;

  @override
  void initState() {
    super.initState();
    _syncStatus = widget.syncRuntime?.service.status;
    _syncStatus?.addListener(_onSyncStatusChanged);
  }

  @override
  void dispose() {
    _syncStatus?.removeListener(_onSyncStatusChanged);
    super.dispose();
  }

  /// A pull that wrote rows means another till rang up sales that no screen here
  /// has ever shown. Refresh in place instead of waiting for the operator to
  /// switch tabs — "sign in and see the whole shop" has to be visible, not just
  /// true in the database.
  void _onSyncStatusChanged() {
    if ((_syncStatus?.value.applied ?? 0) <= 0) return;
    _loadScreen(_selectedIndex, silent: true);
  }

  /// Feature key at each nav position, rebuilt every frame from the account's
  /// ticks so tab-change / sale-complete handlers resolve the current screen
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

  /// Silent background refreshes so every data screen shows the latest
  /// figures. Each loader is guarded by its GlobalKey, so a screen the account
  /// can't open (null currentState) is simply skipped.
  void _refreshDataScreens() {
    _registerKey.currentState?.loadData(silent: true);
    _dashboardKey.currentState?.loadDashboard(silent: true);
    _reportsKey.currentState?.loadReports();
    _salesKey.currentState?.loadShift();
    _financeKey.currentState?.load(silent: true);
  }

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
      case 'reports':
        _reportsKey.currentState?.loadReports();
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.currentUser;

    // Completing a sale refreshes every data screen and lands the shell on the
    // Register tab when this account has it. The index is resolved through the
    // live feature mapping at call time, so it stays correct however the
    // visible tabs are ticked out for the signed-in account.
    void onSaleCompleted() {
      _refreshDataScreens();
      final registerIndex = _navFeatureKeys.indexOf('register');
      if (registerIndex >= 0) setState(() => _selectedIndex = registerIndex);
    }

    final salesScreen = SalesScreen(
      key: _salesKey,
      saleRepository: widget.saleRepository,
      shiftRepository: widget.shiftRepository,
      deviceId: widget.deviceId,
      currentUser: user,
      onSaleCompleted: onSaleCompleted,
    );
    final registerScreen = RegisterScreen(
      key: _registerKey,
      onShiftUpdated: _refreshDataScreens,
      currentUser: user,
      shiftRepository: widget.shiftRepository,
      saleRepository: widget.saleRepository,
    );
    final settingsScreen = SettingsScreen(
      currentUser: user,
      db: widget.db,
      userRepository: widget.userRepository,
      onLogout: widget.onLogout,
      isDarkMode: widget.isDarkMode,
      onToggleTheme: widget.onToggleTheme,
      syncRuntime: widget.syncRuntime,
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
        saleRepository: widget.saleRepository,
        currentUser: user,
      ),
    );
    add('pos', salesScreen);
    add('register', registerScreen);
    add(
      'finance',
      FinanceOverviewScreen(
        key: _financeKey,
        financeRepository: widget.financeRepository,
        currentUser: user,
      ),
    );
    add(
      'reports',
      ReportsScreen(key: _reportsKey, saleRepository: widget.saleRepository),
    );
    add(
      'users',
      UserManagementScreen(
        userRepository: widget.userRepository,
        currentUser: user,
      ),
    );
    add('audit', AuditLogScreen(saleRepository: widget.saleRepository));
    // Settings is always visible regardless of ticks (logout / theme).
    entries.add(
      _ShellDestination('settings', 'Settings', Icons.settings, settingsScreen),
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
    // the hamburger drawer. At most 4, but never more than the visible count.
    final pillCount = entries.length < 4 ? entries.length : 4;
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
            // extendBody:false keeps each child screen's body (and its FAB) above
            // the floating pill; extendBody:true let them drop behind the nav.
            extendBody: false,
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
              title: Text(title),
            ),
            drawer: _buildDrawer(context, drawerItems),
            body: IndexedStack(index: _selectedIndex, children: screens),
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
                      onTap: () {
                        setState(() => _selectedIndex = settingsIndex);
                        _loadScreen(settingsIndex, silent: true);
                      },
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

  /// Floating frosted-glass pill bottom nav for phones. Renders exactly the
  /// role's primary destinations; everything else lives behind the app-bar
  /// menu icon that opens the drawer.
  Widget _mobilePillNav(List<_NavItem> items) {
    // A custom bottomNavigationBar does not get the system bottom inset for
    // free, so wrap in SafeArea(bottom: true) — otherwise the pill collides
    // with the Android back/home/recents bar and becomes partly unclickable.
    return SafeArea(
      top: false,
      child: Padding(
        // Extra bottom clearance lifts the pill above the phone's home-indicator
        // / gesture zone so its buttons stay tappable.
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
      onTap: () {
        setState(() => _selectedIndex = it.index);
        _loadScreen(it.index, silent: true);
      },
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
        onTap: () {
          setState(() => _selectedIndex = index);
          _loadScreen(index, silent: true);
        },
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
                        setState(() => _selectedIndex = item.index);
                        _loadScreen(item.index, silent: true);
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

/// A feature-tab destination built per-account in [MainLayout.build]: the
/// feature key (for sale-complete register-landing resolution), its nav label /
/// icon, and the already-constructed screen widget for the IndexedStack.
class _ShellDestination {
  final String key;
  final String label;
  final IconData icon;
  final Widget screen;

  const _ShellDestination(this.key, this.label, this.icon, this.screen);
}

/// Shown instead of a blank window if startup fails.
class _StartupErrorApp extends StatelessWidget {
  final Object error;
  final StackTrace stackTrace;
  const _StartupErrorApp(this.error, this.stackTrace);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: SelectableText(
              'Wholesale POS could not start.\n\n'
              'Please screenshot this and send to support.\n'
              'No data has been lost.\n\n'
              '$error\n\n$stackTrace',
            ),
          ),
        ),
      ),
    );
  }
}
