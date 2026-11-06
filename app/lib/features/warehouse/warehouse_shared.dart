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
      return AppDesign.blueBright;
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
String formatPicklistDate(DateTime dt) =>
    '${dt.day.toString().padLeft(2, '0')}/'
    '${dt.month.toString().padLeft(2, '0')}/'
    '${dt.year}';
