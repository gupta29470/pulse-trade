import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:pulse_trade_frontend/app/routing/app_router.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_radii.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/app/widgets/app_card.dart';
import 'package:pulse_trade_frontend/app/widgets/connection_chip.dart';
import 'package:pulse_trade_frontend/app/widgets/inline_notice.dart';
import 'package:pulse_trade_frontend/app/widgets/metric_tile.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/features/adaptive_delivery/adaptive_delivery_cubit.dart';
import 'package:pulse_trade_frontend/features/adaptive_delivery/adaptive_delivery_state.dart';
import 'package:pulse_trade_frontend/features/adaptive_delivery/widgets/tier_chip.dart';
import 'package:pulse_trade_frontend/features/adaptive_delivery/widgets/tier_explanation_sheet.dart';
import 'package:pulse_trade_frontend/features/connection/connection_bloc.dart';
import 'package:pulse_trade_frontend/features/connection/connection_state.dart';
import 'package:pulse_trade_frontend/features/market/market_bloc.dart';
import 'package:pulse_trade_frontend/features/market/market_event.dart';
import 'package:pulse_trade_frontend/features/market/market_state.dart';
import 'package:pulse_trade_frontend/features/market/widgets/chart_block.dart';
import 'package:pulse_trade_frontend/features/market/widgets/interval_selector.dart';
import 'package:pulse_trade_frontend/features/market/widgets/market_not_found_view.dart';
import 'package:pulse_trade_frontend/features/market/widgets/price_summary_card.dart';
import 'package:pulse_trade_frontend/features/market/widgets/trades_list.dart';
import 'package:pulse_trade_frontend/features/orderbook/order_book_bloc.dart';
import 'package:pulse_trade_frontend/features/orderbook/order_book_event.dart';
import 'package:pulse_trade_frontend/features/orderbook/order_book_state.dart';
import 'package:pulse_trade_frontend/features/orderbook/widgets/order_book_section.dart';

/// The routed market screen, top to bottom.
///
/// **This widget creates no blocs.** It reads the app-scoped [MarketBloc],
/// [OrderBookBloc] and [ConnectionBloc] from the context provided by the
/// composition root, which is what stops a navigation away and back from opening
/// a second socket. It also owns no crosshair or star state of its own: those
/// live in the small widgets that need them, so a 10 Hz tick cannot rebuild the
/// screen.
///
/// **The route names the market.** The blocs outlive the route, so when the
/// route symbol differs from the market the bloc is already showing, the page
/// starts both the market bloc and the order book on the new symbol. That is
/// what makes every roster symbol open its own live feed instead of reusing the
/// first one.
///
/// **An unknown symbol is a state, not a blank screen.** The roster must have
/// loaded before absence means anything, which is why [MarketState] carries
/// `markets` and `hasLoadedMarkets`.
class MarketPage extends StatefulWidget {
  /// Creates the page for [symbol].
  const MarketPage({super.key, required this.symbol});

  /// Canonical symbol id from the route.
  final String symbol;

  @override
  State<MarketPage> createState() => _MarketPageState();
}

class _MarketPageState extends State<MarketPage> {
  @override
  void initState() {
    super.initState();
    _bindRouteSymbol();
  }

