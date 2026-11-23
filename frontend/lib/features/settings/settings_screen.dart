import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:pos_contracts/pos_contracts.dart' hide AppBackend;
import 'package:pos_local_engine/pos_local_engine.dart' show ActivationClient;

import '../../core/backend/app_backend.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/sync/sync_runtime.dart';
import '../../core/sync/sync_status.dart';
import 'devices_screen.dart';

class SettingsScreen extends StatefulWidget {
  final User currentUser;
  final AppBackend backend;
  final bool isDarkMode;
  final VoidCallback onToggleTheme;
  final VoidCallback onLogout;
  final SyncRuntime? syncRuntime;

  const SettingsScreen({
    super.key,
    required this.currentUser,
    required this.backend,
    required this.isDarkMode,
    required this.onToggleTheme,
    required this.onLogout,
    this.syncRuntime,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isExporting = false;
  bool _isImporting = false;
  bool _rememberLogin = true;
  bool _isSyncing = false;

  bool get _isOwner => widget.currentUser.role == 'OWNER';
  bool get _supportsLocalDataOps => widget.backend.supportsLocalDataOps;

  @override
  void initState() {
    super.initState();
    _loadRememberPreference();
  }

  Future<void> _loadRememberPreference() async {
    final value = await widget.backend.getSetting(SessionStore.rememberKey);
    if (!mounted) return;
    // Persistent sign-in is ON by default; only an explicit '0' disables it.
    setState(() => _rememberLogin = value != '0');
  }

  Future<void> _toggleRemember(bool value) async {
    setState(() => _rememberLogin = value);
    await widget.backend.setSetting(
      SessionStore.rememberKey,
      value ? '1' : '0',
    );
    // Turning it off drops any persisted session so it cannot auto-resume.
    if (!value) await widget.backend.session.clear();
  }

  Future<void> _exportData() async {
    if (!_supportsLocalDataOps) return;
    setState(() => _isExporting = true);
    try {
      final localData = (widget.backend as LocalDataOpsProvider).localDataOps;
      final path = await localData.exportBackup(userId: widget.currentUser.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backup saved to: $path'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _importData() async {
    if (!_supportsLocalDataOps) return;
    // Use file_selector for picking files - available on mobile/desktop
    final typeGroup = XTypeGroup(label: 'JSON Backup', extensions: ['json']);
    final file = await openFile(acceptedTypeGroups: [typeGroup]);

    if (file == null) return;
    if (!mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore Data?'),
        content: const Text(
          'WARNING: This will completely delete all current sales, products, '
          'and users (including passwords), replacing them with the backup '
          'data. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore Data'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isImporting = true);
    try {
      final localData = (widget.backend as LocalDataOpsProvider).localDataOps;
      await localData.restoreBackup(file.path, userId: widget.currentUser.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Data restored successfully. Restart the app to refresh all '
              'screens.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _openDevicesScreen() async {
    if (!_supportsLocalDataOps) return;
    final localData = (widget.backend as LocalDataOpsProvider).localDataOps;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DevicesScreen(
          activationCodeProvider: localData.activationCode,
          fingerprintProvider: localData.deviceFingerprint,
          client: ActivationClient(),
        ),
      ),
    );
  }

  /// One manual cycle, forced to download as well as upload. The regular timer
  /// pulls every couple of minutes, so this is the "I want it now" action.
  Future<void> _syncNow() async {
    final runtime = widget.syncRuntime;
    if (runtime == null || _isSyncing) return;
    setState(() => _isSyncing = true);
    try {
      final result = await runtime.service.syncNow(forcePull: true);
      if (!mounted) return;
      final status = runtime.service.status.value;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.ok ? status.summary : result.error ?? 'Sync failed.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  /// Redeems the shop's activation code on this device. Without it a PC that
  /// only holds a legacy `license.key` cannot sync at all: the file carries no
  /// tenant, so the gateway refuses it. Data on this device is untouched.
  Future<void> _activateThisDevice() async {
    if (!_supportsLocalDataOps) return;
    final localData = (widget.backend as LocalDataOpsProvider).localDataOps;
    final code = await showDialog<String>(
      context: context,
      builder: (context) => const _ActivationCodeDialog(),
    );
    if (code == null || code.trim().isEmpty) return;

    setState(() => _isSyncing = true);
    try {
      final result = await localData.redeemActivationCode(code);
      if (!mounted) return;
      if (!result.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Activation failed.')),
        );
        return;
      }

      final runtime = widget.syncRuntime;
      final sync = runtime == null
          ? null
          : await runtime.service.syncNow(forcePull: true);
      if (!mounted) return;
      final applied = sync?.applied ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            applied > 0
                ? 'This device is activated · $applied record(s) downloaded from your other devices.'
                : 'This device is activated for cloud sync.',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Widget _syncCard(SyncStatus status) {
    final failing = status.isFailing;
    final IconData icon;
    if (!status.configured) {
      icon = CupertinoIcons.wifi_exclamationmark;
    } else if (failing) {
      icon = CupertinoIcons.wifi_exclamationmark;
    } else if (status.isConnected) {
      icon = CupertinoIcons.checkmark_circle;
    } else {
      icon = CupertinoIcons.arrow_2_circlepath;
    }

    final queued = status.queued;
    final subtitle = queued > 0
        ? '${status.summary}\n$queued change${queued == 1 ? '' : 's'} waiting to upload.'
        : status.summary;

    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              icon,
              color: failing ? AppTheme.danger : AppDesign.accent,
            ),
            title: const Text('Cloud Sync'),
            subtitle: Text(subtitle),
            isThreeLine: queued > 0,
            trailing: _isSyncing
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(CupertinoIcons.arrow_2_circlepath),
                    tooltip: 'Sync now',
                    onPressed: status.configured ? _syncNow : null,
                  ),
          ),
          if (_isOwner && status.authenticationFailed) ...[
            const Divider(height: 1, indent: 56),
            ListTile(
              leading: const Icon(CupertinoIcons.lock),
              title: const Text('Activate this device'),
              subtitle: const Text(
                'Paste the shop activation code once. Sales already recorded '
                "here stay, and every device's transactions download on the "
                'next sync.',
              ),
              isThreeLine: true,
              trailing: const Icon(CupertinoIcons.chevron_right),
              onTap: _isSyncing ? null : _activateThisDevice,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _changePassword() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => _ChangePasswordDialog(
        userRepository: widget.backend.users,
        userId: widget.currentUser.id,
        role: widget.currentUser.role,
      ),
    );
    if (changed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password changed successfully.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: AppBackground(
        child: CustomScrollView(
          slivers: [
            IosLargeTitle.sliver(context, title: 'Settings'),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: AppDesign.buttonGradient,
                        ),
                        child: Center(
                          child: Text(
                            widget.currentUser.username.isEmpty
                                ? '?'
                                : widget.currentUser.username[0].toUpperCase(),
                            style: const TextStyle(
                              color: AppDesign.onBlue,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      title: Text(
                        widget.currentUser.username,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text('Role: ${widget.currentUser.role}'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // iOS grouped-list section label: small, secondary, quiet.
                  Text(
                    'Appearance',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: AppDesign.textLo,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: SwitchListTile(
                      secondary: Icon(
                        widget.isDarkMode
                            ? CupertinoIcons.moon
                            : CupertinoIcons.sun_max,
                      ),
                      title: const Text('Dark Mode'),
                      value: widget.isDarkMode,
                      onChanged: (value) => widget.onToggleTheme(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Account',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: AppDesign.textLo,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(
                            CupertinoIcons.lock_rotation_open,
                          ),
                          title: const Text('Change Password'),
                          subtitle: const Text('Update your sign-in password'),
                          trailing: const Icon(CupertinoIcons.chevron_right),
                          onTap: _changePassword,
                        ),
                        if (_isOwner) ...[
                          const Divider(height: 1, indent: 56),
                          ListTile(
                            leading: const Icon(CupertinoIcons.desktopcomputer),
                            title: const Text('My devices'),
                            subtitle: const Text(
                              'See which phones and PCs are using your activation '
                              'code, deactivate a lost one, or redeem a seat voucher.',
                            ),
                            trailing: const Icon(CupertinoIcons.chevron_right),
                            onTap: _isSyncing ? null : _openDevicesScreen,
                          ),
                        ],
                        const Divider(height: 1, indent: 56),
                        SwitchListTile(
                          secondary: const Icon(
                            CupertinoIcons.square_arrow_right,
                          ),
                          title: const Text('Stay signed in on this PC'),
                          subtitle: const Text(
                            'Reopen the app straight to the register without '
                            're-entering the password for 12 hours. Off by default '
                            'for shared tills.',
                          ),
                          value: _rememberLogin,
                          onChanged: _toggleRemember,
                        ),
                        const Divider(height: 1, indent: 56),
                        ListTile(
                          leading: const Icon(
                            CupertinoIcons.arrow_right_to_line,
                            color: AppTheme.danger,
                          ),
                          title: const Text(
                            'Logout',
                            style: TextStyle(color: AppTheme.danger),
                          ),
                          onTap: widget.onLogout,
                        ),
                      ],
                    ),
                  ),
                  if (widget.syncRuntime != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Cloud Sync',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppDesign.textLo,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ValueListenableBuilder<SyncStatus>(
                      valueListenable: widget.syncRuntime!.service.status,
                      builder: (context, status, _) => _syncCard(status),
                    ),
                  ],
                  if (_isOwner) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Data Management',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppDesign.textLo,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    GlassCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          ListTile(
                            leading: Icon(
                              CupertinoIcons.square_arrow_down,
                              color: AppDesign.accent,
                            ),
                            title: const Text('Export Data (Backup)'),
                            subtitle: const Text(
                              'Owner only. The backup includes password hashes, so '
                              'store it securely.',
                            ),
                            trailing: _isExporting
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(CupertinoIcons.chevron_right),
                            onTap: _isExporting ? null : _exportData,
                          ),
                          const Divider(height: 1, indent: 56),
                          ListTile(
                            leading: const Icon(
                              CupertinoIcons.square_arrow_up,
                              color: AppDesign.warning,
                            ),
                            title: const Text('Restore Data (Import)'),
                            subtitle: const Text(
                              'Restore from a previous JSON backup',
                            ),
                            trailing: _isImporting
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(CupertinoIcons.chevron_right),
                            onTap: _isImporting ? null : _importData,
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_supportsLocalDataOps) ...[
                    const SizedBox(height: 24),
                    Center(
                      child: Text(
                        'Wholesale POS • Database schema v${(widget.backend as LocalDataOpsProvider).localDataOps.schemaVersion}',
                        style: TextStyle(color: AppTheme.muted, fontSize: 12),
                      ),
                    ),
                  ],
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Provider for LocalDataOps operations on native platform.
abstract class LocalDataOpsProvider {
  LocalDataOps get localDataOps;
}

/// Asks for the shop's activation code. The value is returned to the caller,
/// which redeems it — a code is a credential, so nothing is logged or shown
/// again once the device is activated.
class _ActivationCodeDialog extends StatefulWidget {
  const _ActivationCodeDialog();

  @override
  State<_ActivationCodeDialog> createState() => _ActivationCodeDialogState();
}

class _ActivationCodeDialogState extends State<_ActivationCodeDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final maxBodyHeight = (media.size.height - keyboard - 200).clamp(
      120.0,
      420.0,
    );
    return AlertDialog(
      title: const Text('Activate this device'),
      content: MediaQuery(
        data: media.copyWith(viewInsets: EdgeInsets.zero),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 420, maxHeight: maxBodyHeight),
          child: SingleChildScrollView(
            clipBehavior: Clip.none,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enter the activation code from your shop. This device joins '
                  "your shop's cloud account, so sales recorded on your other "
                  'phones and PCs appear here.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Activation Code',
                  ),
                  onSubmitted: (value) => Navigator.of(context).pop(value),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Activate'),
        ),
      ],
    );
  }
}

/// Change password dialog for native platform.
class _ChangePasswordDialog extends StatefulWidget {
  final UserRepository userRepository;
  final String userId;
  final String role;

  const _ChangePasswordDialog({
    required this.userRepository,
    required this.userId,
    required this.role,
  });

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final TextEditingController _currentController = TextEditingController();
  final TextEditingController _newController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  bool _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final current = _currentController.text;
    final next = _newController.text;
    final min = UserRepository.minPasswordLengthFor(widget.role);
    if (next.length < min) {
      setState(() => _error = 'New password must be at least $min characters.');
      return;
    }
    if (next != _confirmController.text) {
      setState(() => _error = 'New passwords do not match.');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await widget.userRepository.changePassword(
        userId: widget.userId,
        currentPassword: current,
        newPassword: next,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final maxBodyHeight = (media.size.height - keyboard - 200).clamp(
      120.0,
      420.0,
    );
    return AlertDialog(
      title: const Text('Change Password'),
      content: MediaQuery(
        data: media.copyWith(viewInsets: EdgeInsets.zero),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 360, maxHeight: maxBodyHeight),
          child: SingleChildScrollView(
            clipBehavior: Clip.none,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _currentController,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Current Password',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _newController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New Password'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirmController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm New Password',
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: AppTheme.danger,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _submit,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
