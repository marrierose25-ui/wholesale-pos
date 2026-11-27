import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_design.dart';

/// The web/PWA provisioning step: the browser has no device license, so the
/// shop's activation code (its tenant identity) is pasted once here before any
/// cashier can sign in.
///
/// [onSubmit] hands the trimmed code to the backend, which verifies it against
/// `pos-api` and persists it (returning a human-readable error, or null on
/// success). Only on success does the widget call [onReady], letting the shell
/// fall through to the login screen. This widget is platform-free — it imports
/// no storage — so it is safe in the browser graph; all persistence lives in
/// the [CloudBackend] closure that builds it.
class WebActivationGate extends StatefulWidget {
  final Future<String?> Function(String code) onSubmit;
  final VoidCallback onReady;

  const WebActivationGate({
    super.key,
    required this.onSubmit,
    required this.onReady,
  });

  @override
  State<WebActivationGate> createState() => _WebActivationGateState();
}

class _WebActivationGateState extends State<WebActivationGate> {
  final _codeController = TextEditingController();
  String? _errorMessage;
  bool _isChecking = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _errorMessage = 'Enter your shop activation code.');
      return;
    }
    setState(() {
      _isChecking = true;
      _errorMessage = null;
    });
    final error = await widget.onSubmit(code);
    if (!mounted) return;
    setState(() => _isChecking = false);
    if (error != null) {
      setState(() => _errorMessage = error);
      return;
    }
    widget.onReady();
  }

  @override
  Widget build(BuildContext context) {
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
                          CupertinoIcons.bag_fill,
                          size: 34,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'Connect your shop',
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
                        'Paste this business\'s activation code once to link '
                        'this browser to your cloud till.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppDesign.textLo,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 30),
                      TextField(
                        controller: _codeController,
                        style: TextStyle(color: AppDesign.textHi),
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'Activation code',
                          hintText: 'MERCA-XXXX-XXXX-XXXX-XX',
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
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
                      if (_isChecking)
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
                          label: 'Connect',
                          icon: CupertinoIcons.link,
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
