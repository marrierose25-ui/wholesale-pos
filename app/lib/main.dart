import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'core/database/local_database.dart';
import 'core/auth/session_store.dart';
import 'core/licensing/activation_client.dart';
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
import 'core/sync/sync_service.dart';
import 'core/theme/app_design.dart';
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
    isMobile: Platform.isAndroid || Platform.isIOS,
    licenseProvider: () =>
        LocalDatabase.getSetting(db, SyncGatewayBackend.licenseSettingKey),
  );
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
      // Dark is the flagship look; honour an explicit 'light' choice, but
      // default to dark on fresh installs / when unset.
      initialDarkMode: themeSetting != 'light',
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
  /// Settings key holding the signed license payload on ANY platform. Desktop
  /// additionally honours the legacy `license.key` file next to the exe if
  /// this is empty, so Umer's existing shop PCs keep working unchanged.
  static const String _licenseCodeKey = 'license_code';

  /// Settings key holding the short opaque activation code (e.g.
  /// "MERCA-7Q2F-9K3X-4D8M-BN"). Kept separately so Settings -> Devices can
  /// pass it to list/deactivate/voucher endpoints without exposing the
  /// signed license payload itself.
  static const String _activationCodeKey = 'activation_code';

  bool _isChecking = true;
  bool _isLicensed = false;
  String? _error;
  String? _fingerprint;

  /// Instantiated once; the URL is baked via --dart-define at build time.
  final ActivationClient _activationClient = ActivationClient();

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

  /// Validates whatever the user typed on the activation screen. Two shapes
  /// are accepted for backward compatibility:
  ///  - A short opaque code (e.g. "MERCA-…-BN") — redeem it against the
  ///    licensing Edge Function; on success the server returns a signed v2
  ///    license bound to this device's fingerprint, which we persist.
  ///  - A full signed payload (`base64url.base64url`) — validate it locally
  ///    with the same Ed25519 path used in Phase 14 for device-unbound
  ///    licenses (still valid for the developer's own shop PC + any legacy
  ///    codes sold before Phase 17).
  Future<String?> _activateWithCode(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return 'Enter the activation code.';
    final fingerprint = _fingerprint;
    if (fingerprint == null) {
      return 'Could not compute a device fingerprint; restart the app.';
    }

    final looksLikeSignedPayload = trimmed.contains('.');
    final String licenseToStore;
    if (looksLikeSignedPayload) {
      final result = await LicenseValidator.validateLicense(
        licenseText: trimmed,
        deviceFingerprint: fingerprint,
      );
      if (result == null || result['error'] != null) {
        return result?['error'] as String? ?? 'Invalid license code.';
      }
      licenseToStore = trimmed;
    } else {
      if (!_activationClient.isConfigured) {
        return 'Activation server is not configured on this build. Ask your '
            'provider to rebuild with '
            '--dart-define=WHOLESALE_POS_LICENSE_FN_URL=<url>.';
      }
      final response = await _activationClient.activateDevice(
        activationCode: trimmed,
        deviceFingerprint: fingerprint,
        deviceName: Platform.localHostname,
      );
      if (!response.ok) {
        return response.error ?? 'Activation failed.';
      }
      final returned = response.licenseCode!;
      // Defense-in-depth: never trust the server's word — verify the signed
      // payload with the baked Ed25519 public key before we accept it.
      final verify = await LicenseValidator.validateLicense(
        licenseText: returned,
        deviceFingerprint: fingerprint,
      );
      if (verify == null || verify['error'] != null) {
        return 'Server returned an invalid license.';
      }
      licenseToStore = returned;
      await LocalDatabase.setSetting(widget.db, _activationCodeKey, trimmed);
    }

    await LocalDatabase.setSetting(widget.db, _licenseCodeKey, licenseToStore);
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

  /// On launch, resume the previous sign-in unless the user explicitly opted
  /// OUT (a stored '0'). Persistent sign-in is ON by default so a shop till
  /// that is simply closed and reopened does not demand the password again.
  /// On a successful resume the session window is slid forward, so a till used
  /// at least once per validity period never expires in normal daily use.
  Future<void> _restoreSession() async {
    User? restored;
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
    // A custom bottomNavigationBar does not get the system bottom inset for
    // free, so wrap in SafeArea(bottom: true) — otherwise the pill collides
    // with the Android back/home/recents bar and becomes partly unclickable.
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
