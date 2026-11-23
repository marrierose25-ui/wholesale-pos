import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pos_contracts/pos_contracts.dart' hide AppBackend, kDefaultStaffPermissions;
import '../../core/auth/features.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';

class UserManagementScreen extends StatefulWidget {
  final UserRepository userRepository;
  final User currentUser;

  const UserManagementScreen({
    super.key,
    required this.userRepository,
    required this.currentUser,
  });

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  List<User> _users = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final users = await widget.userRepository.getAllUsers();
      if (!mounted) return;
      setState(() {
        _users = users;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showAddUserDialog() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => _AddUserDialog(
        userRepository: widget.userRepository,
        // A shop has exactly one owner, so the owner option is offered only
        // while that seat is free instead of failing at save time.
        ownerSeatTaken: _users.any((u) => u.role == 'OWNER'),
      ),
    );
    if (created == true && mounted) {
      await _loadUsers();
      _showMessage('User created.');
    }
  }

  Future<void> _showEditPermissionsDialog(User user) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _EditPermissionsDialog(
        userRepository: widget.userRepository,
        user: user,
      ),
    );
    if (saved == true && mounted) {
      await _loadUsers();
      _showMessage('Permissions updated for ${user.username}.');
    }
  }

  Future<void> _showEditPhoneDialog(User user) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _EditPhoneDialog(
        userRepository: widget.userRepository,
        user: user,
        actingUserId: widget.currentUser.id,
      ),
    );
    if (saved == true && mounted) {
      await _loadUsers();
      _showMessage('Phone number updated.');
    }
  }

  Future<void> _resetPassword(User user) async {
    final reset = await showDialog<bool>(
      context: context,
      builder: (context) => _ResetPasswordDialog(
        userRepository: widget.userRepository,
        targetUserId: user.id,
        actingUserId: widget.currentUser.id,
        username: user.username,
      ),
    );
    if (reset == true && mounted) {
      _showMessage('Password reset for ${user.username}.');
    }
  }

  Future<void> _toggleActive(User user) async {
    final activating = !user.isActive;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(activating ? 'Activate User?' : 'Deactivate User?'),
        content: Text(
          activating
              ? '${user.username} will be able to sign in again.'
              : '${user.username} will no longer be able to sign in. '
                    'Existing sales remain attributed to them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: activating ? null : AppTheme.danger,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(activating ? 'Activate' : 'Deactivate'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    try {
      await widget.userRepository.setUserActive(
        targetUserId: user.id,
        active: activating,
        actingUserId: widget.currentUser.id,
      );
      if (!mounted) return;
      await _loadUsers();
      _showMessage(activating ? 'User activated.' : 'User deactivated.');
    } catch (e) {
      if (mounted) {
        _showMessage(e.toString().replaceAll('Exception: ', ''));
      }
    }
  }

  Future<void> _deleteUser(User user) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account?'),
        content: Text(
          '${user.username} will be removed from this list and can no longer '
          'sign in. Sales, shifts and cash movements they already recorded '
          'stay in your reports.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    try {
      await widget.userRepository.deleteUser(
        targetUserId: user.id,
        actingUserId: widget.currentUser.id,
      );
      if (!mounted) return;
      await _loadUsers();
      _showMessage('Account deleted.');
    } catch (e) {
      if (mounted) {
        _showMessage(e.toString().replaceAll('Exception: ', ''));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 8),
            TextButton(onPressed: _loadUsers, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('User Management'),
        actions: [
          IconButton(icon: const Icon(CupertinoIcons.arrow_clockwise), onPressed: _loadUsers),
        ],
      ),
      body: AppBackground(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          itemCount: _users.length,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final user = _users[index];
            final isSelf = user.id == widget.currentUser.id;
            return GlassCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: user.role == 'OWNER'
                      ? AppDesign.blue
                      : AppDesign.textFaint,
                  foregroundColor: Colors.white,
                  child: const Icon(CupertinoIcons.person_fill),
                ),
                title: Text(
                  user.username,
                  style: TextStyle(
                    color: user.isActive ? null : AppTheme.muted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Text(isSelf ? '${user.role} (you)' : user.role),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (user.isDemo)
                      // The demo password is a per-install secret, so a fresh
                      // install has none the owner knows yet.
                      Tooltip(
                        message:
                            'Training account. Use Reset Password to set a '
                            'password before handing it to a trainee.',
                        child: const Chip(
                          label: Text('Demo'),
                          backgroundColor: AppDesign.blue,
                          labelStyle: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    if (!user.isActive)
                      const Chip(
                        label: Text('Disabled'),
                        backgroundColor: AppTheme.danger,
                        labelStyle: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    PopupMenuButton<String>(
                      tooltip: 'User actions',
                      onSelected: (value) {
                        if (value == 'phone') _showEditPhoneDialog(user);
                        if (value == 'reset') _resetPassword(user);
                        if (value == 'perms') _showEditPermissionsDialog(user);
                        if (value == 'toggle') _toggleActive(user);
                        if (value == 'delete') _deleteUser(user);
                      },
                      itemBuilder: (context) => [
                        if (!user.isDemo)
                          const PopupMenuItem(
                            value: 'phone',
                            child: Text('Edit phone'),
                          ),
                        const PopupMenuItem(
                          value: 'reset',
                          child: Text('Reset Password'),
                        ),
                        if (user.role != 'OWNER')
                          const PopupMenuItem(
                            value: 'perms',
                            child: Text('Permissions'),
                          ),
                        if (!isSelf && !user.isDemo)
                          PopupMenuItem(
                            value: 'toggle',
                            child: Text(
                              user.isActive ? 'Deactivate' : 'Activate',
                            ),
                          ),
                        // Only a disabled account can be removed, and only once
                        // it has been deactivated — that two-step keeps a
                        // mis-tap from destroying an active login.
                        if (!isSelf && !user.isDemo && !user.isActive)
                          PopupMenuItem(
                            value: 'delete',
                            child: const Text('Delete Account'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        // Explicit tag: the shell keeps every tab mounted in one IndexedStack,
        // so all FABs share a route subtree and the default tag collides.
        heroTag: 'fab-add-user',
        onPressed: _showAddUserDialog,
        icon: const Icon(CupertinoIcons.person_badge_plus),
        label: const Text('Add User'),
      ),
    );
  }
}

class _AddUserDialog extends StatefulWidget {
  final UserRepository userRepository;
  final bool ownerSeatTaken;

  const _AddUserDialog({
    required this.userRepository,
    required this.ownerSeatTaken,
  });

  @override
  State<_AddUserDialog> createState() => _AddUserDialogState();
}

class _AddUserDialogState extends State<_AddUserDialog> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  // Owner access is an all-access override; everyone else is defined purely by
  // the ticked feature set. Default to today's cashier matrix so a new staff
  // account is immediately usable and the owner can narrow it from there.
  bool _ownerAccess = false;
  final Set<String> _selected = {...kDefaultStaffPermissions};
  bool _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final role = _ownerAccess ? 'OWNER' : 'CASHIER';
    if (PhoneNumber.normalize(username) == null) {
      setState(() => _error = PhoneNumber.invalidMessage);
      return;
    }
    final min = UserRepository.minPasswordLengthFor(role);
    if (password.length < min) {
      setState(() => _error = 'Password must be at least $min characters.');
      return;
    }
    if (password != _confirmController.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await widget.userRepository.createUser(
        username,
        password,
        role,
        permissions: _ownerAccess ? const [] : _selected.toList(),
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
    return AlertDialog(
      title: const Text('Add New User'),
      content: SizedBox(
        width: 360,
        height: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _usernameController,
                autofocus: true,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone Number',
                  hintText: 'e.g. ${PhoneNumber.example}',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password (min 8, or 12 for owner)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirm Password',
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                value: _ownerAccess,
                title: const Text('Owner access (sees everything)'),
                subtitle: widget.ownerSeatTaken
                    ? const Text('This shop already has an owner account.')
                    : null,
                onChanged: widget.ownerSeatTaken
                    ? null
                    : (v) => setState(() => _ownerAccess = v ?? false),
              ),
              if (!_ownerAccess) ...[
                const SizedBox(height: 4),
                _FeaturePicker(
                  selected: _selected,
                  enabled: true,
                  onToggle: (key, value) => setState(() {
                    if (value) {
                      _selected.add(key);
                    } else {
                      _selected.remove(key);
                    }
                  }),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Owner accounts see every tab and bypass feature ticks.',
                    style: TextStyle(color: AppDesign.textLo, fontSize: 12),
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: AppTheme.danger, fontSize: 13),
                ),
              ],
            ],
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
              : const Text('Create User'),
        ),
      ],
    );
  }
}

/// A reusable tick list over [kGrantableFeatures]. When [enabled] is false the
/// whole grid is greyed and inert (used when "Owner access" overrides the
/// ticks). Money Tracking is an ordinary tick here — both backends check the
/// tick (or the OWNER role) themselves, so ticking it is what grants the tab.
class _FeaturePicker extends StatelessWidget {
  final Set<String> selected;
  final bool enabled;
  final void Function(String key, bool value) onToggle;

  const _FeaturePicker({
    required this.selected,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !enabled,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Visible features',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppDesign.textHi,
              ),
            ),
            const SizedBox(height: 4),
            for (final f in kGrantableFeatures)
              CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                value: selected.contains(f.key),
                title: Row(
                  children: [
                    Icon(f.icon, size: 18, color: AppDesign.textLo),
                    const SizedBox(width: 8),
                    Expanded(child: Text(f.label)),
                  ],
                ),
                onChanged: enabled ? (v) => onToggle(f.key, v ?? false) : null,
              ),
          ],
        ),
      ),
    );
  }
}

