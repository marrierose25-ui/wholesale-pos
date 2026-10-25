import 'package:flutter/material.dart';

import '../../../core/theme/app_design.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/money_utils.dart';

/// One calendar-day bucket for the revenue trend chart.
class TrendPoint {
  final String day; // YYYY-MM-DD
  final int count;
  final int totalMinorUnits;

  const TrendPoint({
    required this.day,
    required this.count,
    required this.totalMinorUnits,
  });

  factory TrendPoint.fromRow(Map<String, dynamic> row) {
    return TrendPoint(
      day: row['day'] as String,
      count: (row['count'] as int?) ?? 0,
      totalMinorUnits: (row['total'] as int?) ?? 0,
    );
  }
}

/// Lightweight dependency-free charts (custom widgets only) so the offline
/// Windows build stays reproducible without pulling in fl_chart.
class DashboardPanel extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;

  const DashboardPanel({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppDesign.textHi,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ],
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

/// Vertical bars, one per day, scaled to the busiest day in the range.
class RevenueTrendChart extends StatelessWidget {
  final List<TrendPoint> points;

  const RevenueTrendChart({super.key, required this.points});

  static const int _maxBars = 14;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return _Empty(label: 'No completed sales in this period.');
    }
    // Keep the chart readable: show the most recent days only.
    final shown = points.length > _maxBars
        ? points.sublist(points.length - _maxBars)
        : points;
    final maxTotal = shown.fold<int>(
      0,
      (m, p) => p.totalMinorUnits > m ? p.totalMinorUnits : m,
    );
    final effectiveMax = maxTotal == 0 ? 1 : maxTotal;

    return SizedBox(
      height: 150,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Cap bar width so a single/few data points render as slim bars
          // (not a full-width slab), and give each bar a light track behind it.
          final slotWidth = constraints.maxWidth / shown.length;
          final barWidth = (slotWidth * 0.6).clamp(6.0, 26.0);
          const plotHeight = 108.0;
          final trackColor = Theme.of(context).colorScheme.onSurface
              .withValues(alpha: 0.05);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: shown.map((p) {
              final ratio = (p.totalMinorUnits / effectiveMax).clamp(0.0, 1.0);
              final barHeight = (ratio * plotHeight).clamp(3.0, plotHeight);
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Tooltip(
                    message:
                        '${p.day}  •  ${MoneyUtils.formatBr(p.totalMinorUnits)}'
                        '  (${p.count} sale${p.count == 1 ? '' : 's'})',
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        SizedBox(
                          width: barWidth,
                          height: plotHeight,
                          child: Stack(
                            alignment: Alignment.bottomCenter,
                            children: [
                              Positioned.fill(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: trackColor,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ),
                              Container(
                                width: barWidth,
                                height: barHeight,
                                decoration: BoxDecoration(
                                  gradient: AppDesign.buttonGradient,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4),
                                  ),
                                  boxShadow: [
                                    AppDesign.blueGlow(alpha: 0.35, blur: 12),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _shortDay(p.day),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  String _shortDay(String day) {
    final parts = day.split('-');
    if (parts.length != 3) return day;
    return '${parts[1]}/${parts[2]}';
  }
}

/// A single horizontal bar contrasting cash vs bank collections.
class PaymentSplitBar extends StatelessWidget {
  final int cashMinorUnits;
  final int bankMinorUnits;

  const PaymentSplitBar({
    super.key,
    required this.cashMinorUnits,
    required this.bankMinorUnits,
  });

  @override
  Widget build(BuildContext context) {
    final total = cashMinorUnits + bankMinorUnits;
    if (total == 0) {
      return const _Empty(label: 'No collections in this period.');
    }
    final cashRatio = cashMinorUnits / total;
    final bankRatio = bankMinorUnits / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 22,
            child: Row(
              children: [
                if (cashMinorUnits > 0)
                  Expanded(
                    flex: (cashRatio * 1000).round().clamp(1, 1000),
                    child: Container(color: AppTheme.success),
                  ),
                if (bankMinorUnits > 0)
                  Expanded(
                    flex: (bankRatio * 1000).round().clamp(1, 1000),
                    child: Container(color: AppTheme.primary),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _Legend(
              color: AppTheme.success,
              label: 'Cash',
              value: MoneyUtils.formatBr(cashMinorUnits),
              pct: '${(cashRatio * 100).toStringAsFixed(0)}%',
            ),
            const SizedBox(width: 24),
            _Legend(
              color: AppTheme.primary,
              label: 'Bank',
              value: MoneyUtils.formatBr(bankMinorUnits),
              pct: '${(bankRatio * 100).toStringAsFixed(0)}%',
            ),
          ],
        ),
      ],
    );
  }
}

/// Horizontal bars for the top revenue-earning product names.
class TopProductsBar extends StatelessWidget {
  final List<Map<String, dynamic>>
  rows; // product_name_snapshot + total_revenue

  const TopProductsBar({super.key, required this.rows});

  static const int _maxRows = 6;

  @override
  Widget build(BuildContext context) {
    final data = rows
        .where((r) => ((r['total_revenue'] as int?) ?? 0) > 0)
        .take(_maxRows)
        .toList();
    if (data.isEmpty) {
      return const _Empty(label: 'No product sales in this period.');
    }
    final maxRevenue = data.fold<int>(0, (m, r) {
      final v = (r['total_revenue'] as int?) ?? 0;
      return v > m ? v : m;
    });
    final effectiveMax = maxRevenue == 0 ? 1 : maxRevenue;

    return Column(
      children: data.map((r) {
        final name = r['product_name_snapshot'] as String? ?? '—';
        final revenue = (r['total_revenue'] as int?) ?? 0;
        final ratio = (revenue / effectiveMax).clamp(0.05, 1.0);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 120,
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    height: 16,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Container(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: ratio,
                            child: Container(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 96,
                child: Text(
                  MoneyUtils.formatBr(revenue),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  final String value;
  final String pct;

  const _Legend({
    required this.color,
    required this.label,
    required this.value,
    required this.pct,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text('$label  ', style: const TextStyle(fontSize: 13)),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        Text(
          '  ($pct)',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).textTheme.bodySmall?.color,
          ),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final String label;

  const _Empty({required this.label});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 80,
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).textTheme.bodySmall?.color,
          ),
        ),
      ),
    );
  }
}
