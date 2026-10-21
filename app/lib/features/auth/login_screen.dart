import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/user_repository.dart';
import '../../core/theme/app_theme.dart';

class LoginScreen extends StatefulWidget {
  final UserRepository userRepository;
  final Function(User) onLoginSuccess;

  const LoginScreen({
    super.key,
    required this.userRepository,
    required this.onLoginSuccess,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _errorMessage;
  bool _isLoading = false;
  bool _checkingFirstRun = true;
  bool _isFirstRun = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _checkFirstRun();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _checkFirstRun() async {
    try {
      final hasUsers = await widget.userRepository.hasUsers();
      if (!mounted) return;
      setState(() {
        _isFirstRun = !hasUsers;
        _checkingFirstRun = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checkingFirstRun = false;
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty) {
      setState(() => _errorMessage = 'Please enter a username.');
      return;
    }
    if (password.isEmpty) {
      setState(() => _errorMessage = 'Please enter a password.');
      return;
    }
    if (_isFirstRun) {
      if (password.length < UserRepository.minimumPasswordLength) {
        setState(
          () => _errorMessage =
              'Password must be at least '
              '${UserRepository.minimumPasswordLength} characters.',
        );
        return;
      }
      if (password != _confirmController.text) {
        setState(() => _errorMessage = 'Passwords do not match.');
        return;
      }
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final User? user;
      if (_isFirstRun) {
        user = await widget.userRepository.createFirstOwner(username, password);
      } else {
        user = await widget.userRepository.authenticate(username, password);
      }

      if (!mounted) return;
      if (user == null) {
        setState(() => _errorMessage = 'Invalid username or password.');
        return;
      }
      widget.onLoginSuccess(user);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _errorMessage = e.toString().replaceAll('Exception: ', ''),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingFirstRun) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final title = _isFirstRun
        ? 'Create Owner Account'
        : 'Sign in to your account';
    final buttonLabel = _isFirstRun ? 'Create Account' : 'Sign In';

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            width: 400,
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.storefront, size: 48, color: AppTheme.primary),
                const SizedBox(height: 24),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_isFirstRun) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Set up the first owner account for this business.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.muted, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 32),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(labelText: 'Username'),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    suffixIcon: IconButton(
                      tooltip: _obscurePassword
                          ? 'Show password'
                          : 'Hide password',
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  onSubmitted: (_) {
                    if (!_isFirstRun) _submit();
                  },
                ),
                if (_isFirstRun) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _confirmController,
                    obscureText: _obscurePassword,
                    decoration: const InputDecoration(
                      labelText: 'Confirm Password',
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ],
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _errorMessage!,
                    style: const TextStyle(
                      color: AppTheme.danger,
                      fontSize: 13,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _submit,
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(buttonLabel),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
