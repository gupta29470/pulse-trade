import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_radii.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';

/// The `1m 5m 15m 1h 4h 1D` pill row.
///
/// **The tap target is larger than the pill.** The pills look compact because a
/// dense header demands it, but each one is centred inside a 48dp square
/// so the control is finger-sized even though the ink is not. The
/// row scrolls horizontally rather than wrapping, because a wrapping selector
/// would change the header's height between intervals and shift the chart.
///
/// Selection is carried by background *and* text colour, and announced through
/// `Semantics.selected`, so it never depends on colour alone.
class IntervalSelector extends StatelessWidget {
  /// Creates the selector.
  ///
  /// [isRefreshing] draws the subtle loading bar under the row while a history
  /// request is in flight; the previous candles stay on screen throughout.
  ///
  const IntervalSelector({
    super.key,
    required this.selected,
    required this.onSelected,
    this.isRefreshing = false,
  });

  /// The interval currently selected.
  final CandleInterval selected;

  /// Called with the interval the user tapped.
  final ValueChanged<CandleInterval> onSelected;

  /// True while an interval switch is being loaded.
  final bool isRefreshing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: AppSpacing.minTouchTarget,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final CandleInterval interval in CandleInterval.values)
                  _IntervalPill(
                    interval: interval,
                    isSelected: interval == selected,
                    onTap: onSelected,
                  ),
              ],
            ),
          ),
        ),
        // The slot is always reserved: a bar that appears and disappears would
        // move the chart by 2dp on every interval switch.
        SizedBox(
          height: 2,
          child: isRefreshing
              ? const LinearProgressIndicator(
                  minHeight: 2,
                  color: AppColors.bull,
                  backgroundColor: AppColors.outline,
                )
              : null,
        ),
      ],
    );
  }
}

class _IntervalPill extends StatelessWidget {
  const _IntervalPill({
    required this.interval,
    required this.isSelected,
    required this.onTap,
  });

  final CandleInterval interval;
  final bool isSelected;
  final ValueChanged<CandleInterval> onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isSelected,
      label: '${interval.wire} candle interval',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: AppSpacing.minTouchTarget,
          minHeight: AppSpacing.minTouchTarget,
        ),
        child: Center(
          child: InkWell(
            onTap: () => onTap(interval),
            borderRadius: AppRadii.microAll,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.spaceXs,
                vertical: AppSpacing.space2xs,
              ),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.outline : AppColors.transparent,
                borderRadius: AppRadii.microAll,
              ),
              child: Text(
                interval.wire,
                style: AppTypography.labelMd.copyWith(
                  color: isSelected ? AppColors.bull : AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
