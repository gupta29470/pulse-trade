import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pulse_trade_frontend/app/routing/app_router.dart';
import 'package:pulse_trade_frontend/app/routing/deep_link_handler.dart';
import 'package:pulse_trade_frontend/core/cache/cache_store.dart';
import 'package:pulse_trade_frontend/core/cache/file_cache_store.dart';
import 'package:pulse_trade_frontend/core/cache/market_cache_repository.dart';
import 'package:pulse_trade_frontend/core/cache/prefs_cache_store.dart';
import 'package:pulse_trade_frontend/core/cache/tiered_cache_store.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/failure_mapper.dart';
import 'package:pulse_trade_frontend/core/lifecycle/app_lifecycle_observer.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/network_connectivity/service/connectivity_service.dart';
import 'package:pulse_trade_frontend/core/networking/connectivity_offline_gate.dart';
import 'package:pulse_trade_frontend/core/networking/dio_market_api.dart';
import 'package:pulse_trade_frontend/core/networking/market_api.dart';
import 'package:pulse_trade_frontend/core/networking/market_websocket_client.dart';
import 'package:pulse_trade_frontend/core/storage/app_storage.dart';
import 'package:pulse_trade_frontend/core/storage/storage_keys.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/data/dto/market_dto_decoder_impl.dart';
import 'package:pulse_trade_frontend/data/parser/market_message_parser.dart';
import 'package:pulse_trade_frontend/data/repositories/caching_market_history_repository.dart';
import 'package:pulse_trade_frontend/data/repositories/caching_market_summary_repository.dart';
import 'package:pulse_trade_frontend/data/repositories/caching_order_book_repository.dart';
import 'package:pulse_trade_frontend/data/repositories/debug_http_client.dart';
import 'package:pulse_trade_frontend/data/repositories/http_metrics_repository.dart';
import 'package:pulse_trade_frontend/data/repositories/prefs_watchlist_storage.dart';
import 'package:pulse_trade_frontend/data/repositories/socket_market_stream_repository.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/subscription_spec.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_history_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_stream_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_summary_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/metrics_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/order_book_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/watchlist_storage.dart';
import 'package:pulse_trade_frontend/features/adaptive_delivery/adaptive_delivery_cubit.dart';
import 'package:pulse_trade_frontend/features/connection/connection_bloc.dart';
import 'package:pulse_trade_frontend/features/connection/connection_event.dart';
import 'package:pulse_trade_frontend/features/connection/reconnect_policy.dart';
import 'package:pulse_trade_frontend/features/debug/debug_console_cubit.dart';
import 'package:pulse_trade_frontend/features/diagnostics/diagnostics_cubit.dart';
import 'package:pulse_trade_frontend/features/market/market_bloc.dart';
import 'package:pulse_trade_frontend/features/market/market_event.dart';
import 'package:pulse_trade_frontend/features/orderbook/order_book_bloc.dart';
import 'package:pulse_trade_frontend/features/orderbook/order_book_event.dart';
import 'package:pulse_trade_frontend/features/orderbook/order_book_state.dart';
import 'package:pulse_trade_frontend/features/watchlist/watchlist_cubit.dart';

/// The hand-written composition root.
///
/// There is deliberately no service-locator package: every dependency is
/// constructed here, in dependency order, so a reader can see the whole object
/// graph in one file and a test can build the same graph with fakes by
/// constructing the pieces directly.
///
/// Ownership is explicit: [dispose] releases exactly what [initialize] created,
/// in reverse order.
final class AppBootstrap {
  AppBootstrap._({
    required this.clock,
    required this.metrics,
    required this.connectivity,
    required this.storage,
    required this.cacheStore,
    required this.cache,
    required this.marketApi,
    required this.stream,
    required this.history,
    required this.orderBooks,
    required this.summaries,
    required this.metricsRepository,
    required this.watchlistStorage,
    required this.subscription,
    required this.router,
    required this.lifecycle,
    required this.connectionBloc,
    required this.marketBloc,
    required this.orderBookBloc,
    required this.adaptiveDeliveryCubit,
    required this.watchlistCubit,
    required this.diagnosticsCubit,
    required this.debugConsoleCubit,
  });

