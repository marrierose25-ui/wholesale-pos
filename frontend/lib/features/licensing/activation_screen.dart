import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pos_local_engine/pos_local_engine.dart';

import '../../core/theme/app_design.dart';

class ActivationScreen extends StatefulWidget {
  final VoidCallback onActivated;
  final String? errorMessage;
  final Future<String> Function() hardwareIdProvider;

  /// Mobile-only: validates a typed/pasted license code, persists it on success
  /// and returns null; returns an error message on failure (nothing persisted).
  final Future<String?> Function(String code)? onActivateWithCode;

  /// When true (phones/tablets) show the manual code-entry UI instead of the
  /// desktop "place the license.key file next to the app" instruction.
  final bool showCodeEntry;

  const ActivationScreen({
    super.key,
    required this.onActivated,
    this.errorMessage,
    this.hardwareIdProvider = LicenseValidator.getHardwareId,
    this.onActivateWithCode,
    this.showCodeEntry = false,
  });

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  String _hardwareId = 'Loading...';
  final _codeController = TextEditingController();
  String? _submitError;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    widget.hardwareIdProvider().then((id) {
      if (mounted) setState(() => _hardwareId = id);
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final onActivateWithCode = widget.onActivateWithCode;
    if (onActivateWithCode == null) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    final error = await onActivateWithCode(_codeController.text);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _submitError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayError = _submitError ?? widget.errorMessage;
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              // ConstrainedBox (not a fixed width) so the card shrinks to fit a
              // phone instead of overflowing at narrow widths.
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: GlassCard(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: AppDesign.buttonGradient,
                          boxShadow: [AppDesign.blueGlow()],
                        ),
                        child: const Icon(
                          CupertinoIcons.lock_shield,
                          size: 42,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'License Activation',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppDesign.textHi,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This software requires a valid license to run.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppDesign.textLo),
                      ),
                      if (displayError != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          displayError,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppDesign.danger,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      if (widget.showCodeEntry)
                        ..._buildCodeEntry(context)
                      else
                        ..._buildDesktopInstructions(context),
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

  List<Widget> _buildCodeEntry(BuildContext context) {
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Enter your activation code:',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: AppDesign.textHi,
          ),
        ),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _codeController,
        minLines: 2,
        maxLines: 4,
        autocorrect: false,
        enabled: !_submitting,
        decoration: const InputDecoration(
          hintText:
              'Your provider sends this code once per shop, e.g.\n'
              'MERCA-7Q2F-9K3X-4D8M-BN',
        ),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          color: AppDesign.textHi,
        ),
      ),
      const SizedBox(height: 16),
      if (_submitting)
        const SizedBox(
          height: 52,
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
          ),
        )
      else
        GlowButton(
          label: 'Activate',
          icon: CupertinoIcons.bolt_fill,
          onPressed: _submit,
        ),
      const SizedBox(height: 16),
      Text(
        'One code covers your whole business — activate as many devices as '
        'you need. If you change device, deactivate the old one under '
        'Settings → Devices — no need to contact your provider.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: AppDesign.textLo),
      ),
    ];
  }

  List<Widget> _buildDesktopInstructions(BuildContext context) {
    return [
      const Text(
        'Your Device Hardware ID:',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          _hardwareId,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      const SizedBox(height: 24),
      const Text(
        'Send this ID to your provider. Place the license.key file next to the '
        'app and click Retry.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12),
      ),
      const SizedBox(height: 24),
      SizedBox(
        width: double.infinity,
        height: 50,
        child: FilledButton(
          onPressed: widget.onActivated,
          child: const Text('Retry Activation'),
        ),
      ),
    ];
  }
}
