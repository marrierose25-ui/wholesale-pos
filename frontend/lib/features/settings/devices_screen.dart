import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pos_cloud_engine/pos_cloud_engine.dart'
    show CloudApiClient, CloudApiException;

import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';

/// Buyer-facing screen for device management under the shop's activation
/// code(s).
///
/// Policy: ONE activation code = ONE business with UNLIMITED devices. This
/// screen lists every device currently registered against the shop's code(s)
/// so the owner can deactivate a lost or replaced device; there is no seat
/// cap and no seat voucher.
///
/// Security: device management is an OWNER action on the `pos-api` surface.
/// The owner signs in with their cloud (pos-api) credentials — the same
/// phone + password the web/PWA uses — and the returned session JWT scopes
/// every call server-side. The activation code plus a device fingerprint is
/// NOT sufficient to list or deactivate devices; that unauthenticated path
/// was removed from the licensing Edge Function.
class DevicesScreen extends StatefulWidget {
  final Future<String?> Function() activationCodeProvider;
  final Future<String> Function() fingerprintProvider;

  /// This device's signed license (`license_code` setting). Sent with
  /// list/deactivate calls so the server can verify WHICH device is calling
  /// instead of trusting the client-supplied fingerprint.
  final Future<String?> Function() licenseProvider;

  /// pos-api client. [CloudApiClient.token] starts empty; this screen drives
  /// the owner `login` action itself and keeps the JWT in memory only.
  final CloudApiClient api;