/// Edits an existing staff account's feature ticks. Owner rows are never shown
/// this dialog (the row action is hidden for them).
class _EditPermissionsDialog extends StatefulWidget {
  final UserRepository userRepository;
  final User user;

  const _EditPermissionsDialog({
    required this.userRepository,
    required this.user,
  });

  @override
  State<_EditPermissionsDialog> createState() => _EditPermissionsDialogState();
}

class _EditPermissionsDialogState extends State<_EditPermissionsDialog> {
  late final Set<String> _selected = {...widget.user.permissions};
  bool _isSaving = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await widget.userRepository.setUserPermissions(
        widget.user.id,
        _selected.toList(),
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
    return AlertDialog(
      title: Text('Permissions for ${widget.user.username}'),
      content: SizedBox(
        width: 360,
        height: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FeaturePicker(
                selected: _selected,
                enabled: !_isSaving,
                onToggle: (key, value) => setState(() {
                  if (value) {
                    _selected.add(key);
                  } else {
                    _selected.remove(key);
                  }
                }),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: AppTheme.danger, fontSize: 13),
                ),
              ],
            ],
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

class _ResetPasswordDialog extends StatefulWidget {
  final UserRepository userRepository;
  final String targetUserId;
  final String actingUserId;
  final String username;

  const _ResetPasswordDialog({
    required this.userRepository,
    required this.targetUserId,
    required this.actingUserId,
    required this.username,
  });

  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _passwordController.text;
    // Length is validated by the repository against the target user's role
    // (owner vs cashier), so the exact requirement is enforced server-side.
    if (password != _confirmController.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await widget.userRepository.resetPassword(
        targetUserId: widget.targetUserId,
        newPassword: password,
        actingUserId: widget.actingUserId,
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
    return AlertDialog(
      title: Text('Reset Password for ${widget.username}'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _passwordController,
              autofocus: true,
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
                style: const TextStyle(color: AppTheme.danger, fontSize: 13),
              ),
            ],
          ],
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
              : const Text('Reset Password'),
        ),
      ],
    );
  }
}

