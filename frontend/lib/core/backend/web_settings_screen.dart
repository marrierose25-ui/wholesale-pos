import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pos_contracts/pos_contracts.dart' hide AppBackend;

import 'app_backend.dart';
import '../theme/app_design.dart';
import '../theme/app_theme.dart';

/// The web/PWA Settings screen.
///
/// Mirrors the native `SettingsScreen`'s account controls (change password,
/// "stay signed in", logout) and the theme switch, but deliberately omits the
/// native-only, `dart:io`-coupled tiles — local SQLite backup/restore and the
/// device-seat manager — because on the browser the cloud is authoritative and
/// those files do not exist here. It talks to storage only through the
/// [AppBackend] seam, so it stays platform-free.
class WebSettingsScreen extends StatefulWidget {
  final AppBackend backend;
  final User currentUser;
  final VoidCallback onLogout;
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const WebSettingsScreen({
    super.key,
    required this.backend,
    required this.currentUser,
    required this.onLogout,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<WebSettingsScreen> createState() => _WebSettingsScreenState();
}

class _WebSettingsScreenState extends State<WebSettingsScreen> {
  bool _rememberLogin = true;

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
    // Turning it off drops the persisted session so it cannot auto-resume.
    if (!value) await widget.backend.session.clear();
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
      appBar: AppBar(title: const Text('Settings')),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
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
            const Text(
              'Appearance',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
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
            const Text(
              'Account',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 8),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(CupertinoIcons.lock_rotation_open),
                    title: const Text('Change Password'),
                    subtitle: const Text('Update your sign-in password'),
                    trailing: const Icon(CupertinoIcons.chevron_right),
                    onTap: _changePassword,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(CupertinoIcons.square_arrow_right),
                    title: const Text('Stay signed in in this browser'),
                    subtitle: const Text(
                      'Reopen the app straight to the register without '
                      're-entering the password for 12 hours. Off by default '
                      'for shared tills.',
                    ),
                    value: _rememberLogin,
                    onChanged: _toggleRemember,
                  ),
                  const Divider(height: 1),
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
            const SizedBox(height: 24),
            Center(
              child: Text(
                'Wholesale POS • Cloud (browser)',
                style: TextStyle(color: AppTheme.muted, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
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
    // Three fields plus the keyboard do not fit a small phone, so cap the body
    // to the space above the keyboard and scroll it.
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