  const DevicesScreen({
    super.key,
    required this.activationCodeProvider,
    required this.fingerprintProvider,
    required this.licenseProvider,
    required this.api,
  });

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  bool _loading = true;
  bool _needsOwnerLogin = false;
  String? _error;
  String? _activationCode;
  String _fingerprint = '';
  String? _license;
  List<Map<String, dynamic>> _devices = const [];
  int _activeDevices = 0;

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _signingIn = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    if (!widget.api.isConfigured) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'Cloud API is not configured for this build. Device management '
            'needs --dart-define=WHOLESALE_POS_API_URL=<url>.';
      });
      return;
    }
    final code = await widget.activationCodeProvider();
    final fp = await widget.fingerprintProvider();
    final license = await widget.licenseProvider();
    if (!mounted) return;
    if (code == null || code.isEmpty) {
      setState(() {
        _loading = false;
        _activationCode = null;
        _fingerprint = fp;
        _error =
            'This install was activated with a license file, not an '
            'activation code, so there are no cloud devices to manage. To '
            'switch to the code-based model, activate again with the '
            'activation code Umer sent you.';
      });
      return;
    }
    _activationCode = code;
    _fingerprint = fp;
    _license = license;
    if (!widget.api.isSignedIn) {
      setState(() {
        _loading = false;
        _needsOwnerLogin = true;
      });
      return;
    }
    await _refreshDevices();
  }

  Future<void> _refreshDevices() async {
    try {
      final res = await widget.api.call('list_devices', {
        'device_fingerprint': _fingerprint,
        if (_license != null && _license!.isNotEmpty) 'license': _license,
      });
      if (!mounted) return;
      final raw = res['devices'];
      setState(() {
        _loading = false;
        _needsOwnerLogin = false;
        _devices = raw is List
            ? raw.whereType<Map<String, dynamic>>().toList()
            : const [];
        _activeDevices =
            (res['active_devices'] as num?)?.toInt() ?? _devices.length;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is CloudApiException ? e.message : 'Could not load devices.';
      });
    }
  }

  Future<void> _signIn() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      _showSnack('Enter the owner phone number and password.', danger: true);
      return;
    }
    setState(() {
      _signingIn = true;
      _error = null;
    });
    try {
      final res = await widget.api.call('login', {
        'activation_code': _activationCode,
        'username': username,
        'password': password,
      });
      final token = res['token'] as String?;
      if (token == null || token.isEmpty) {
        throw CloudApiException('Sign-in did not return a session.');
      }
      widget.api.token = token;
      _passwordController.clear();
      setState(() => _signingIn = false);
      await _refreshDevices();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _signingIn = false;
        _needsOwnerLogin = true;
        _error = e is CloudApiException ? e.message : 'Sign-in failed.';
      });
    }
  }

  Future<void> _deactivate(Map<String, dynamic> device) async {
    final registrationId = device['id'] as String?;
    if (registrationId == null) return;
    final name = (device['device_name'] as String?) ?? 'this device';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Deactivate device?'),
        content: Text(
          '"$name" will lose access to the cloud as soon as it next '
          'syncs. You can reactivate it later by signing in on that '
          'device with the activation code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _loading = true);
    try {
      await widget.api.call('deactivate_device', {
        'registration_id': registrationId,
        'device_fingerprint': _fingerprint,
        if (_license != null && _license!.isNotEmpty) 'license': _license,
      });
      _showSnack('Device deactivated.');
      await _refreshDevices();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showSnack(
        e is CloudApiException ? e.message : 'Deactivation failed.',
        danger: true,
      );
    }
  }

  void _showSnack(String message, {bool danger = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: danger ? AppTheme.danger : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('My devices'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(CupertinoIcons.arrow_clockwise),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: AppBackground(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_activationCode != null && !_needsOwnerLogin) ...[
                      _HeaderCard(
                        activationCodeMasked: _mask(_activationCode),
                        activeDevices: _activeDevices,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_needsOwnerLogin) ...[
                      _OwnerSignInCard(
                        usernameController: _usernameController,
                        passwordController: _passwordController,
                        signingIn: _signingIn,
                        onSignIn: _signIn,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        _ErrorCard(message: _error!, onRetry: _load),
                      ],
                    ] else ...[
                      if (_error != null) ...[
                        _ErrorCard(message: _error!, onRetry: _load),
                        const SizedBox(height: 16),
                      ],
                      if (_error == null) ..._deviceTiles(),
                      if (_error == null) ...[
                        const SizedBox(height: 24),
                        const Text(
                          'How devices work',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const GlassCard(
                          padding: EdgeInsets.zero,
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              'One activation code covers your whole business '
                              '— activate as many phones, PCs, or tills as '
                              'you need; there is no device limit and nothing '
                              'extra to buy. If a device is lost, sign in '
                              'here as the owner and deactivate it, then '
                              'activate the replacement with the same code.',
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  List<Widget> _deviceTiles() {
    if (_devices.isEmpty) {
      return [
        const GlassCard(
          child: ListTile(
            leading: Icon(CupertinoIcons.info_circle),
            title: Text('No devices registered yet.'),
          ),
        ),
      ];
    }
    return [
      Text(
        'Active devices ($_activeDevices)',
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
      ),
      const SizedBox(height: 8),
      GlassCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (var i = 0; i < _devices.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              _buildDeviceTile(_devices[i]),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _buildDeviceTile(Map<String, dynamic> device) {
    final isSelf = device['is_self'] == true;
    final name = (device['device_name'] as String?) ?? 'Unnamed device';
    final masked = (device['fingerprint_masked'] as String?) ?? '';
    final lastSeen = device['last_heartbeat'] as String?;
    final subtitleParts = <String>[
      if (masked.isNotEmpty) masked,
      if (lastSeen != null) 'Last seen $lastSeen',
    ];
    return ListTile(
      leading: Icon(
        isSelf
            ? CupertinoIcons.device_phone_portrait
            : CupertinoIcons.desktopcomputer,
      ),
      title: Row(
        children: [
          Flexible(child: Text(name)),
          if (isSelf) ...[const SizedBox(width: 8), const _ThisDeviceChip()],
        ],
      ),
      subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(' · ')),
      trailing: isSelf
          ? null
          : TextButton(
              onPressed: _loading ? null : () => _deactivate(device),
              child: const Text(
                'Deactivate',
                style: TextStyle(color: AppTheme.danger),
              ),
            ),
    );
  }

  String _mask(String? full) {
    if (full == null || full.isEmpty) return '';
    if (full.length <= 12) return full;
    return '${full.substring(0, 8)}…${full.substring(full.length - 4)}';
  }
}

class _HeaderCard extends StatelessWidget {
  final String? activationCodeMasked;
  final int activeDevices;
  const _HeaderCard({
    required this.activationCodeMasked,
    required this.activeDevices,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(CupertinoIcons.lock),
        title: Text(
          'Activation code ${activationCodeMasked ?? ''}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '$activeDevices active device${activeDevices == 1 ? '' : 's'} · '
          'unlimited devices on this code',
        ),
      ),
    );
  }
}

class _OwnerSignInCard extends StatelessWidget {
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final bool signingIn;
  final VoidCallback onSignIn;

  const _OwnerSignInCard({
    required this.usernameController,
    required this.passwordController,
    required this.signingIn,
    required this.onSignIn,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(CupertinoIcons.person_crop_circle_badge_checkmark),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Owner sign-in required',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Managing devices is an owner action. Sign in with the shop '
              'owner account (the same phone number and password used on '
              'the web app). Your session is kept in memory only.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: usernameController,
              enabled: !signingIn,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Owner phone number',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              enabled: !signingIn,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => onSignIn(),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: signingIn ? null : onSignIn,
                icon: signingIn
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(CupertinoIcons.lock_open),
                label: const Text('Sign in'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  const _ErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      border: Border.all(color: AppDesign.danger.withValues(alpha: 0.4)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  CupertinoIcons.exclamationmark_triangle,
                  color: AppTheme.danger,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Cannot load devices',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(message),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onRetry, child: const Text('Retry')),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThisDeviceChip extends StatelessWidget {
  const _ThisDeviceChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppDesign.blue.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        'This device',
        style: TextStyle(
          fontSize: 11,
          color: AppDesign.accent,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