  @override
  void didUpdateWidget(covariant MarketPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.symbol != widget.symbol) _bindRouteSymbol();
  }

  /// Points both market blocs at the symbol this route names.
  ///
  /// The order book is told first so its order-book-only subscription is the
  /// earlier one, leaving the market bloc's full-channel subscription the last
  /// word on the session.
  void _bindRouteSymbol() {
    final MarketBloc market = context.read<MarketBloc>();
    if (market.state.symbol == widget.symbol) return;
    context.read<OrderBookBloc>().add(OrderBookStarted(symbol: widget.symbol));
    market.add(MarketStarted(widget.symbol));
  }

  @override
  Widget build(BuildContext context) {
    final String symbol = widget.symbol;
    return BlocBuilder<MarketBloc, MarketState>(
      // Only facts that change the shell's shape: a price tick must not rebuild
      // the scaffold, the sections subscribe to the bloc themselves.
      buildWhen: _shellChanged,
      builder: (BuildContext context, MarketState state) {
        if (state.hasLoadedMarkets && !_hasSymbol(state.markets, symbol)) {
          return MarketNotFoundView(
            symbol: symbol,
            onBack: () => context.go('/watchlist'),
          );
        }
        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: _MarketAppBar(
            symbol: symbol,
            market: _marketFor(state.markets, symbol),
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenMarginPhone,
              vertical: AppSpacing.spaceSm,
            ),
            children: <Widget>[
              const _TelemetryStrip(),
              const SizedBox(height: AppSpacing.spaceSm),
              if (state.isPaused) ...<Widget>[
                const InlineNotice(message: 'Market generator paused'),
                const SizedBox(height: AppSpacing.spaceSm),
              ],
              const _PriceSection(),
              const SizedBox(height: AppSpacing.spaceSm),
              const _IntervalSection(),
              const SizedBox(height: AppSpacing.spaceXs),
              const _ChartSection(),
              const SizedBox(height: AppSpacing.spaceSm),
              const _BookSection(),
              const SizedBox(height: AppSpacing.spaceSm),
              const _TradesSection(),
            ],
          ),
        );
      },
    );
  }
}

bool _shellChanged(MarketState previous, MarketState next) =>
    previous.symbol != next.symbol ||
    previous.hasLoadedMarkets != next.hasLoadedMarkets ||
    previous.markets != next.markets ||
    previous.marketStatus != next.marketStatus;

bool _hasSymbol(List<MarketInfo> markets, String symbol) {
  for (final MarketInfo market in markets) {
    if (market.symbol == symbol) return true;
  }
  return false;
}

MarketInfo? _marketFor(List<MarketInfo> markets, String symbol) {
  for (final MarketInfo market in markets) {
    if (market.symbol == symbol) return market;
  }
  return null;
}

/// App bar: symbol, `SIM` badge, display pair, star and overflow menu.
class _MarketAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _MarketAppBar({required this.symbol, required this.market});

  final String symbol;
  final MarketInfo? market;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 18);

  @override
  Widget build(BuildContext context) {
    final MarketInfo? info = market;
    return AppBar(
      // This is a tab root, not a pushed page: the bottom bar is the way back,
      // an implied back arrow would be a control that only leads to this
      // same screen.
      automaticallyImplyLeading: false,
      backgroundColor: AppColors.surface1,
      titleSpacing: AppSpacing.spaceSm,
      title: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              symbol,
              style: AppTypography.headlineSm.copyWith(
                color: AppColors.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.spaceXs),
          const _SimBadge(),
        ],
      ),
      actions: <Widget>[
        _StarToggle(display: info?.display ?? symbol),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: 'More',
          onSelected: (String value) {
            if (value == 'diagnostics') context.push('/diagnostics');
          },
          itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: 'diagnostics',
              child: Text('Diagnostics'),
            ),
          ],
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(18),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.spaceMd,
              bottom: AppSpacing.space2xs,
            ),
            child: Text(
              info?.display ?? symbol,
              style: AppTypography.bodySm.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The `SIM` badge marks a simulated market. There is no perpetual market here,
/// so the badge must not imply one.
class _SimBadge extends StatelessWidget {
  const _SimBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.space2xs,
        vertical: AppSpacing.space2xs / 2,
      ),
      decoration: BoxDecoration(
        borderRadius: AppRadii.microAll,
        border: Border.all(color: AppColors.outlineFocus),
      ),
      child: Text(
        'SIM',
        style: AppTypography.labelSm.copyWith(color: AppColors.textSecondary),
      ),
    );
  }
}

/// Star toggle. Local state until the watchlist bloc owns the favourite; the
/// control is present, labelled and 48dp, and never silently does nothing.
class _StarToggle extends StatefulWidget {
  const _StarToggle({required this.display});

  final String display;

  @override
  State<_StarToggle> createState() => _StarToggleState();
}

