import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_motion.dart';
import 'package:pulse_trade_frontend/app/theme/app_radii.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/features/watchlist/watchlist_state.dart';

/// One watchlist row.
///
/// Every row is a live market, so every row gets the same treatment: a pulsing
/// dot next to the newest price, coloured by the direction of the 24h change.
/// A row whose price is not known yet shows a dash rather than an invented
/// number.
///
/// Everything interactive is at least [AppSpacing.minTouchTarget] tall, and the
/// whole row is wrapped in one [Semantics] node so a screen reader hears one
/// sentence per market instead of one per widget.
class WatchlistRow extends StatelessWidget {
  /// Creates a row.
  ///
  /// All callbacks are optional so the row can be rendered read-only in tests or
  /// in a preview without inventing handlers.
  const WatchlistRow({
    super.key,
    required this.entry,
    this.isDragging = false,
    this.position = 1,
    this.total = 1,
    this.dragIndex,
    this.onTap,
    this.onFavouriteToggle,
    this.onRemove,
    this.onPin,
  });

  /// The row's data, already projected by the cubit.
  final WatchlistEntry entry;

  /// True while this row is the one being dragged, which dims it in place.
  final bool isDragging;

  /// 1-based position in the visible list, spoken for accessibility.
  final int position;

  /// Number of rows in the visible list, spoken for accessibility.
  final int total;

  /// This row's index inside the surrounding `ReorderableListView`, when there
  /// is one. Supplying it turns the drag handle into the **only** drag
  /// affordance: without it, the list's default behaviour would start a drag on
  /// any touch down, which would fight the row's tap and its swipe gestures.
  final int? dragIndex;

  /// Opens the market screen for this symbol.
  final VoidCallback? onTap;

  /// Adds or removes the symbol from the favourites.
  final VoidCallback? onFavouriteToggle;

  /// Removes the row; the page wires this to the swipe and to the undo flow.
  final VoidCallback? onRemove;

  /// Pins this symbol to the top of the list.
  final VoidCallback? onPin;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? tap = onTap;
    final int? index = dragIndex;
    final Widget handle = Icon(
      Icons.drag_indicator,
      size: 18,
      color: index == null ? AppColors.textDisabled : AppColors.textSecondary,
    );
    final Widget content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.spaceSm),
      child: Row(
        children: <Widget>[
          if (index == null)
            handle
          else
            ReorderableDragStartListener(index: index, child: handle),
          const SizedBox(width: AppSpacing.spaceXs),
          _Glyph(entry: entry),
          const SizedBox(width: AppSpacing.spaceSm),
          Expanded(child: _Identity(entry: entry)),
          const SizedBox(width: AppSpacing.spaceSm),
          _Quote(entry: entry),
          _FavouriteStar(
            isFavourite: entry.isFavourite,
            onPressed: onFavouriteToggle,
          ),
        ],
      ),
    );

    return Semantics(
      button: tap != null,
      label: _semanticsLabel,
      child: Opacity(
        opacity: isDragging ? 0.6 : 1,
        child: Material(
          color: AppColors.canvas,
          child: InkWell(
            onTap: tap,
            onLongPress: onPin,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AppSpacing.minTouchTarget,
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }

  /// One spoken sentence for the row: identity, position, price and direction.
  ///
  /// Composed here rather than from the child widgets so the number of words a
  /// screen reader emits does not depend on how the row is laid out internally.
  String get _semanticsLabel {
    final StringBuffer buffer = StringBuffer(entry.display);
    buffer.write(', position $position of $total');
    if (entry.isPinned) buffer.write(', pinned');
    buffer.write(', live');
    final Money? price = entry.price;
    if (price != null) {
      buffer.write(', price ${price.format()}');
    }
    final int? basisPoints = entry.changeBasisPoints;
    if (basisPoints != null) {
      final String direction = basisPoints >= 0 ? 'up' : 'down';
      buffer.write(', $direction ${_formatBasisPoints(basisPoints)} percent');
    }
    return buffer.toString();
  }
}

/// The asset glyph chip.
class _Glyph extends StatelessWidget {
  const _Glyph({required this.entry});

  final WatchlistEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.componentAll,
        border: Border.all(color: AppColors.outline),
      ),
      child: Text(
        entry.glyph,
        style: AppTypography.labelMd.copyWith(color: AppColors.textPrimary),
      ),
    );
  }
}

