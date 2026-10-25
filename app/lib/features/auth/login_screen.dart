import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/user_repository.dart';
import '../../core/theme/app_design.dart';

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
      final min = UserRepository.minPasswordLengthFor('OWNER');
      if (password.length < min) {
        setState(
          () => _errorMessage = 'Password must be at least $min characters.',
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
      return const Scaffold(
        body: AppBackground(child: Center(child: CircularProgressIndicator())),
      );
    }

    final title = _isFirstRun ? 'Create Owner Account' : 'Welcome back';
    final subtitle = _isFirstRun
        ? 'Set up the first owner account for this business.'
        : 'Sign in to your account';
    final buttonLabel = _isFirstRun ? 'Create Account' : 'Sign In';

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: GlassCard(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 74,
                        height: 74,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: AppDesign.buttonGradient,
                          boxShadow: [AppDesign.blueGlow()],
                        ),
                        child: const Icon(
                          Icons.storefront_rounded,
                          size: 34,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppDesign.textHi,
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppDesign.textLo,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 30),
                      TextField(
                        controller: _usernameController,
                        style: TextStyle(color: AppDesign.textHi),
                        decoration: const InputDecoration(
                          labelText: 'Username',
                        ),
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        style: TextStyle(color: AppDesign.textHi),
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
                            onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
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
                          style: TextStyle(color: AppDesign.textHi),
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
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppDesign.danger,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      const SizedBox(height: 26),
                      if (_isLoading)
                        const SizedBox(
                          height: 52,
                          child: Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                              ),
                            ),
                          ),
                        )
                      else
                        GlowButton(
                          label: buttonLabel,
                          icon: Icons.login_rounded,
                          onPressed: _submit,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
