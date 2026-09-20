import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_motion.dart';
import 'package:pulse_trade_frontend/app/theme/app_radii.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';

/// One row of one side of the order book.
///
/// A row is a fixed 20dp stack of three things: a **depth bar** painted behind
/// everything, the price and quantity values, and — on the touch only — the
/// `BEST BID`/`BEST ASK` badge. Every number is `labelSm`, which carries tabular
/// figures, so a price ticking from `9` to `10` cannot reflow the row.
///
/// The row is stateless and takes no bloc: the bloc hands it an already-projected
/// [OrderBookLevel] and an already-computed [cumulativeRatio], so `build`
/// performs no accumulation, no comparison and no sort.
class DepthRow extends StatelessWidget {
  /// Creates a row.
  ///
  /// [level] is `null` for a placeholder row, which is how the two columns are
  /// kept the same height before either side has a full book to draw.
  const DepthRow({
    super.key,
    required this.level,
    required this.cumulativeRatio,
    required this.isBid,
    this.isBest = false,
    this.dimmed = false,
  });

  /// Fixed row height (`DepthRow` is 20dp). Exposed so the column can
  /// document its own height arithmetic without repeating the literal.
  static const double rowHeight = 20.0;

  /// The level to render, or `null` for an empty placeholder.
  final OrderBookLevel? level;

  /// The 0..1 depth-bar width from `TopOfBook.depthRatio`; already a projection,
  /// never recomputed here.
  final double cumulativeRatio;

  /// True for a bid row. Decides the depth-bar colour, the mirroring of the two
  /// value columns and the badge text.
  final bool isBid;

  /// True for the touch row, which carries the `BEST BID`/`BEST ASK` badge.
  final bool isBest;

  /// True when the values must read as not-current (stale socket, or a resync in
  /// progress). Values drop to the secondary text colour; they are never hidden,
  /// because a preserved book is the point.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final OrderBookLevel? row = level;
    if (row == null) {
      // A placeholder keeps both sides at exactly `rowCount` rows, so the panel
      // height is constant from the first frame and a partially-filled book
      // never makes the layout jump.
      return const SizedBox(height: rowHeight);
    }

    final String price = row.price.format();
    final String quantity = row.quantity.format();
    final Color valueColor = dimmed
        ? AppColors.textSecondary
        : AppColors.textPrimary;

    // The columns mirror each other: on the bid side the price is against the
    // outside edge and the size against the spread, and on the ask side that is
    // reversed. That is what makes the two columns read as one book.
    final Alignment priceAlignment = isBid
        ? Alignment.centerLeft
        : Alignment.centerRight;
    final Alignment quantityAlignment = isBid
        ? Alignment.centerRight
        : Alignment.centerLeft;

    return Semantics(
      container: true,
      excludeSemantics: true,
      label:
          '${isBid ? 'Bid' : 'Ask'} $price, quantity $quantity'
          '${isBest ? ', best ${isBid ? 'bid' : 'ask'}' : ''}',
      child: SizedBox(
        height: rowHeight,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // The bar is pure decoration: `ExcludeSemantics` keeps it out of the
            // accessibility tree (the row announces side, price and quantity),
            // the `RepaintBoundary` stops a bar that changes at 10 Hz from
            // repainting its neighbours.
            RepaintBoundary(
              child: ExcludeSemantics(
                child: AnimatedContainer(
                  duration: AppMotion.depthBar,
                  curve: Curves.easeOut,
                  // The bar fills from the left on both sides: the columns are
                  // mirrored by position, and a bar that always grows the same
                  // way makes "more depth" read identically on each side.
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: math.min(1.0, math.max(0.0, cumulativeRatio)),
                    alignment: Alignment.centerLeft,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: isBid ? AppColors.bidDepth : AppColors.askDepth,
                        borderRadius: AppRadii.microAll,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.space2xs,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: _Value(
                      text: price,
                      alignment: priceAlignment,
                      color: valueColor,
                    ),
                  ),
                  Expanded(
                    child: _Value(
                      text: quantity,
                      alignment: quantityAlignment,
                      color: valueColor,
                    ),
                  ),
                  if (isBest) _BestBadge(isBid: isBid),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One numeric cell of a [DepthRow].
///
/// `FittedBox(scaleDown)` is the overflow guarantee: the accessibility contract
/// requires the layout to survive `textScaleFactor` 1.3, and scaling a value's
/// glyphs is the one adjustment that cannot be mistaken for the value changing.
///
class _Value extends StatelessWidget {
  const _Value({
    required this.text,
    required this.alignment,
    required this.color,
  });

  final String text;
  final Alignment alignment;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: alignment,
        child: Text(
          text,
          maxLines: 1,
          style: AppTypography.labelSm.copyWith(color: color),
        ),
      ),
    );
  }
}

/// The `BEST BID`/`BEST ASK` pill on the touch row.
///
/// The wording, not the colour, carries the meaning: `bull`/`bear` encode the
/// side, and the label says it in words so a greyscale reader loses nothing.
///
class _BestBadge extends StatelessWidget {
  const _BestBadge({required this.isBid});

  final bool isBid;

  @override
  Widget build(BuildContext context) {
    final Color accent = isBid ? AppColors.bull : AppColors.bear;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.space2xs),
      decoration: BoxDecoration(
        border: Border.all(color: accent),
        borderRadius: AppRadii.microAll,
      ),
      child: Text(
        isBid ? 'BEST BID' : 'BEST ASK',
        maxLines: 1,
        style: AppTypography.labelSm.copyWith(color: accent),
      ),
    );
  }
}
