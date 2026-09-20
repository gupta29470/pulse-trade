import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/app/widgets/app_card.dart';
import 'package:pulse_trade_frontend/app/widgets/cached_tag.dart';
import 'package:pulse_trade_frontend/app/widgets/card_header.dart';
import 'package:pulse_trade_frontend/app/widgets/empty_state.dart';
import 'package:pulse_trade_frontend/app/widgets/skeleton_block.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/features/market/chart/candlestick_renderer.dart';
import 'package:pulse_trade_frontend/features/market/market_state.dart';

/// The chart card: readout strip, candle canvas, and the empty/error/skeleton
/// states the page owns rather than the renderer.
///
/// **Crosshair state is local.** The widget is a `StatefulWidget` on purpose: a
/// drag repaints the canvas and the readout through `setState` here, and never
/// travels through `MarketBloc`, so the surrounding market screen does not
/// rebuild while the user inspects a candle.
class ChartBlock extends StatefulWidget {
  /// Creates the block.
  ///
  /// [onRetry] is only reachable from the error state, and is `null` when the
  /// caller has no way to retry.
  const ChartBlock({super.key, required this.state, this.onRetry});

  /// The market state to render.
  final MarketState state;

  /// Re-issues the history load after a failure.
  final VoidCallback? onRetry;

  @override
  State<ChartBlock> createState() => _ChartBlockState();
}

class _ChartBlockState extends State<ChartBlock> {
  /// Height of the candle canvas.
  static const double _canvasHeight = 220;

  CrosshairState _crosshair = CrosshairState.none;

  @override
  void didUpdateWidget(covariant ChartBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A crosshair index means nothing across an interval switch: the same slot
    // holds a different bucket. Clearing it here keeps the readout honest
    // without a rebuild of the surrounding screen.
    if (widget.state.interval != oldWidget.state.interval) {
      _crosshair = CrosshairState.none;
    }
  }

  @override
  Widget build(BuildContext context) {
    final MarketState state = widget.state;
    return AppCard(
      // Zero inset: the header and the canvas own their own padding so the
      // header divider reaches the card's edges.
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CardHeader(title: 'Chart', trailing: _tag(state)),
          _ChartReadout(candle: _readoutCandle(state)),
          if (state.hasCandles)
            SizedBox(
              height: _canvasHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.spaceSm,
                  AppSpacing.space2xs,
                  AppSpacing.spaceSm,
                  AppSpacing.spaceSm,
                ),
                child: _interactiveCanvas(state),
              ),
            )
          else
            // The empty and error states size themselves; forcing them into the
            // canvas height would overflow as soon as the text scale rises.
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.spaceSm),
              child: _placeholder(state),
            ),
        ],
      ),
    );
  }

  /// The CACHED/STALE tag, or `null` when the series is live.
  ///
  /// A live provenance deliberately renders nothing rather than a `LIVE` tag:
  /// the tag exists to qualify data that is *not* fresh, and printing it always
  /// would make it invisible.
  Widget? _tag(MarketState state) {
    final DateTime? asOf = state.candleAsOf;
    final DataProvenance? provenance = state.candleProvenance;
    if (asOf == null ||
        provenance == null ||
        provenance == DataProvenance.live) {
      return null;
    }
    final bool stale = provenance == DataProvenance.stale;
    return CachedTag(
      kind: stale ? 'STALE' : 'CACHED',
      asOf: asOf,
      stale: stale,
    );
  }

  /// The candle the readout describes: the crosshair's, else the forming bucket,
  /// else the newest closed one.
  Candle? _readoutCandle(MarketState state) {
    final Candle? selected = _crosshair.candle;
    if (selected != null) return selected;
    final Candle? active = state.activeCandle;
    if (active != null) return active;
    return state.hasCandles ? state.candles.last : null;
  }

  /// Skeleton, empty message or error-with-retry.
  Widget _placeholder(MarketState state) {
    final AppFailure? failure = state.failure;
    if (failure != null) {
      return EmptyState(
        title: 'Chart unavailable',
        message: failure.message,
        icon: Icons.show_chart,
        onRetry: widget.onRetry,
      );
    }
    if (state.status == MarketDataStatus.initialLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.spaceSm),
        child: SkeletonBlock(height: _canvasHeight),
      );
    }
    return const EmptyState(
      title: 'No history',
      message:
          'No historical data available. Live candles will appear when '
          'trading begins.',
      icon: Icons.insights_outlined,
    );
  }

  Widget _interactiveCanvas(MarketState state) {
    final List<Candle> window = CandleSeriesAdapter.visibleWindow(
      state.candles,
    );
    final Money? livePriceMoney = _livePrice(state);
    final double? livePrice = livePriceMoney?.toDouble();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        return GestureDetector(
          // Opaque so a touch on an empty part of the canvas still selects the
          // slot under the finger instead of falling through to the scroll view.
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails details) =>
              _select(details.localPosition.dx, width, window),
          onHorizontalDragStart: (DragStartDetails details) =>
              _select(details.localPosition.dx, width, window),
          onHorizontalDragUpdate: (DragUpdateDetails details) =>
              _select(details.localPosition.dx, width, window),
          child: const FlChartCandlestickRenderer().build(
            candles: state.candles,
            active: state.activeCandle,
            crosshair: _crosshair,
            livePrice: livePrice,
          ),
        );
      },
    );
  }

  /// The latest traded price, drawn as the dashed pointer.
  Money? _livePrice(MarketState state) {
    final Candle? active = state.activeCandle;
    if (active != null) return active.close;
    return state.hasCandles ? state.candles.last.close : null;
  }

  void _select(double dx, double width, List<Candle> window) {
    if (window.isEmpty || width <= 0) return;
    final double slot = width / window.length;
    final int index = (dx / slot).floor().clamp(0, window.length - 1).toInt();
    if (_crosshair.index == index && _crosshair.candle == window[index]) return;
    setState(() {
      _crosshair = CrosshairState(
        index: index,
        candle: window[index],
        isActive: true,
      );
    });
  }
}

