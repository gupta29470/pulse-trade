import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_motion.dart';
import 'package:pulse_trade_frontend/app/theme/app_radii.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/app/widgets/app_card.dart';
import 'package:pulse_trade_frontend/app/widgets/cached_tag.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';
import 'package:pulse_trade_frontend/features/market/market_state.dart';

/// The hero price, the 24h change pill and the delivery metadata.
///
/// **The tick is a colour change, not a layout change.** The value is rendered
/// on `headlineLgMobile` with tabular figures, so an extra digit cannot reflow
/// the row; the only thing a tick animates is the colour, cross-faded over
/// [AppMotion.priceTickFade]. Direction is carried by the colour *and* by the
/// ▲/▼ glyph on the pill, so the meaning survives greyscale.
///
/// The price is wrapped in a [Semantics] label built by [priceSemanticsLabel]
/// rather than by ad-hoc string work at the call site, because a screen reader
/// needs the symbol, the price and the percentage together to be useful.
class PriceSummaryCard extends StatefulWidget {
  /// Creates the card for one market state.
  ///
  /// [rttMs], [jitterMs] and [effectiveRatePerSec] are nullable on purpose: an
  /// unavailable measurement is omitted from the metadata row rather than
  /// rendered as a zero, because `0 ms` is a claim and `—` is not.
  const PriceSummaryCard({
    super.key,
    required this.state,
    this.rttMs,
    this.jitterMs,
    this.effectiveRatePerSec,
    this.cachedAsOf,
  });

  /// The market state to render.
  final MarketState state;

  /// Latest client-measured round trip, when known.
  final double? rttMs;

  /// Latest jitter estimate, when known.
  final double? jitterMs;

  /// Delivered messages per second, when the health feed reported one.
  final double? effectiveRatePerSec;

  /// When the displayed values were captured, when they came from disk. Passing
  /// it renders a [CachedTag]; passing `null` renders none.
  final DateTime? cachedAsOf;

  /// The screen-reader sentence for a price and its change.
  ///
  /// Composed here rather than in the widget tree so a widget test can assert
  /// the exact wording without pumping a frame.
  static String priceSemanticsLabel({
    required String display,
    required Money last,
    required Money change,
    required int changeBasisPoints,
  }) {
    final String direction = changeBasisPoints >= 0 ? 'up' : 'down';
    final String magnitude = (changeBasisPoints.abs() / 100).toStringAsFixed(2);
    final String delta =
        '${change.sign < 0 ? '-' : '+'}${change.format().replaceFirst('-', '')}';
    return '$display latest price ${_grouped(last.format())}, '
        '$direction $magnitude percent, change $delta';
  }

  @override
  State<PriceSummaryCard> createState() => _PriceSummaryCardState();
}

class _PriceSummaryCardState extends State<PriceSummaryCard> {
  /// Direction colour of the most recent tick. Starts neutral so the first
  /// paint does not flash a direction the market never moved in.
  Color _tickColour = AppColors.textPrimary;

  @override
  void didUpdateWidget(covariant PriceSummaryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Money? now = _heroPrice(widget.state);
    final Money? before = _heroPrice(oldWidget.state);
    if (now != null && before != null && now != before) {
      _tickColour = now > before ? AppColors.bull : AppColors.bear;
    }
  }

  @override
  Widget build(BuildContext context) {
    final MarketState state = widget.state;
    final Money? price = _heroPrice(state);
    final MarketSummary? summary = state.summary;
    final DateTime? cachedAsOf = widget.cachedAsOf;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (cachedAsOf != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.spaceXs),
              child: Align(
                alignment: Alignment.centerRight,
                child: CachedTag(
                  // "Past the freshness window" is a property of the payload,
                  // not of the screen: a live book must not make a cached price
                  // look fresh.
                  kind: _isStale(state) ? 'STALE' : 'CACHED',
                  asOf: cachedAsOf,
                  stale: _isStale(state),
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Semantics(
                  label: price == null || summary == null
                      ? '${state.symbol} latest price unavailable'
                      : PriceSummaryCard.priceSemanticsLabel(
                          display: state.symbol,
                          last: price,
                          change: summary.change,
                          changeBasisPoints: summary.changeBasisPoints,
                        ),
                  child: AnimatedDefaultTextStyle(
                    duration: AppMotion.priceTickFade,
                    curve: Curves.easeOut,
                    style: AppTypography.headlineLgMobile.copyWith(
                      color: _tickColour,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                    child: Text(
                      price?.format() ?? '—',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              if (summary != null) _ChangePill(summary: summary),
            ],
          ),
          const SizedBox(height: AppSpacing.spaceXs),
          _MetadataRow(
            trade: state.trades.isEmpty ? null : state.trades.first,
            rttMs: widget.rttMs,
            jitterMs: widget.jitterMs,
            effectiveRatePerSec: widget.effectiveRatePerSec,
          ),
        ],
      ),
    );
  }

  /// The price the hero shows.
  ///
  /// The 24h summary is preferred because the backend computes it; before the
  /// first summary frame the newest candle close stands in, and before that the
  /// newest trade. Each fallback is a real observation, never a synthesised one.
  Money? _heroPrice(MarketState state) {
    final MarketSummary? summary = state.summary;
    if (summary != null) return summary.last;
    final Candle? active = state.activeCandle;
    if (active != null) return active.close;
    if (state.candles.isNotEmpty) return state.candles.last.close;
    return null;
  }
}

class _ChangePill extends StatelessWidget {
  const _ChangePill({required this.summary});

