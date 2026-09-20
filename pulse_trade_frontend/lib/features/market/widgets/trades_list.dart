import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_motion.dart';
import 'package:pulse_trade_frontend/app/theme/app_radii.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/app/widgets/app_card.dart';
import 'package:pulse_trade_frontend/app/widgets/card_header.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';
import 'package:pulse_trade_frontend/domain/entities/trade_side.dart';

/// The recent-trades tape: four columns, keyed rows and a compaction chip.
///
/// **`AnimatedList` is deliberately not used.** The tape is capped at
/// [maxRows], a new row arrives at the top and nothing else moves, and an
/// `AnimatedList` would additionally demand a `GlobalKey`, an imperative
/// `insertItem` call and a second index space that has to be kept in step with
/// the bloc's list. A plain list of keyed rows lets Flutter's element reuse do
/// the same job with a bounded, predictable frame cost, which is the property
/// the design asks for.
///
/// A plain `Column`, not a `ListView`: this card is already a child of the
/// market screen's scroll view, and a nested scrollable would capture the drag
/// and fight it.
class TradesList extends StatelessWidget {
  /// Creates the tape.
  ///
  /// [omittedCount] comes from the backend's compaction accounting and is shown
  /// rather than hidden, so a DEGRADED or MINIMAL session explains its own gaps.
  ///
  const TradesList({super.key, required this.trades, this.omittedCount = 0});

  /// Hard cap on rendered rows.
  static const int maxRows = 50;

  /// Recent trades, newest first.
  final List<Trade> trades;

  /// Executions the backend omitted when compacting recent batches.
  final int omittedCount;

  @override
  Widget build(BuildContext context) {
    final List<Trade> visible = trades.length > maxRows
        ? trades.sublist(0, maxRows)
        : trades;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CardHeader(
            title: 'Recent trades',
            trailing: _Trailing(
              isLive: visible.isNotEmpty,
              omittedCount: omittedCount,
            ),
          ),
          const _ColumnHeaderRow(),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.spaceSm,
                vertical: AppSpacing.spaceMd,
              ),
              child: Text(
                'Waiting for trades…',
                style: AppTypography.bodySm.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            )
          else
            for (final Trade trade in visible)
              _TradeRow(key: ValueKey<int>(trade.tradeId), trade: trade),
        ],
      ),
    );
  }
}

class _Trailing extends StatelessWidget {
  const _Trailing({required this.isLive, required this.omittedCount});

  final bool isLive;
  final int omittedCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (omittedCount > 0) ...<Widget>[
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.space2xs,
              vertical: AppSpacing.space2xs / 2,
            ),
            decoration: BoxDecoration(
              borderRadius: AppRadii.microAll,
              border: Border.all(color: AppColors.warn),
            ),
            child: Text(
              '$omittedCount omitted',
              style: AppTypography.labelSm.copyWith(color: AppColors.warn),
            ),
          ),
          const SizedBox(width: AppSpacing.spaceXs),
        ],
        // The live dot is decorative; the word travels through Semantics so the
        // state is never colour-only.
        Semantics(
          label: isLive ? 'Receiving trades' : 'No trades yet',
          excludeSemantics: true,
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isLive ? AppColors.bull : AppColors.textDisabled,
            ),
          ),
        ),
      ],
    );
  }
}

class _ColumnHeaderRow extends StatelessWidget {
  const _ColumnHeaderRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.spaceSm),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.outline)),
      ),
      child: const Row(
        children: <Widget>[
          _HeaderCell(label: 'TIME', flex: 3),
          _HeaderCell(label: 'PRICE', flex: 3),
          _HeaderCell(label: 'QTY', flex: 3),
          _HeaderCell(label: 'SIDE', flex: 2),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({required this.label, required this.flex});

  final String label;
  final int flex;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Text(
        label,
        style: AppTypography.labelSm.copyWith(color: AppColors.textDisabled),
      ),
    );
  }
}

class _TradeRow extends StatefulWidget {
  const _TradeRow({super.key, required this.trade});

  final Trade trade;

  @override
  State<_TradeRow> createState() => _TradeRowState();
}

class _TradeRowState extends State<_TradeRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _flash;

  @override
  void initState() {
    super.initState();
    // The flash runs once, when the row's element is first created. Because the
    // rows are keyed by trade id, an arriving trade inserts exactly one new
    // element and therefore triggers exactly one flash.
    _controller = AnimationController(
      vsync: this,
      duration: AppMotion.tradeFlash,
    )..forward();
    _flash = Tween<double>(
      begin: 1,
      end: 0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Trade trade = widget.trade;
    final bool isBuy = trade.side == TradeSide.buy;
    final Color sideColour = isBuy ? AppColors.bull : AppColors.bear;
    return AnimatedBuilder(
      animation: _flash,
      // The row content is passed as `child` so the 400 ms flash rebuilds only
      // the background, not the four text cells inside it.
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.spaceSm),
        child: Row(
          children: <Widget>[
            Expanded(
              flex: 3,
              child: Text(
                _time(trade.timestamp),
                style: AppTypography.labelSm.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                trade.price.format(),
                style: AppTypography.labelSm.copyWith(color: sideColour),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                trade.quantity.format(),
                style: AppTypography.labelSm.copyWith(
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.space2xs,
                  ),
                  decoration: BoxDecoration(
                    color: isBuy ? AppColors.bidDepth : AppColors.askDepth,
                    borderRadius: AppRadii.microAll,
                  ),
                  child: Text(
                    trade.side.wire,
                    style: AppTypography.labelSm.copyWith(color: sideColour),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      builder: (BuildContext context, Widget? child) => Container(
        color: sideColour.withValues(alpha: _flash.value * 0.18),
        child: child,
      ),
    );
  }
}

String _time(DateTime value) {
  final DateTime utc = value.toUtc();
  final String hour = utc.hour.toString().padLeft(2, '0');
  final String minute = utc.minute.toString().padLeft(2, '0');
  final String second = utc.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second';
}
