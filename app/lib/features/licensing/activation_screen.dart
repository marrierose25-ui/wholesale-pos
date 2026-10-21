import 'package:flutter/material.dart';

import '../../core/licensing/license_validator.dart';

class ActivationScreen extends StatefulWidget {
  final VoidCallback onActivated;
  final String? errorMessage;

  const ActivationScreen({
    super.key,
    required this.onActivated,
    this.errorMessage,
  });

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  String _hardwareId = 'Loading...';

  @override
  void initState() {
    super.initState();
    LicenseValidator.getHardwareId().then(
      (id) => setState(() => _hardwareId = id),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Container(
          width: 500,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_person, size: 64, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                'License Activation',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'This software requires a valid license to run.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              if (widget.errorMessage != null) ...[
                const SizedBox(height: 16),
                Text(
                  widget.errorMessage!,
                  style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
              const SizedBox(height: 24),
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
                'Send this ID to your provider. Place the license.key file next to the app and click Retry.',
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
            ],
          ),
        ),
      ),
    );
  }
}
