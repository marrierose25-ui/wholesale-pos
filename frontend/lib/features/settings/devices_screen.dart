import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pos_local_engine/pos_local_engine.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';

/// Buyer-facing screen for the seat-based licensing (Phase 17 / 17b).
///
/// Shows every device currently occupying a seat on the shop's activation
/// code, lets the buyer deactivate one (e.g. a lost phone) so the seat is
/// freed for a replacement, and lets the buyer redeem a one-shot seat
/// voucher issued by Umer after an out-of-band payment.
///
/// All actions go through [ActivationClient] against the licensing Edge
/// Function. The Edge Function requires a valid (activation_code,
/// device_fingerprint) pair from a device that already holds an active seat
/// before it will respond, so this screen only works after the current
/// device has been activated with a short activation code (not the legacy
/// file-based license).
class DevicesScreen extends StatefulWidget {
  final Future<String?> Function() activationCodeProvider;
  final Future<String> Function() fingerprintProvider;
  final ActivationClient client;

  /// Optional hook so the caller can delete the persisted activation_code +
  /// license_code from local settings after the last seat is deactivated.
  /// In practice this screen refuses to deactivate "this device" so it is
  /// only used defensively.
  const DevicesScreen({
    super.key,
    required this.activationCodeProvider,
    required this.fingerprintProvider,
    required this.client,
  });

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  bool _loading = true;
  String? _error;
  String? _activationCode;
  String _fingerprint = '';
  List<Map<String, dynamic>> _devices = const [];
  int? _seatLimit;
  int? _seatsUsed;