/// Symbol, display pair and name.
class _Identity extends StatelessWidget {
  const _Identity({required this.entry});

  final WatchlistEntry entry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                entry.symbol,
                style: AppTypography.headlineSm.copyWith(
                  color: AppColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppSpacing.space2xs),
            Text(
              entry.display,
              style: AppTypography.labelSm.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.space2xs),
        Text(
          entry.name,
          style: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Price, direction chip and the pulsing live marker.
class _Quote extends StatelessWidget {
  const _Quote({required this.entry});

  final WatchlistEntry entry;

  @override
  Widget build(BuildContext context) {
    final Money? price = entry.price;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          price == null ? '—' : price.format(),
          style: AppTypography.labelLg.copyWith(
            color: AppColors.textPrimary,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: AppSpacing.space2xs),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const _PulsingDot(),
            const SizedBox(width: AppSpacing.space2xs),
            _ChangeChip(basisPoints: entry.changeBasisPoints),
          ],
        ),
      ],
    );
  }
}

/// The change pill: ▲/▼ plus the magnitude in basis points.
///
/// The percentage is derived from the integer basis points rather than from a
/// `double` price, so `0.21 %` is exact and 1 bp is always `0.01 %`.
class _ChangeChip extends StatelessWidget {
  const _ChangeChip({required this.basisPoints});

  final int? basisPoints;

  @override
  Widget build(BuildContext context) {
    final int? points = basisPoints;
    final bool up = (points ?? 0) >= 0;
    final Color color = up ? AppColors.bull : AppColors.bear;
    return Text(
      points == null ? '—' : '${up ? '▲' : '▼'} ${_formatBasisPoints(points)}%',
      style: AppTypography.labelSm.copyWith(color: color),
    );
  }
}

/// The live indicator: a small dot that pulses on the [AppMotion.chipPulse]
/// cadence and is excluded from semantics, because the row's label already says
/// `live`, so status is never carried by colour or motion alone.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.chipPulse,
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(
    begin: 0.35,
    end: 1,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: FadeTransition(
        opacity: _opacity,
        child: Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            color: AppColors.bull,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// The favourite star, sized to a full touch target.
class _FavouriteStar extends StatelessWidget {
  const _FavouriteStar({required this.isFavourite, this.onPressed});

  final bool isFavourite;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? handler = onPressed;
    if (handler == null) {
      return const SizedBox(width: AppSpacing.minTouchTarget);
    }
    return Semantics(
      button: true,
      toggled: isFavourite,
      label: isFavourite ? 'Remove from favourites' : 'Add to favourites',
      child: IconButton(
        onPressed: handler,
        iconSize: 20,
        constraints: const BoxConstraints(
          minWidth: AppSpacing.minTouchTarget,
          minHeight: AppSpacing.minTouchTarget,
        ),
        icon: Icon(
          isFavourite ? Icons.star : Icons.star_border,
          color: isFavourite ? AppColors.warn : AppColors.textDisabled,
        ),
      ),
    );
  }
}

/// Formats integer basis points as a percentage string with two decimals.
///
/// 100 bp = 1 %, so the integer part is `bp ~/ 100` and the fraction is
/// `bp % 100`. Doing it with integer arithmetic keeps the display exact and
/// avoids ever putting a price through a `double`.
String _formatBasisPoints(int basisPoints) {
  final int magnitude = basisPoints.abs();
  final int whole = magnitude ~/ 100;
  final int fraction = magnitude % 100;
  return '$whole.${fraction.toString().padLeft(2, '0')}';
}