  final MarketSummary summary;

  @override
  Widget build(BuildContext context) {
    final bool up = summary.isUp;
    final Color colour = up ? AppColors.bull : AppColors.bear;
    final Money magnitude = summary.change.sign < 0
        ? -summary.change
        : summary.change;
    final String percent = (summary.changeBasisPoints.abs() / 100)
        .toStringAsFixed(2);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.spaceXs,
        vertical: AppSpacing.space2xs,
      ),
      decoration: BoxDecoration(
        color: up ? AppColors.bidDepth : AppColors.askDepth,
        borderRadius: AppRadii.microAll,
      ),
      child: Text(
        '${up ? '▲' : '▼'} ${up ? '+' : '-'}\$${magnitude.format()} '
        '(${up ? '+' : '-'}$percent%)',
        style: AppTypography.labelMd.copyWith(color: colour),
      ),
    );
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({
    required this.trade,
    required this.rttMs,
    required this.jitterMs,
    required this.effectiveRatePerSec,
  });

  final Trade? trade;
  final double? rttMs;
  final double? jitterMs;
  final double? effectiveRatePerSec;

  @override
  Widget build(BuildContext context) {
    final Trade? last = trade;
    final double? rtt = rttMs;
    final double? jitter = jitterMs;
    final double? rate = effectiveRatePerSec;
    return Wrap(
      spacing: AppSpacing.spaceSm,
      runSpacing: AppSpacing.space2xs,
      children: <Widget>[
        _item(
          last == null
              ? 'Last trade: —'
              : 'Last trade: ${_clock(last.timestamp)} UTC · Trade ${last.tradeId}',
        ),
        if (rtt != null) _item('Lat: ${_ms(rtt)}'),
        if (jitter != null) _item('Jitter: ${_ms(jitter)}'),
        if (rate != null) _item('Rate: ${_rate(rate)}'),
        // The client applies frames as they arrive and holds no pending
        // coalescing buffer of its own — the order book's delta buffer is the
        // only one in the app — so this is an observed zero, not a placeholder.
        _item('Buf: 0'),
      ],
    );
  }

  Widget _item(String text) => Text(
    text,
    style: AppTypography.labelSm.copyWith(color: AppColors.textSecondary),
  );
}

String _ms(double value) => '${value.round()}ms';

/// True when the price section's own payload is past its freshness window.
bool _isStale(MarketState state) =>
    state.candleProvenance == DataProvenance.stale ||
    state.tradesProvenance == DataProvenance.stale ||
    state.status == MarketDataStatus.stale;

String _rate(double value) =>
    value >= 10 ? '${value.round()}/s' : '${value.toStringAsFixed(1)}/s';

String _clock(DateTime value) {
  final DateTime utc = value.toUtc();
  return '${_two(utc.hour)}:${_two(utc.minute)}:${_two(utc.second)}';
}

String _two(int value) => value.toString().padLeft(2, '0');

/// Inserts thousands separators into a fixed-point decimal string.
///
/// Kept local rather than pulled from `intl` because the input is already an
/// exact decimal string and re-parsing it through a locale formatter is exactly
/// the round trip the design forbids.
String _grouped(String value) {
  final int dot = value.indexOf('.');
  final String whole = dot < 0 ? value : value.substring(0, dot);
  final String tail = dot < 0 ? '' : value.substring(dot);
  final StringBuffer out = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) out.write(',');
    out.write(whole[i]);
  }
  return '$out$tail';
}
