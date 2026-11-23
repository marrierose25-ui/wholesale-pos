import 'package:material_ui/material_ui.dart';
import 'package:pos_core/pos_core.dart';
import 'package:pos_contracts/pos_contracts.dart' hide AppBackend;

import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/date_formatter.dart';

/// Opens the rich "Sale Details" popup for [sale] in a dialog — the single
/// source of truth for inspecting a sale, shared by Sales History's day
/// drill-down. Shows the header (with VOIDED / VOID REQUESTED chips), the
/// date / cashier / customer / payment / status rows, the line items, the
/// total, and — for a live sale — the Void (owner) or Request Void (cashier)
/// action. [onChanged] fires after a successful void so the caller can
/// refresh its list.
Future<void> showSaleDetails({
  required BuildContext context,
  required Sale sale,
  required SaleRepository repository,
  required User currentUser,
  VoidCallback? onChanged,
}) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => _SaleDetailsDialog(
      sale: sale,
      repository: repository,
      currentUser: currentUser,
      onChanged: onChanged,
    ),
  );
}

class _SaleDetailsDialog extends StatefulWidget {
  final Sale sale;
  final SaleRepository repository;
  final User currentUser;
  final VoidCallback? onChanged;

  const _SaleDetailsDialog({
    required this.sale,
    required this.repository,
    required this.currentUser,
    this.onChanged,
  });

  @override
  State<_SaleDetailsDialog> createState() => _SaleDetailsDialogState();
}

class _SaleDetailsDialogState extends State<_SaleDetailsDialog> {
  bool _busy = false;

  Future<void> _voidSale() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _VoidSaleDialog(),
    );
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.repository.voidSale(
        widget.sale.id,
        widget.currentUser.id,
        reason,
      );
      widget.onChanged?.call();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
    }
  }

  Future<void> _requestVoid() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _VoidSaleDialog(requestMode: true),
    );
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.repository.requestVoid(
        widget.sale.id,
        widget.currentUser.id,
        reason,
      );
      widget.onChanged?.call();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sale = widget.sale;
    final isVoided = sale.status == 'VOIDED';
    final isOwner = widget.currentUser.role == 'OWNER';

    return AlertDialog(
      title: Row(
        children: [
          const Flexible(child: Text('Sale Details')),
          if (isVoided) ...[
            const SizedBox(width: 8),
            const Chip(label: Text('VOIDED')),
          ] else if (sale.hasPendingVoidRequest) ...[
            const SizedBox(width: 8),
            const Chip(label: Text('VOID REQUESTED')),
          ],
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailRow('Date', formatAddisDateTime(sale.createdAt)),
              _detailRow('Cashier', sale.cashierName ?? 'Unknown'),
              if (sale.customerName != null &&
                  sale.customerName!.trim().isNotEmpty)
                _detailRow('Customer', sale.customerName!),
              _detailRow(
                'Payment',
                sale.paymentMethod == 'CASH'
                    ? 'Cash'
                    : sale.paymentMethod == 'LOAN'
                    ? 'Loan'
                    : 'Bank Transfer',
              ),
              _detailRow('Status', isVoided ? 'Voided' : 'Completed'),
              const Divider(),
              ...sale.items.map(
                (item) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: Text(item.productNameSnapshot)),
                          Text(
                            MoneyUtils.formatBr(item.lineTotalMinorUnits),
                            style: const TextStyle(
                              fontWeight: FontWeight.w500,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '${item.quantityText} @ '
                        '${MoneyUtils.formatBr(item.unitPriceSnapshotMinorUnits)} each'
                        '${item.hasManualLineTotal ? ' (manual amount)' : ''}',
                        style: TextStyle(color: AppDesign.textLo, fontSize: 12),
                      ),
                      if (item.notes != null && item.notes!.trim().isNotEmpty)
                        Text(
                          'Note: ${item.notes}',
                          style: TextStyle(
                            color: AppDesign.textLo,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'TOTAL:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    MoneyUtils.formatBr(sale.totalMinorUnits),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              if (isVoided && sale.voidReason != null) ...[
                const Divider(),
                Text(
                  'Voided: ${sale.voidReason}',
                  style: const TextStyle(color: AppTheme.danger, fontSize: 12),
                ),
                if (sale.voidedAt != null)
                  Text(
                    'Voided at ${formatAddisDateTime(sale.voidedAt!)}',
                    style: TextStyle(color: AppDesign.textLo, fontSize: 12),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (!isVoided && isOwner)
          TextButton(
            onPressed: _busy ? null : _voidSale,
            child: const Text(
              'Void Sale',
              style: TextStyle(color: AppTheme.danger),
            ),
          ),
        if (!isVoided && !isOwner && !sale.hasPendingVoidRequest)
          TextButton(
            onPressed: _busy ? null : _requestVoid,
            child: const Text(
              'Request Void',
              style: TextStyle(color: AppTheme.warning),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(color: AppDesign.textLo, fontSize: 12),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

class _VoidSaleDialog extends StatefulWidget {
  final bool requestMode;

  const _VoidSaleDialog({this.requestMode = false});

  @override
  State<_VoidSaleDialog> createState() => _VoidSaleDialogState();
}

class _VoidSaleDialogState extends State<_VoidSaleDialog> {
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) return;
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    final requestMode = widget.requestMode;
    // Keyboard open on a small phone: cap the body above the keyboard and let
    // the explanation + reason field scroll instead of overflowing.
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final maxBodyHeight = (media.size.height - keyboard - 200).clamp(
      100.0,
      420.0,
    );
    return AlertDialog(
      title: Text(requestMode ? 'Request Void?' : 'Void Sale?'),
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
                Text(
                  requestMode
                      ? 'Ask the owner to void this sale. It keeps counting as '
                            'revenue until the owner approves. Give a reason '
                            'below.'
                      : 'Void this sale? The original sale stays in the audit '
                            'trail; it just stops counting as revenue.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _reasonController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Reason'),
                  maxLength: 240,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
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
          style: FilledButton.styleFrom(
            backgroundColor: requestMode ? AppTheme.warning : AppTheme.danger,
          ),
          onPressed: _reasonController.text.trim().isEmpty ? null : _submit,
          child: Text(requestMode ? 'Send Request' : 'Void Sale'),
        ),
      ],
    );
  }
}