  final TextEditingController _voucherController = TextEditingController();
  bool _redeeming = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _voucherController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    if (!widget.client.isConfigured) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'Licensing server is not configured for this build. Seat '
            'management is only available in builds compiled with '
            '--dart-define=WHOLESALE_POS_LICENSE_FN_URL=<url>.';
      });
      return;
    }
    final code = await widget.activationCodeProvider();
    final fp = await widget.fingerprintProvider();
    if (!mounted) return;
    if (code == null || code.isEmpty) {
      setState(() {
        _loading = false;
        _activationCode = null;
        _fingerprint = fp;
        _error =
            'This install was activated with a license file, not an '
            'activation code, so there are no remote seats to manage. To '
            'switch to the code-based model, activate again with the '
            'activation code Umer sent you.';
      });
      return;
    }
    final response = await widget.client.listDevices(
      activationCode: code,
      deviceFingerprint: fp,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _activationCode = code;
      _fingerprint = fp;
      if (response.ok) {
        _devices = response.devices ?? const [];
        _seatLimit = response.seatLimit;
        _seatsUsed = response.seatsUsed;
        _error = null;
      } else {
        _error = response.error;
      }
    });
  }

  Future<void> _deactivate(Map<String, dynamic> device) async {
    final targetFingerprint = device['device_fingerprint'] as String?;
    if (targetFingerprint == null) return;
    final name = (device['device_name'] as String?) ?? 'this device';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Deactivate device?'),
        content: Text(
          '"$name" will lose its seat as soon as it next contacts the '
          'licensing server. The seat becomes free for another device. '
          'You can reactivate it later if the deactivation was a mistake.',
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
    final response = await widget.client.deactivateDevice(
      activationCode: _activationCode!,
      requestingFingerprint: _fingerprint,
      targetFingerprint: targetFingerprint,
    );
    if (!mounted) return;
    if (!response.ok) {
      setState(() => _loading = false);
      _showSnack(response.error ?? 'Deactivation failed.', danger: true);
      return;
    }
    _showSnack('Device deactivated. Seat is now free.');
    await _load();
  }

  Future<void> _redeemVoucher() async {
    final code = _voucherController.text.trim();
    if (code.isEmpty) {
      _showSnack('Enter the voucher code from Umer first.', danger: true);
      return;
    }
    setState(() => _redeeming = true);
    final response = await widget.client.redeemVoucher(
      activationCode: _activationCode!,
      deviceFingerprint: _fingerprint,
      voucherCode: code,
    );
    if (!mounted) return;
    setState(() => _redeeming = false);
    if (!response.ok) {
      _showSnack(response.error ?? 'Voucher redemption failed.', danger: true);
      return;
    }
    final added = response.seatsAdded ?? 0;
    final newLimit = response.newSeatLimit;
    _voucherController.clear();
    _showSnack(
      newLimit == null
          ? 'Voucher applied: $added seat(s) added.'
          : 'Voucher applied: $added seat(s) added. New limit: $newLimit.',
    );
    await _load();
  }

  void _showSnack(String message, {bool danger = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: danger ? AppTheme.danger : null,
      ),
    );
  }

  String _mask(String? full) {
    if (full == null || full.isEmpty) return '';
    if (full.length <= 12) return full;
    return '${full.substring(0, 8)}…${full.substring(full.length - 4)}';
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
                    if (_activationCode != null) ...[
                      _HeaderCard(
                        activationCodeMasked: _mask(_activationCode),
                        seatsUsed: _seatsUsed,
                        seatLimit: _seatLimit,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_error != null) ...[
                      _ErrorCard(message: _error!, onRetry: _load),
                      const SizedBox(height: 16),
                    ],
                    if (_error == null && _activationCode != null)
                      ..._deviceTiles(),
                    if (_error == null && _activationCode != null) ...[
                      const SizedBox(height: 24),
                      const Text(
                        'Add more seats',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 8),
                      GlassCard(
                        padding: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Bought extra seats from Umer? Paste the '
                                'voucher code (starts with V-) below. It '
                                'works once and permanently raises your seat '
                                'limit for this activation code.',
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _voucherController,
                                enabled: !_redeeming,
                                decoration: const InputDecoration(
                                  labelText: 'Voucher code',
                                  hintText: 'V-1A2B3C4D',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Align(
                                alignment: Alignment.centerRight,
                                child: FilledButton.icon(
                                  onPressed: _redeeming ? null : _redeemVoucher,
                                  icon: _redeeming
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(CupertinoIcons.number),
                                  label: const Text('Redeem'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'How seats work',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 8),
                      GlassCard(
                        padding: EdgeInsets.zero,
                        child: const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Each device that redeems your activation code '
                            'takes one seat. Your seat limit is the number '
                            'of phones or PCs that can be active at the '
                            'same time. Reinstalling the app on the same '
                            'device reuses its existing seat. If a device '
                            'is lost, deactivate it here and activate the '
                            'replacement — no need to contact Umer.',
                          ),
                        ),
                      ),
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
            title: Text('No devices listed yet.'),
          ),
        ),
      ];
    }
    final tiles = <Widget>[
      const Text(
        'Active seats',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
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
    return tiles;
  }

  Widget _buildDeviceTile(Map<String, dynamic> device) {
    final fp = device['device_fingerprint'] as String? ?? '';
    final isSelf = fp.isNotEmpty && fp == _fingerprint;
    final name = (device['device_name'] as String?) ?? 'Unnamed device';
    final lastSeen = device['last_seen_at'] as String?;
    final subtitleParts = <String>[_mask(fp)];
    if (lastSeen != null) subtitleParts.add('Last seen $lastSeen');
    return ListTile(
      leading: Icon(isSelf ? CupertinoIcons.device_phone_portrait : CupertinoIcons.desktopcomputer),
      title: Row(
        children: [
          Flexible(child: Text(name)),
          if (isSelf) ...[const SizedBox(width: 8), const _ThisDeviceChip()],
        ],
      ),
      subtitle: Text(subtitleParts.join(' · ')),
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
}

class _HeaderCard extends StatelessWidget {
  final String? activationCodeMasked;
  final int? seatsUsed;
  final int? seatLimit;
  const _HeaderCard({
    required this.activationCodeMasked,
    required this.seatsUsed,
    required this.seatLimit,
  });

  @override
  Widget build(BuildContext context) {
    final usage = seatsUsed != null && seatLimit != null
        ? '$seatsUsed of $seatLimit seats in use'
        : 'Seat usage loading…';
    return GlassCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(CupertinoIcons.lock),
        title: Text(
          'Activation code ${activationCodeMasked ?? ''}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(usage),
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
            Row(
              children: const [
                Icon(CupertinoIcons.exclamationmark_triangle, color: AppTheme.danger),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Cannot load seat list',
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