/// Lets the owner move an account onto a phone-number login (or change an
/// existing one). The demo account is excluded: it always signs in as `demo`.
class _EditPhoneDialog extends StatefulWidget {
  final UserRepository userRepository;
  final User user;
  final String actingUserId;

  const _EditPhoneDialog({
    required this.userRepository,
    required this.user,
    required this.actingUserId,
  });

  @override
  State<_EditPhoneDialog> createState() => _EditPhoneDialogState();
}

class _EditPhoneDialogState extends State<_EditPhoneDialog> {
  late final TextEditingController _phoneController = TextEditingController(
    text: widget.user.username,
  );
  bool _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final phone = PhoneNumber.normalize(_phoneController.text);
    if (phone == null) {
      setState(() => _error = PhoneNumber.invalidMessage);
      return;
    }
    if (phone == widget.user.username) {
      Navigator.of(context).pop(false);
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await widget.userRepository.setUserPhone(
        userId: widget.user.id,
        phone: phone,
        actingUserId: widget.actingUserId,
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
    return AlertDialog(
      title: const Text('Change Phone Number'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _phoneController,
              autofocus: true,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone Number',
                hintText: 'e.g. ${PhoneNumber.example}',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Text(
              'This is the number the account signs in with.',
              style: TextStyle(color: AppDesign.textLo, fontSize: 12),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: AppTheme.danger, fontSize: 13),
              ),
            ],
          ],
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
