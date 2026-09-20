import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/app/widgets/bid_ask_badge.dart';
import 'package:pulse_trade_frontend/app/widgets/cached_tag.dart';
import 'package:pulse_trade_frontend/app/widgets/empty_state.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';
import 'package:pulse_trade_frontend/domain/entities/top_of_book.dart';
import 'package:pulse_trade_frontend/domain/orderbook/order_book_synchronizer.dart';
import 'package:pulse_trade_frontend/features/orderbook/order_book_state.dart';
import 'package:pulse_trade_frontend/features/orderbook/widgets/depth_row.dart';

/// The order-book body: spread line, provenance tag, and two mirrored columns of
/// depth rows.
///
/// The widget is a pure function of [state]. It performs no sequencing, no
/// accumulation and no sorting: the projection, the depth ratios and the
/// provenance label all arrive precomputed, which is what keeps `build` inside a
/// frame budget at 10 updates/s.
class OrderBookView extends StatelessWidget {
  /// Creates the view.
  ///
  /// [rowCount] is the number of rows rendered *per side*, not in total: both
  /// columns always render exactly this many rows so the panel height is
  /// constant from the first frame.
  const OrderBookView({
    super.key,
    required this.state,
    this.rowCount = 10,
    this.onRetry,
  });

  /// The immutable projection to render.
  final OrderBookStateModel state;

  /// Rows per side. Ten by default.
  final int rowCount;

  /// Invoked by the error state's Retry action. `null` renders the action as a
  /// no-op button, which is honest: there is nothing the widget itself can do.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final bool hasFailed = state.syncState == OrderBookState.error;
    final bool isWaiting = !hasFailed && state.top.isEmpty && state.isSyncing;
    final bool dimmed =
        state.isStale || state.syncState == OrderBookState.recovering;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _StatusLine(state: state),
        const SizedBox(height: AppSpacing.spaceXs),
        if (hasFailed)
          EmptyState(
            title: 'Order book unavailable',
            message: state.failure?.message,
            icon: Icons.cloud_off_outlined,
            onRetry: onRetry,
          )
        else if (isWaiting)
          // No cache and no snapshot yet: say so, rather than drawing ten empty
          // rows that would read as a real, empty book.
          const EmptyState(title: 'Waiting for order book…')
        else
          _Columns(state: state, rowCount: rowCount, dimmed: dimmed),
      ],
    );
  }
}

/// The two mirrored half-books.
class _Columns extends StatelessWidget {
  const _Columns({
    required this.state,
    required this.rowCount,
    required this.dimmed,
  });

  final OrderBookStateModel state;
  final int rowCount;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: _bookSide(isBid: true)),
        const SizedBox(width: AppSpacing.gutterPhone),
        Expanded(child: _bookSide(isBid: false)),
      ],
    );
  }

  Widget _bookSide({required bool isBid}) {
    final List<OrderBookLevel> levels = isBid ? state.top.bids : state.top.asks;
    // A `Column` of fixed-height rows rather than a `ListView.builder`: the
    // depth is a compile-time-known constant (10 rows in a 200dp panel), so a
    // scrolling viewport would add a scroll physics/layout cost, a possible
    // scrollbar and a lazy-build boundary for content that always fits on
    // screen. The fixed structure is also what guarantees the 16 ms budget.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int index = 0; index < rowCount; index++)
          DepthRow(
            // A missing level becomes a placeholder, so a partially-filled book
            // still renders `rowCount` rows on both sides and the columns stay
            // aligned.
            level: index < levels.length ? levels[index] : null,
            cumulativeRatio: state.top.depthRatio(index, isBid: isBid),
            isBid: isBid,
            isBest: index == 0 && levels.isNotEmpty,
            dimmed: dimmed,
          ),
      ],
    );
  }
}

/// The spread readout and the provenance tag.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.state});

  final OrderBookStateModel state;

  @override
  Widget build(BuildContext context) {
    // The canonical touch readout: exact [Money] values through
    // `Money.format`, never a formatted double. The spread percentage is added
    // beside it because a bare `0.20` says nothing about whether that is wide or
    // narrow for this instrument.
    final double? percent = _spreadPercent(state.top);
    // A Wrap, not a Row: the provenance tag ("STALE · as of 12:41:03") is long
    // enough that a Row would overflow by 81 px on a phone in the stale state,
    // and a large text scale would do the same to a live one. Wrapping costs a
    // second line in the worst case instead of clipping information the user
    // needs.
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpacing.spaceXs,
      runSpacing: AppSpacing.space2xs,
      children: <Widget>[
        BidAskBadge(
          bid: state.top.bestBid,
          ask: state.top.bestAsk,
          spread: state.top.spread,
        ),
        if (percent != null)
          Text(
            '${percent.toStringAsFixed(4)}%',
            style: AppTypography.labelSm.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        _tag(),
      ],
    );
  }

  /// The tag, or nothing at all when the book is live.
  ///
  /// `LIVE` is already stated by the connection chip; a tag on a section exists
  /// to mark data that is not live, so repeating it here would be noise.
  Widget _tag() {
    final String label = state.tagLabel;
    if (label == 'LIVE') return const SizedBox.shrink();

    final DateTime? asOf = state.asOf;
    if (asOf == null) {
      // A `CachedTag` is defined by its `as of` time; inventing one would be a
      // lie, so an untimestamped tag is plain text.
      return Text(
        label,
        style: AppTypography.labelSm.copyWith(color: AppColors.warn),
      );
    }
    return CachedTag(kind: label, asOf: asOf, stale: state.isStale);
  }
}

/// The spread as a percentage of the mid price, or `null` when it cannot be
/// stated. The mid is derived from both touches so a crossed or one-sided book
/// produces no percentage rather than a meaningless one.
double? _spreadPercent(TopOfBook top) {
  final Money? spread = top.spread;
  final Money? bestBid = top.bestBid;
  final Money? bestAsk = top.bestAsk;
  if (spread == null || bestBid == null || bestAsk == null) return null;
  final double mid = (bestBid + bestAsk).toDouble() / 2;
  if (mid == 0) return null;
  return spread.toDouble() / mid * 100;
}