  /// The process-wide clock. Nothing else may call `DateTime.now()`.
  final SystemClock clock;

  /// On-device counters surfaced in diagnostics.
  final OnDeviceMetrics metrics;

  /// Internet reachability.
  final ConnectivityService connectivity;

  /// Versioned key/value persistence.
  final AppStorage storage;

  /// The file-backed market cache tier.
  final CacheStore cacheStore;

  /// Domain-level cache façade with the TTLs.
  final MarketCacheRepository cache;

  /// The offline-gated REST client.
  final MarketApi marketApi;

  /// The parsed socket stream.
  final MarketStreamRepository stream;

  /// Candle history, cache-first.
  final MarketHistoryRepository history;

  /// Book snapshots, cache-first.
  final OrderBookRepository orderBooks;

  /// 24h summaries and the market roster.
  final MarketSummaryRepository summaries;

  /// The backend metrics API.
  final MetricsRepository metricsRepository;

  /// Watchlist persistence.
  final WatchlistStorage watchlistStorage;

  /// The session subscription the connection bloc re-sends after a reconnect.
  final SubscriptionSpec subscription;

  /// Route configuration.
  final AppRouter router;

  /// Background/foreground policy.
  final AppLifecycleObserver lifecycle;

  /// Socket lifecycle.
  final ConnectionBloc connectionBloc;

  /// Candles, trades and the 24h summary.
  final MarketBloc marketBloc;

  /// Snapshot/delta synchronisation.
  final OrderBookBloc orderBookBloc;

  /// Backend-reported delivery state.
  final AdaptiveDeliveryCubit adaptiveDeliveryCubit;

  /// Watchlist ordering and favourites.
  final WatchlistCubit watchlistCubit;

  /// Polled telemetry.
  final DiagnosticsCubit diagnosticsCubit;

  /// Debug controls and fault injection.
  final DebugConsoleCubit debugConsoleCubit;

  StreamSubscription<InternetStatus?>? _connectivitySubscription;

  /// Routes `pulsetrade://` links onto screens.
  DeepLinkHandler? _deepLinks;

  /// Re-probes reachability while the app believes it is offline.
  ///
  /// The connectivity layer publishes on change, and a change is not guaranteed
  /// to be observed: the checker's stream can miss a transition, and the service
  /// deliberately ignores a disconnect read while backgrounded. A status that
  /// stays `disconnected` would keep the offline gate refusing every dial, so
  /// the app asks again on a timer and recovery does not depend on the signal
  /// that failed.
  Timer? _reachabilityReprobeTimer;
  StreamSubscription<OrderBookStateModel>? _bookStateSubscription;
  bool _disposed = false;

  /// The base URL used when the user has not overridden it.
  ///
  /// The deployed backend, so a plain build connects with no configuration. A
  /// build that should talk to a local one overrides it with
  /// `--dart-define=PULSETRADE_GATEWAY=http://<host>:8080`, and an install that
  /// already carries a stored override keeps using that.
  static const String defaultBaseUrl = String.fromEnvironment(
    'PULSETRADE_GATEWAY',
    defaultValue: 'https://pulse-trade-backend.onrender.com',
  );

  /// The symbol the market tab opens on before any route names another.
  static const String liveSymbol = 'BTCUSDT';

