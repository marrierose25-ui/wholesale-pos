import 'package:flutter/material.dart';

import '../../core/models/picklist.dart';
import '../../core/theme/app_design.dart';

/// Warehouse-local shared bits: the status pill and a compact date stamp.
/// Kept in the feature folder so nothing here leaks into Sales or Finance —
/// the picklist look borrows the Money Tracking design language without
/// importing any of its code.

/// The accent colour a status is drawn in: PENDING orange, PARTIAL blue,
/// COMPLETED green. Mirrors the finance screens' use of the semantic tokens.
Color picklistStatusColor(String status) {
  switch (status) {
    case Picklist.statusCompleted:
      return AppDesign.success;
    case Picklist.statusPartial:
      return AppDesign.accent;
    default:
      return AppDesign.warning;
  }
}

/// A rounded status pill (label in its accent colour on a tinted fill), used
/// on both the directory cards and the fulfillment header.
class PicklistStatusChip extends StatelessWidget {
  final String status;
  const PicklistStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final color = picklistStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppDesign.radiusPill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        status,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// Short, unambiguous local date stamp (dd/MM/yyyy) for a picklist row. No
/// `intl` dependency — hand-formatted so it reads the same on every platform.
/// Cloud rows can arrive in UTC, so the stamp is always converted to the
/// device's local day first.
String formatPicklistDate(DateTime dt) {
  final local = dt.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/'
      '${local.year}';
}

/// Units offered in the shop's New Sale dialog. The warehouse list uses the
/// same four so a shop worker can never invent a unit the warehouse does not
/// recognise, and a picker sees the exact words the POS already uses.
const List<String> kPicklistUnits = ['Karton', 'Kuntal', 'Derzen', 'Fre'];

/// '6 November 2026' — the day heading used by Warehouse History, matching the
/// Sales History drill-down.
String formatPicklistDay(DateTime day) {
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
  final local = day.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}