class _StarToggleState extends State<_StarToggle> {
  bool _starred = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: _starred,
      label: _starred
          ? 'Remove ${widget.display} from watchlist'
          : 'Add ${widget.display} to watchlist',
      child: IconButton(
        onPressed: () => setState(() => _starred = !_starred),
        icon: Icon(_starred ? Icons.star : Icons.star_border),
        color: _starred ? AppColors.textPrimary : AppColors.textSecondary,
        tooltip: _starred ? 'Starred' : 'Star',
      ),
    );
  }
}

/// Chip, tier chip and the three 24h statistics.
class _TelemetryStrip extends StatelessWidget {
  const _TelemetryStrip();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Flexible(child: _ConnectionChipSlot()),
              SizedBox(width: AppSpacing.spaceXs),
              Flexible(child: _TierChipSlot()),
            ],
          ),
          const SizedBox(height: AppSpacing.spaceSm),
          BlocBuilder<MarketBloc, MarketState>(
            buildWhen: (MarketState previous, MarketState next) =>
                previous.summary != next.summary,
            builder: (BuildContext context, MarketState state) {
              final MarketSummary? summary = state.summary;
              return Row(
                children: <Widget>[
                  Expanded(
                    child: MetricTile(
                      label: '24h High',
                      value: summary?.high24h.format() ?? '—',
                    ),
                  ),
                  Expanded(
                    child: MetricTile(
                      label: '24h Low',
                      value: summary?.low24h.format() ?? '—',
                    ),
                  ),
                  Expanded(
                    child: MetricTile(
                      label: '24h Vol',
                      value: summary?.volume24h.format() ?? '—',
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The chip's value, derived from two independent layers and never collapsed:
/// the transport owns liveness, the engine owns "paused".
class _ConnectionChipSlot extends StatelessWidget {
  const _ConnectionChipSlot();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MarketBloc, MarketState>(
      buildWhen: (MarketState previous, MarketState next) =>
          previous.isPaused != next.isPaused ||
          previous.oldestAsOf != next.oldestAsOf,
      builder: (BuildContext context, MarketState market) =>
          BlocBuilder<ConnectionBloc, PtConnectionState>(
            builder: (BuildContext context, PtConnectionState connection) =>
                ConnectionChip(
                  state: _chipState(market, connection),
                  // `ConnectionChip` takes whole milliseconds and a coarse age; the
                  // wall clock is reached through `Clock` so no widget calls
                  // `DateTime.now`.
                  rttMs: connection is ConnectionConnected
                      ? connection.rttMs
                      : null,
                  cachedAge: market.oldestAsOf == null
                      ? null
                      : _chipClock.now().difference(market.oldestAsOf!),
                  compact: true,
                ),
          ),
    );
  }
}

class _TierChipSlot extends StatelessWidget {
  const _TierChipSlot();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ConnectionBloc, PtConnectionState>(
      builder: (BuildContext context, PtConnectionState connection) {
        final bool connected = connection is ConnectionConnected;
        final DeliveryTier tier = connected
            ? connection.tier
            : DeliveryTier.full;
        final TierChip chip = TierChip(
          tier: tier,
          // Before the first `health` frame the backend's target rate is
          // unknown; the nominal rate is only a fallback and zero is honest.
          targetRatePerSec: connected ? tier.nominalTargetRatePerSec : 0,
          isOverridden: false,
          // The info affordance explains the tier from the backend's own report:
          // the client never decides or estimates a tier.
          onInfoTap: () {
            final AdaptiveDeliveryState delivery = context
                .read<AdaptiveDeliveryCubit>()
                .state;
            unawaited(
              TierExplanationSheet.show(
                context,
                current: delivery.tier,
                rttMs: delivery.rttMs,
                jitterMs: delivery.jitterMs,
                reason: delivery.reason,
                isOverridden: delivery.tierOverride.isActive,
              ),
            );
          },
        );
        return GestureDetector(
          // The debug console holds the documented forced-tier control.
          // Long-pressing the tier chip keeps that control next to the thing it
          // changes, and only in builds that register the route.
          onLongPress: kDebugMode ? () => context.push(AppPaths.debug) : null,
          child: chip,
        );
      },
    );
  }
}

/// The single clock this page uses, only to age a cached value for the chip.
/// A static instance keeps `Clock` allocation off the build path.
final Clock _chipClock = SystemClock();

ConnectionChipState _chipState(
  MarketState market,
  PtConnectionState connection,
) {
  if (market.isPaused) return ConnectionChipState.paused;
  if (connection is ConnectionConnected) return _chipForTier(connection.tier);
  if (connection is ConnectionConnecting) return ConnectionChipState.connecting;
  if (connection is ConnectionReconnecting) return ConnectionChipState.stale;
  if (connection is ConnectionStale) return ConnectionChipState.stale;
  if (connection is ConnectionOffline) return ConnectionChipState.offline;
  return ConnectionChipState.offline;
}

ConnectionChipState _chipForTier(DeliveryTier tier) => switch (tier) {
  DeliveryTier.full => ConnectionChipState.live,
  DeliveryTier.degraded => ConnectionChipState.degraded,
  DeliveryTier.minimal => ConnectionChipState.minimal,
};

class _PriceSection extends StatelessWidget {
  const _PriceSection();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MarketBloc, MarketState>(
      buildWhen: (MarketState previous, MarketState next) =>
          previous.summary != next.summary ||
          previous.activeCandle != next.activeCandle ||
          previous.trades.isNotEmpty != next.trades.isNotEmpty ||
          previous.status != next.status ||
          previous.oldestAsOf != next.oldestAsOf,
      builder: (BuildContext context, MarketState state) =>
          BlocBuilder<ConnectionBloc, PtConnectionState>(
            builder: (BuildContext context, PtConnectionState connection) =>
                PriceSummaryCard(
                  state: state,
                  rttMs: connection is ConnectionConnected
                      ? connection.rttMs.toDouble()
                      : null,
                  // The tag is only meaningful while the values are not live.
                  cachedAsOf: state.status == MarketDataStatus.live
                      ? null
                      : state.oldestAsOf,
                ),
          ),
    );
  }
}

class _IntervalSection extends StatelessWidget {
  const _IntervalSection();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MarketBloc, MarketState>(
      buildWhen: (MarketState previous, MarketState next) =>
          previous.interval != next.interval ||
          previous.isRefreshing != next.isRefreshing,
      builder: (BuildContext context, MarketState state) => IntervalSelector(
        selected: state.interval,
        isRefreshing: state.isRefreshing,
        onSelected: (CandleInterval interval) =>
            context.read<MarketBloc>().add(MarketIntervalSelected(interval)),
      ),
    );
  }
}

class _ChartSection extends StatelessWidget {
  const _ChartSection();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MarketBloc, MarketState>(
      buildWhen: (MarketState previous, MarketState next) =>
          !identical(previous.candles, next.candles) ||
          previous.activeCandle != next.activeCandle ||
          previous.status != next.status ||
          previous.failure != next.failure ||
          previous.candleProvenance != next.candleProvenance ||
          previous.candleAsOf != next.candleAsOf,
      builder: (BuildContext context, MarketState state) => ChartBlock(
        state: state,
        onRetry: () => context.read<MarketBloc>().add(
          const MarketHistoryRefreshRequested(forceRefresh: true),
        ),
      ),
    );
  }
}

class _BookSection extends StatelessWidget {
  const _BookSection();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<OrderBookBloc, OrderBookStateModel>(
      builder: (BuildContext context, OrderBookStateModel state) =>
          OrderBookSection(
            state: state,
            onRetry: () => context.read<OrderBookBloc>().add(
              const OrderBookRetryRequested(),
            ),
          ),
    );
  }
}

class _TradesSection extends StatelessWidget {
  const _TradesSection();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MarketBloc, MarketState>(
      buildWhen: (MarketState previous, MarketState next) =>
          !identical(previous.trades, next.trades) ||
          previous.omittedTradeCount != next.omittedTradeCount,
      builder: (BuildContext context, MarketState state) => TradesList(
        trades: state.trades,
        omittedCount: state.omittedTradeCount,
      ),
    );
  }
}