  /// Builds every collaborator and returns the composition root.
  ///
  /// Fails soft: a cache directory that cannot be created, a connectivity probe
  /// that never answers, or a preference that cannot be read all degrade to a
  /// working, honest app rather than a crash on launch.
  static Future<AppBootstrap> initialize() async {
    final SystemClock clock = SystemClock();
    AppLogger.clock = clock;

    final OnDeviceMetrics metrics = OnDeviceMetrics();
    const FailureMapper failureMapper = FailureMapper();

    final ConnectivityService connectivity = ConnectivityService(clock: clock);
    await connectivity.initializeConnectionChecker();

    final AppStorage storage = await AppStorage.open();
    // Two tiers, one facade: the small preferences tier holds the
    // market roster, the 8 MB file tier holds candles, books and trades. Routing
    // lives in the store so no call site can put 500 candles in prefs.
    final CacheStore fileCacheStore = await FileCacheStore.open(
      metrics: metrics,
      clock: clock,
    );
    final CacheStore prefsCacheStore = PrefsCacheStore(
      storage: storage,
      metrics: metrics,
      clock: clock,
    );
    final CacheStore cacheStore = TieredCacheStore(
      prefsTier: prefsCacheStore,
      fileTier: fileCacheStore,
    );
    final MarketCacheRepository cache = MarketCacheRepository(
      store: cacheStore,
      clock: clock,
      metrics: metrics,
    );

    final String baseUrl =
        storage.readString(StorageKeys.backendBaseUrl) ?? defaultBaseUrl;
    final Dio dio = Dio(BaseOptions(baseUrl: baseUrl));
    final MarketApi rawApi = DioMarketApi(
      dio: dio,
      failureMapper: failureMapper,
      clock: clock,
      baseUrl: baseUrl,
      decoder: const MarketDtoDecoderImpl(),
      metrics: metrics,
    );
    final ConnectivityOfflineGate gate = ConnectivityOfflineGate(
      connectivity: connectivity,
    );
    final MarketApi marketApi = OfflineGatedMarketApi(
      inner: rawApi,
      gate: gate,
      metrics: metrics,
    );

    final MarketWebSocketClient socket = OfflineGatedWebSocketClient(
      inner: WebSocketMarketClient(
        failureMapper: failureMapper,
        metrics: metrics,
      ),
      gate: gate,
      metrics: metrics,
    );
    final MarketStreamRepository stream = SocketMarketStreamRepository(
      client: socket,
      parser: MarketMessageParser(metrics: metrics, clock: clock),
      url: _webSocketUriFor(baseUrl),
      failureMapper: failureMapper,
      metrics: metrics,
    );

    final MarketHistoryRepository history = CachingMarketHistoryRepository(
      api: marketApi,
      cache: cache,
      failureMapper: failureMapper,
      clock: clock,
    );
    final OrderBookRepository orderBooks = CachingOrderBookRepository(
      api: marketApi,
      cache: cache,
      failureMapper: failureMapper,
      clock: clock,
    );
    final MarketSummaryRepository summaries = CachingMarketSummaryRepository(
      api: marketApi,
      cache: cache,
      failureMapper: failureMapper,
      clock: clock,
    );
    final MetricsRepository metricsRepository = HttpMetricsRepository(
      api: marketApi,
      failureMapper: failureMapper,
    );

    final WatchlistStorage watchlistStorage = PrefsWatchlistStorage(
      storage: storage,
    );

    const SubscriptionSpec subscription = SubscriptionSpec(
      symbol: liveSymbol,
      interval: CandleInterval.defaultInterval,
    );

    final ConnectionBloc connectionBloc = ConnectionBloc(
      stream: stream,
      subscription: subscription,
      policy: ReconnectPolicy(),
      clock: clock,
      metrics: metrics,
      // Subscriptions are per session, so the connection bloc re-sends this one
      // after every reconnect.
    );
    final MarketBloc marketBloc = MarketBloc(
      history: history,
      summaries: summaries,
      orderBooks: orderBooks,
      stream: stream,
      symbol: liveSymbol,
      clock: clock,
      metrics: metrics,
    );
    final OrderBookBloc orderBookBloc = OrderBookBloc(
      repository: orderBooks,
      stream: stream,
      symbol: liveSymbol,
      clock: clock,
      metrics: metrics,
    );
    final AdaptiveDeliveryCubit adaptiveDeliveryCubit = AdaptiveDeliveryCubit(
      stream: stream,
      clock: clock,
    );
    final WatchlistCubit watchlistCubit = WatchlistCubit(
      storage: watchlistStorage,
      summaries: summaries,
      marketStream: stream,
      metrics: metrics,
    );
    final DiagnosticsCubit diagnosticsCubit = DiagnosticsCubit(
      metrics: metricsRepository,
      stream: stream,
      counters: metrics,
      clock: clock,
    );
    final DebugHttpClient debugHttpClient = DebugHttpClient(
      dio: dio,
      failureMapper: failureMapper,
      clock: clock,
      baseUrl: baseUrl,
    );
    final DebugConsoleCubit debugConsoleCubit = DebugConsoleCubit(
      api: marketApi,
      stream: stream,
      metrics: metrics,
      clock: clock,
      debugRequest: debugHttpClient.call,
    );

    final AppLifecycleObserver lifecycle = AppLifecycleObserver(
      onBackgrounded: () {
        // Heartbeats stop immediately; the socket survives until the timeout.
        connectionBloc.add(const AppBackgrounded());
      },
      // Resumable: the timeout exists to stop paying for a socket nobody is
      // watching, not to end the session. `resumeOnForeground` is what keeps the
      // return path able to dial again.
      onBackgroundTimeout: () => connectionBloc.add(
        const Disconnect(
          reason: 'background_timeout',
          resumeOnForeground: true,
        ),
      ),
      onForegrounded: () {
        gate.reset();
        connectionBloc.add(const AppForegrounded());
      },
      clock: clock,
    );

    return AppBootstrap._(
      clock: clock,
      metrics: metrics,
      connectivity: connectivity,
      storage: storage,
      cacheStore: cacheStore,
      cache: cache,
      marketApi: marketApi,
      stream: stream,
      history: history,
      orderBooks: orderBooks,
      summaries: summaries,
      metricsRepository: metricsRepository,
      watchlistStorage: watchlistStorage,
      subscription: subscription,
      router: AppRouter.create(),
      lifecycle: lifecycle,
      connectionBloc: connectionBloc,
      marketBloc: marketBloc,
      orderBookBloc: orderBookBloc,
      adaptiveDeliveryCubit: adaptiveDeliveryCubit,
      watchlistCubit: watchlistCubit,
      diagnosticsCubit: diagnosticsCubit,
      debugConsoleCubit: debugConsoleCubit,
    );
  }