/// The crosshair tooltip strip.
class _ChartReadout extends StatelessWidget {
  const _ChartReadout({required this.candle});

  final Candle? candle;

  @override
  Widget build(BuildContext context) {
    final Candle? current = candle;
    if (current == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.spaceSm,
          vertical: AppSpacing.space2xs,
        ),
        child: Text('—'),
      );
    }
    // H, L and C carry the bucket's direction; O and V stay neutral because
    // colouring them would imply a comparison they do not have.
    final Color direction = current.close >= current.open
        ? AppColors.bull
        : AppColors.bear;
    return Semantics(
      container: true,
      label:
          'Selected candle ${current.startTime.toUtc().toIso8601String()}, '
          'open ${current.open.format()}, high ${current.high.format()}, '
          'low ${current.low.format()}, close ${current.close.format()}, '
          'volume ${current.volume.format()}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.spaceSm,
          vertical: AppSpacing.space2xs,
        ),
        child: Wrap(
          spacing: AppSpacing.spaceSm,
          runSpacing: AppSpacing.space2xs,
          children: <Widget>[
            _Cell(label: 'T', value: _time(current.startTime)),
            _Cell(label: 'O', value: current.open.format()),
            _Cell(label: 'H', value: current.high.format(), color: direction),
            _Cell(label: 'L', value: current.low.format(), color: direction),
            _Cell(label: 'C', value: current.close.format(), color: direction),
            _Cell(label: 'V', value: current.volume.format()),
          ],
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: AppTypography.labelSm.copyWith(color: AppColors.textSecondary),
        children: <InlineSpan>[
          TextSpan(text: '$label '),
          TextSpan(
            text: value,
            style: AppTypography.labelSm.copyWith(
              color: color ?? AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

String _time(DateTime value) {
  final DateTime utc = value.toUtc();
  final String hour = utc.hour.toString().padLeft(2, '0');
  final String minute = utc.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}
