import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// A caption, a value, and optionally a delta and a trailing slot.
///
/// The label is `bodySm`/`textSecondary` and the value is `labelLg`, so the
/// value is the only thing with tabular figures: a metric that ticks cannot
/// shift the label above it.
///
/// The tile needs a bounded width — a grid cell, an `Expanded` inside a `Row`,
/// or a `Wrap` child — because the value is allowed to shrink and ellipsize
/// rather than push its neighbours off the row.
class MetricTile extends StatelessWidget {
  /// Creates a tile.
  ///
  /// [delta] is a pre-formatted string, not a number: formatting is the caller's
  /// job because only the caller knows the unit and the sign convention.
  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    this.delta,
    this.valueColor,
    this.trailing,
  });

  /// What the value measures, e.g. `ROUND TRIP`.
  final String label;

  /// The already-formatted value, rendered in `labelLg`.
  final String value;

  /// Optional change indicator, e.g. `▲ 0.21%`. Neutral by design — a delta that
  /// needs direction colouring should be supplied as a fully-formed [trailing]
  /// widget, because this widget will not guess a direction from a formatted
  /// string.
  final String? delta;

  /// Overrides the value colour, e.g. `AppColors.bull` for an up move. Pair it
  /// with a glyph in [delta] or in [value]: colour alone never carries the sign.
  final Color? valueColor;

  /// Optional widget after the value, e.g. a unit suffix or a `CachedTag`.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final String? deltaText = delta;
    final Widget? trailingWidget = trailing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpacing.space2xs),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                value,
                style: AppTypography.labelLg.copyWith(
                  color: valueColor ?? AppColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (deltaText != null)
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.space2xs),
                child: Text(
                  deltaText,
                  style: AppTypography.labelSm.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (trailingWidget != null)
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.space2xs),
                child: trailingWidget,
              ),
          ],
        ),
      ],
    );
  }
}