  /// How often an offline app re-asks whether it is still offline.
  ///
  /// Only ever runs while the last reading was not connected, and each tick is
  /// one cheap probe, so the cost is bounded by how long the app spends offline.
  static const Duration _reachabilityReprobeInterval = Duration(seconds: 5);

  /// Starts the offline re-probe loop; idempotent.
  void _startReachabilityReprobe() {
    _reachabilityReprobeTimer ??= Timer.periodic(_reachabilityReprobeInterval, (
      _,
    ) {
      if (_disposed) return;
      if (connectivity.isInternetConnectionAvailable) return;
      // Publishes through the normal path, so the connection bloc reacts to a
      // recovered reading exactly as it would to a streamed one.
      unawaited(connectivity.checkConnection());
    });
  }

  /// Attaches the lifecycle observer, watches connectivity and dispatches the
  /// initial events into each bloc.
  ///
  /// Called from the widget tree (not from [initialize]) so the tree exists
  /// before the first state lands.
  void start() {
    lifecycle.attach();
    _startReachabilityReprobe();
    _deepLinks = DeepLinkHandler(router: router)..attach();
    _connectivitySubscription = connectivity.internetStatusStream.listen((
      InternetStatus? status,
    ) {
      if (status == null) return;
      connectionBloc.add(InternetStatusChanged(status));
      // The diagnostics matrix shows the internet layer; it is push-fed so the
      // screen never probes the network itself.
      diagnosticsCubit.reportInternetStatus(
        status == InternetStatus.connected ? 'ONLINE' : 'OFFLINE',
      );
    });

    // Order book -> diagnostics bridge. The bloc deliberately knows nothing
    // about diagnostics, so the composition root is what publishes its sync
    // state (last applied range, gap and recovery counts).
    _bookStateSubscription = orderBookBloc.stream.listen(
      (OrderBookStateModel book) => diagnosticsCubit.reportBookState(
        state: book.syncState,
        epoch: book.epoch,
        appliedUpdateId: book.appliedUpdateId,
        first: book.lastAppliedFirstUpdateId,
        last: book.lastAppliedLastUpdateId,
        gaps: book.gapCount,
        duplicates: book.duplicateCount,
        stale: book.staleCount,
        recoveries: book.recoveryCount,
      ),
    );

    connectionBloc.add(const Connect());
    marketBloc.add(const MarketStarted(liveSymbol));
    orderBookBloc.add(const OrderBookStarted());
    unawaited(watchlistCubit.load());
    unawaited(_publishCacheStats());
  }

