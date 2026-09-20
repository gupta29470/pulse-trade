import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';

import '../theme/app_colors.dart';
import '../theme/app_radii.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// The `BEST BID` / `BEST ASK` micro badges at the top of the order book, and
/// the spread between them.
///
/// Every value is a [Money], never a `double`. A price that has passed through
/// binary floating point is a price that can print `67421.34999999999`, and the
/// spread is exactly the subtraction where that shows up first; [Money.format]
/// is the only formatter used here.
///
/// The caption is textual (`BEST BID`, `BEST ASK`, `SPREAD`), so the side of the
/// book is never conveyed by the bull/bear tint alone.
class BidAskBadge extends StatelessWidget {
  /// Creates the badge pair.
  ///
  /// [decimals] is a *padding* hint for column alignment and never a rounding
  /// instruction: a value with more fraction digits than [decimals] is printed
  /// exactly, because hiding precision the backend sent is worse than a ragged
  /// column.
  const BidAskBadge({
    super.key,
    this.bid,
    this.ask,
    this.spread,
    this.decimals = 2,
  }) : assert(
         decimals >= 0,
         'decimals is a padding hint and cannot be negative',
       );

  /// Best bid, or null when the book has no bids.
  final Money? bid;

  /// Best ask, or null when the book has no asks.
  final Money? ask;

  /// The spread, when the caller already computed it from the same projection.
  final Money? spread;

  /// Minimum fraction digits to print, for a stable column width.
  final int decimals;

  /// The exact decimal string of [value], or an em dash when there is no value.
  ///
  /// A missing best bid and a best bid of zero are different facts, so an absent
  /// value is never rendered as a number.
  static String formatMoney(Money? value) =>
      value == null ? '—' : value.format();

  /// Pads [value] to [decimals] fraction digits for alignment.
  ///
  /// Padding only: the exact value is returned untouched when it already has at
  /// least [decimals] fraction digits.
  String _aligned(Money? value) {
    if (value == null) return formatMoney(null);
    final String exact = value.format();
    if (decimals <= 0) return exact;
    final int dot = exact.indexOf('.');
    final String whole = dot < 0 ? exact : exact.substring(0, dot);
    final String fraction = dot < 0 ? '' : exact.substring(dot + 1);
    if (fraction.length >= decimals) return exact;
    return '$whole.${fraction.padRight(decimals, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final Money? spreadValue = spread;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _MicroBadge(
              label: 'BEST BID',
              spokenLabel: 'Best bid',
              value: _aligned(bid),
              tone: AppColors.bull,
              fill: AppColors.bidDepth,
            ),
            const SizedBox(width: AppSpacing.spaceXs),
            _MicroBadge(
              label: 'BEST ASK',
              spokenLabel: 'Best ask',
              value: _aligned(ask),
              tone: AppColors.bear,
              fill: AppColors.askDepth,
            ),
          ],
        ),
        if (spreadValue != null) ...<Widget>[
          const SizedBox(height: AppSpacing.space2xs),
          Text(
            'SPREAD ${_aligned(spreadValue)}',
            style: AppTypography.labelSm.copyWith(
              color: AppColors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// One tinted micro badge: an uppercase caption above a coloured value.
final class _MicroBadge extends StatelessWidget {
  /// Creates a badge.
  const _MicroBadge({
    required this.label,
    required this.spokenLabel,
    required this.value,
    required this.tone,
    required this.fill,
  });

  /// Uppercase caption, e.g. `BEST BID`.
  final String label;

  /// The same caption in sentence case, for screen readers that would otherwise
  /// spell out an uppercase abbreviation.
  final String spokenLabel;

  /// The formatted value.
  final String value;

  /// Value colour: bull for the bid, bear for the ask.
  final Color tone;

  /// Background tint, from the same 12 % blend family as the depth bars.
  final Color fill;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '$spokenLabel $value',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.space2xs,
          vertical: AppSpacing.space2xs / 2,
        ),
        decoration: BoxDecoration(color: fill, borderRadius: AppRadii.microAll),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: AppTypography.labelSm.copyWith(
                color: AppColors.textSecondary,
              ),
              maxLines: 1,
            ),
            Text(
              value,
              style: AppTypography.labelSm.copyWith(color: tone),
              maxLines: 1,
            ),
          ],
        ),
      ),
    );
  }
}
