import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design.dart';
import '../../../core/utils/date_formatter.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_core/sales.dart';

/// '27 October 2026' — the day-heading format the whole sales drill-down uses.
String formatSalesDay(DateTime day) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${day.day} ${months[day.month - 1]} ${day.year}';
}

/// Bold Item / Quantity / Unit Price / Total captions that sit above a list of
/// [SaleLedgerRow]s so the fixed columns read as a ledger.
class SaleLedgerHeader extends StatelessWidget {
  const SaleLedgerHeader({super.key});

  static Widget _cell(String label, TextAlign align, {double? width}) {
    return SizedBox(
      width: width,
      child: Text(
        label,
        textAlign: align,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppDesign.textLo,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 6),
      child: wide
          ? Row(
              children: [
                const SizedBox(width: 48),
                const SizedBox(width: 8),
                Expanded(flex: 3, child: _cell('Item', TextAlign.start)),
                const SizedBox(width: 6),
                Expanded(flex: 2, child: _cell('Reason', TextAlign.start)),
                const SizedBox(width: 6),
                _cell('Quantity', TextAlign.end, width: 58),
                const SizedBox(width: 6),
                _cell('Unit Price', TextAlign.end, width: 82),
                const SizedBox(width: 6),
                _cell('Method', TextAlign.end, width: 52),
                const SizedBox(width: 6),
                _cell('Total', TextAlign.end, width: 86),
              ],
            )
          : Row(
              children: [
                const SizedBox(width: 48),
                const SizedBox(width: 8),
                Expanded(child: _cell('Item', TextAlign.start)),
                _cell('Total', TextAlign.end, width: 88),
              ],
            ),
    );
  }
}

/// One ledger line: time · item · quantity · unit price · total. Voided sales
/// are greyed with a strike-through. Shared by the Dashboard's day drill-down
/// and the Register History day screen so both list sales identically.
class SaleLedgerRow extends StatelessWidget {
  final Sale sale;
  final VoidCallback? onTap;

  const SaleLedgerRow({super.key, required this.sale, this.onTap});

  String get _time => formatAddisTime(sale.createdAt);
  String get _methodLabel => switch (sale.paymentMethod) {
    'LOAN' => 'Loan',
    'BANK' => 'Bank',
    _ => 'Cash',
  };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final isVoided = sale.status == 'VOIDED';
    final item = sale.items.isNotEmpty ? sale.items.first : null;
    final color = isVoided ? Colors.grey : AppDesign.textHi;
    final decoration = isVoided ? TextDecoration.lineThrough : null;
    final quantity = item?.quantityText ?? '-';
    final unitPrice = item == null
        ? '-'
        : MoneyUtils.formatBr(item.unitPriceSnapshotMinorUnits);

    final quantityText = Text(
      quantity,
      maxLines: 1,
      textAlign: TextAlign.end,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: color,
        decoration: decoration,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final unitPriceText = Text(
      unitPrice,
      maxLines: 1,
      textAlign: TextAlign.end,
      style: TextStyle(
        fontSize: 12,
        color: color,
        decoration: decoration,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final methodText = Text(
      _methodLabel,
      maxLines: 1,
      textAlign: TextAlign.end,
      style: TextStyle(fontSize: 11.5, color: color, decoration: decoration),
    );
    final totalText = Text(
      MoneyUtils.formatBr(sale.totalMinorUnits),
      maxLines: 1,
      textAlign: TextAlign.end,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: color,
        decoration: decoration,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );

    final rawReason = item?.notes?.trim();
    final reasonText = (rawReason != null && rawReason.isNotEmpty)
        ? rawReason
        : (isVoided &&
              sale.voidReason != null &&
              sale.voidReason!.trim().isNotEmpty)
        ? sale.voidReason!.trim()
        : '-';

    final reasonCell = Expanded(
      flex: 2,
      child: Text(
        reasonText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: isVoided ? Colors.grey : AppDesign.textLo,
          decoration: decoration,
        ),
      ),
    );

    Widget buildItemCell({int? flex}) {
      final cell = Row(
        children: [
          // Expanded (not Flexible) so the name gives room to the
          // VOID/REQ badge and the "+N" count before ellipsizing.
          Expanded(
            child: Text(
              item?.productNameSnapshot ?? 'Sale',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
                decoration: decoration,
              ),
            ),
          ),
          if (sale.items.length > 1) ...[
            const SizedBox(width: 4),
            Text(
              '+${sale.items.length - 1}',
              style: TextStyle(fontSize: 11, color: AppDesign.textLo),
            ),
          ],
          if (!isVoided && sale.hasPendingVoidRequest) ...[
            const SizedBox(width: 6),
            const _MiniBadge('REQ', color: AppDesign.danger),
          ],
          // Voided rows need no badge: grey + strike-through already
          // mark them, and the fixed columns must leave the item name
          // room at phone width.
        ],
      );
      return flex != null
          ? Expanded(flex: flex, child: cell)
          : Expanded(child: cell);
    }

    return GlassCard(
      radius: AppDesign.radiusCardSm,
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: wide
            ? Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: Text(
                      _time,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(fontSize: 11.5, color: AppDesign.textLo),
                    ),
                  ),
                  const SizedBox(width: 8),
                  buildItemCell(flex: 3),
                  const SizedBox(width: 6),
                  reasonCell,
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 58,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: quantityText,
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 82,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: unitPriceText,
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 52,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: methodText,
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 86,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: totalText,
                    ),
                  ),
                ],
              )
            // Phones get two lines: the name and total stay readable, and the
            // quantity / price / method details sit underneath instead of
            // fighting for the same few pixels.
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 48,
                        child: Text(
                          _time,
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppDesign.textLo,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      buildItemCell(),
                      SizedBox(
                        width: 88,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: totalText,
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 56, top: 4),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        quantityText,
                        unitPriceText,
                        methodText,
                        if (reasonText != '-')
                          Text(
                            reasonText,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: AppDesign.textLo,
                              decoration: decoration,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// A tiny inline status badge (VOID / REQ) used in the day list rows.
class _MiniBadge extends StatelessWidget {
  final String text;
  final Color color;

  const _MiniBadge(this.text, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