  /// Publishes the on-device cache size once, so the diagnostics page has a real
  /// number before the user opens Storage & cache.
  Future<void> _publishCacheStats() async {
    final CacheStats stats = await cacheStore.stats();
    diagnosticsCubit.reportCacheStats(stats.toJson());
  }

  /// Releases every owned resource. Safe to call twice.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _deepLinks?.dispose();
    _deepLinks = null;
    _reachabilityReprobeTimer?.cancel();
    _reachabilityReprobeTimer = null;
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    await _bookStateSubscription?.cancel();
    _bookStateSubscription = null;
    lifecycle.dispose();
    await diagnosticsCubit.close();
    await debugConsoleCubit.close();
    await watchlistCubit.close();
    await adaptiveDeliveryCubit.close();
    await orderBookBloc.close();
    await marketBloc.close();
    await connectionBloc.close();
    await stream.dispose();
    connectivity.dispose();
  }

  /// Converts the REST base URL into the socket URL (`http` → `ws`, path `/ws`).
  static Uri _webSocketUriFor(String baseUrl) {
    final Uri? base = Uri.tryParse(baseUrl);
    if (base == null || base.host.isEmpty) {
      // A malformed URL has no host to convert, so this is a defensive branch.
      // It derives from the shipped default rather than naming a host of its
      // own: a socket fallback pointing somewhere the REST fallback does not is
      // a second, silent default.
      final Uri fallback = Uri.parse(defaultBaseUrl);
      return fallback.replace(
        scheme: fallback.scheme == 'https' ? 'wss' : 'ws',
        path: '/ws',
      );
    }
    final String scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return base.replace(scheme: scheme, path: '/ws');
  }
}

/// Provides the composition root's blocs and cubits to the widget tree and
/// starts the app once, from `initState`.
class AppScope extends StatefulWidget {
  /// Wraps [child] with every provider.
  const AppScope({super.key, required this.bootstrap, required this.child});

  /// The composition root.
  final AppBootstrap bootstrap;

  /// The routed widget tree.
  final Widget child;

  @override
  State<AppScope> createState() => _AppScopeState();
}

class _AppScopeState extends State<AppScope> {
  @override
  void initState() {
    super.initState();
    widget.bootstrap.start();
  }

  @override
  Widget build(BuildContext context) {
    final AppBootstrap bootstrap = widget.bootstrap;
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<ConnectivityService>.value(
          value: bootstrap.connectivity,
        ),
        RepositoryProvider<MarketStreamRepository>.value(
          value: bootstrap.stream,
        ),
        RepositoryProvider<MetricsRepository>.value(
          value: bootstrap.metricsRepository,
        ),
        RepositoryProvider<MarketHistoryRepository>.value(
          value: bootstrap.history,
        ),
        RepositoryProvider<OrderBookRepository>.value(
          value: bootstrap.orderBooks,
        ),
        RepositoryProvider<MarketSummaryRepository>.value(
          value: bootstrap.summaries,
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<ConnectionBloc>.value(value: bootstrap.connectionBloc),
          BlocProvider<MarketBloc>.value(value: bootstrap.marketBloc),
          BlocProvider<OrderBookBloc>.value(value: bootstrap.orderBookBloc),
          BlocProvider<AdaptiveDeliveryCubit>.value(
            value: bootstrap.adaptiveDeliveryCubit,
          ),
          BlocProvider<WatchlistCubit>.value(value: bootstrap.watchlistCubit),
          BlocProvider<DiagnosticsCubit>.value(
            value: bootstrap.diagnosticsCubit,
          ),
          BlocProvider<DebugConsoleCubit>.value(
            value: bootstrap.debugConsoleCubit,
          ),
        ],
        child: widget.child,
      ),
    );
  }
}
