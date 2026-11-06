import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../auth/session_store.dart';
import '../cloud/cloud_api_client.dart';
import '../cloud/cloud_finance_repository.dart';
import '../cloud/cloud_picklist_repository.dart';
import '../cloud/cloud_product_repository.dart';
import '../cloud/cloud_sale_repository.dart';
import '../cloud/cloud_shift_repository.dart';
import '../cloud/cloud_user_repository.dart';
import '../models/user.dart';
import '../repositories/finance_repository.dart';
import '../repositories/picklist_repository.dart';
import '../repositories/product_repository.dart';
import '../repositories/sale_repository.dart';
import '../repositories/shift_repository.dart';
import '../repositories/user_repository.dart';
import '../../features/web/web_activation_gate.dart';
import '../../features/web/web_settings_screen.dart';
import 'app_backend.dart';
import 'web_local_storage.dart';

/// The web/PWA [AppBackend]: every read/write goes to the `pos-api` Edge
/// Function over [CloudApiClient], and the browser's own preferences (theme,
/// "stay signed in", the shop activation code, this browser's device id) plus
/// the signed session live in `localStorage`.
///
/// Web-only — it (and the `web_settings_screen` / `web_activation_gate` it
/// builds) import `package:web`, so they are referenced exclusively by
/// `main_web.dart` and never enter the native compile graph. The single
/// credential held anywhere on the client is the `pos-api` JWT; no Supabase key
/// is ever present here or in the bundle.
class CloudBackend extends AppBackend {
  static const String _activationKey = 'pos.activation_code';
  static const String _deviceKey = 'pos.device_id';
  static const String _settingPrefix = 'pos.setting.';

  final CloudApiClient _api;
  late final CloudUserRepository _users = CloudUserRepository(_api);
  late final CloudProductRepository _products = CloudProductRepository(_api);
  late final CloudSaleRepository _sales = CloudSaleRepository(_api);
  late final CloudShiftRepository _shifts = CloudShiftRepository(_api);
  late final CloudFinanceRepository _finance = CloudFinanceRepository(_api);
  late final CloudPicklistRepository _picklists = CloudPicklistRepository(_api);
  late final WebSessionStore _session = WebSessionStore(_api);
  late final String _deviceId = _resolveDeviceId();

  CloudBackend()
    : _api = CloudApiClient(activationCode: webRead(_activationKey) ?? '') {
    // Every authenticated pos-api call now carries this device id (auto-stamped
    // in CloudApiClient) so the server scopes the open drawer + receipt stream
    // per device under a shared, live-synced tenant (audit D1).
    _api.deviceId = _deviceId;
  }

  String _resolveDeviceId() {
    final existing = webRead(_deviceKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = const Uuid().v4();
    webWrite(_deviceKey, id);
    return id;
  }

  @override
  ProductRepository get products => _products;
  @override
  SaleRepository get sales => _sales;
  @override
  UserRepository get users => _users;
  @override
  ShiftRepository get shifts => _shifts;
  @override
  FinanceRepository get finance => _finance;
  @override
  PicklistRepository? get picklists => _picklists;
  @override
  SessionStore get session => _session;
  @override
  String get deviceId => _deviceId;

  @override
  Future<String?> getSetting(String key) async {
    final value = webRead('$_settingPrefix$key');
    return (value == null || value.isEmpty) ? null : value;
  }

  @override
  Future<void> setSetting(String key, String value) async {
    webWrite('$_settingPrefix$key', value);
  }

  @override
  bool get isProvisioned => _api.activationCode.isNotEmpty;

  @override
  Widget settingsScreen({
    required User currentUser,
    required VoidCallback onLogout,
    required bool isDarkMode,
    required VoidCallback onToggleTheme,
  }) {
    return WebSettingsScreen(
      backend: this,
      currentUser: currentUser,
      onLogout: onLogout,
      isDarkMode: isDarkMode,
      onToggleTheme: onToggleTheme,
    );
  }

  @override
  Widget buildActivationGate({required VoidCallback onReady}) {
    return WebActivationGate(onSubmit: _provisionShop, onReady: onReady);
  }

  /// Verifies the pasted shop code against `pos-api` (its `has_users` probe
  /// resolves the activation code to a tenant), then persists it so every
  /// later login is scoped to that tenant. Returns a display-safe error string,
  /// or null on success.
  Future<String?> _provisionShop(String code) async {
    try {
      await _api.call('has_users', {'activation_code': code});
    } on CloudApiException catch (e) {
      return e.message;
    }
    _api.activationCode = code;
    webWrite(_activationKey, code);
    return null;
  }
}

/// [SessionStore] that persists the sign-in envelope in browser
/// [localStorage]. The envelope's `token` is the real `pos-api` JWT (the
/// browser's only credential), captured from [CloudApiClient] on save and
/// re-attached to it on [load] so authenticated calls keep working after a
/// reload.
class WebSessionStore implements SessionStore {
  static const String _key = 'pos.session';

  final CloudApiClient _api;
  WebSessionStore(this._api);

  @override
  Future<void> save(SessionData session) async {
    // Store the live bearer token (set by login) rather than the throwaway
    // nonce, so a browser reload resumes the same server session.
    final token = _api.token ?? session.token;
    webWrite(
      _key,
      jsonEncode({
        'userId': session.userId,
        'token': token,
        'issuedAt': session.issuedAt.toIso8601String(),
        'expiresAt': session.expiresAt.toIso8601String(),
      }),
    );
  }

  @override
  Future<SessionData?> load() async {
    final raw = webRead(_key);
    if (raw == null) return null;
    try {
      final session = SessionData.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (session.isExpired()) {
        await clear();
        return null;
      }
      // Rehydrate the bearer token so the repositories are authenticated.
      _api.token = session.token;
      return session;
    } catch (_) {
      await clear();
      return null;
    }
  }

  @override
  Future<void> clear() async {
    webErase(_key);
    _api.token = null;
  }
}
