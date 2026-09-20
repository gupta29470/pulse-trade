import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_summary_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/watchlist_storage.dart';
import 'package:pulse_trade_frontend/features/watchlist/watchlist_cubit.dart';
import 'package:pulse_trade_frontend/features/watchlist/watchlist_state.dart';

final DateTime _time = DateTime.utc(2026, 9, 17, 12, 41, 3);

MarketInfo _market({
  required String symbol,
  required String display,
  required String name,
  required String glyph,
  required String lastPrice,
  required int changeBasisPoints,
}) => MarketInfo(
  symbol: symbol,
  display: display,
  name: name,
  glyph: glyph,
  priceDigits: 2,
  quantityDigits: 8,
  lastPrice: Money.parse(lastPrice),
  changeBasisPoints: changeBasisPoints,
);

final List<MarketInfo> _markets = <MarketInfo>[
  _market(
    symbol: 'BTCUSDT',
    display: 'BTC/USDT',
    name: 'Bitcoin',
    glyph: 'B',
    lastPrice: '67421.35',
    changeBasisPoints: 18,
  ),
  _market(
    symbol: 'ETHUSDT',
    display: 'ETH/USDT',
    name: 'Ethereum',
    glyph: 'E',
    lastPrice: '2500.00',
    changeBasisPoints: -12,
  ),
  _market(
    symbol: 'SOLUSDT',
    display: 'SOL/USDT',
    name: 'Solana',
    glyph: 'S',
    lastPrice: '142.10',
    changeBasisPoints: 5,
  ),
];

/// A storage double whose writes can be made to fail on demand.
final class _FakeWatchlistStorage implements WatchlistStorage {
  _FakeWatchlistStorage({List<String>? order})
    : order = order ?? <String>['BTCUSDT', 'ETHUSDT', 'SOLUSDT'];

  List<String> order;
  Set<String> favourites = <String>{'BTCUSDT'};
  String? pinned;
  bool failWrites = false;
  int saveOrderCalls = 0;

  @override
  Future<List<String>> loadOrder() async => List<String>.of(order);

  @override
  Future<void> saveOrder(List<String> symbols) async {
    saveOrderCalls++;
    if (failWrites) {
      throw StateError('disk full');
    }
    order = List<String>.of(symbols);
  }

  @override
  Future<Set<String>> loadFavourites() async => Set<String>.of(favourites);

  @override
  Future<void> saveFavourites(Set<String> symbols) async {
    if (failWrites) throw StateError('disk full');
    favourites = Set<String>.of(symbols);
  }

  @override
  Future<String?> loadPinned() async => pinned;

  @override
  Future<void> savePinned(String? symbol) async {
    if (failWrites) throw StateError('disk full');
    pinned = symbol;
  }
}

/// A summary double that answers both the roster and the 24h view.
final class _FakeSummaries implements MarketSummaryRepository {
  _FakeSummaries({List<MarketInfo>? markets}) : markets = markets ?? _markets;

  List<MarketInfo> markets;
  bool failMarkets = false;
  int marketCalls = 0;
  int summaryCalls = 0;

  @override
  Future<Result<Sourced<List<MarketInfo>>>> loadMarkets({
    bool forceRefresh = false,
  }) async {
    marketCalls++;
    if (failMarkets) {
      return const Err<Sourced<List<MarketInfo>>>(NetworkFailure());
    }
    return Ok<Sourced<List<MarketInfo>>>(
      Sourced<List<MarketInfo>>.live(markets, asOf: _time),
    );
  }

  @override
  Future<Result<Sourced<MarketSummary>>> loadSummary(
    String symbol, {
    bool forceRefresh = false,
  }) async {
    summaryCalls++;
    return Ok<Sourced<MarketSummary>>(
      Sourced<MarketSummary>.live(
        MarketSummary(
          symbol: symbol,
          last: Money.parse('67421.35'),
          open24h: Money.parse('67300.00'),
          high24h: Money.parse('67500.00'),
          low24h: Money.parse('67200.00'),
          volume24h: Quantity.parse('184.22000000'),
          change: Money.parse('121.35'),
          changeBasisPoints: 18,
          trades24h: 412,
          updatedAt: _time,
        ),
        asOf: _time,
      ),
    );
  }
}

List<String> _symbolsOf(WatchlistState state) => <String>[
  for (final WatchlistEntry entry in state.entries) entry.symbol,
];

WatchlistEntry _entry(WatchlistCubit cubit, String symbol) => cubit
    .state
    .entries
    .firstWhere((WatchlistEntry entry) => entry.symbol == symbol);

void main() {
  group('WatchlistCubit (M-14)', () {
    test('load reconciles the persisted order with the roster', () async {
      final _FakeWatchlistStorage storage = _FakeWatchlistStorage(
        order: <String>['ETHUSDT', 'BTCUSDT'],
      );
      final WatchlistCubit cubit = WatchlistCubit(
        storage: storage,
        summaries: _FakeSummaries(),
      );

      await cubit.load();

      // The stored order wins; a roster symbol the user has never seen is
      // appended rather than dropped.
      expect(_symbolsOf(cubit.state), <String>[
        'ETHUSDT',
        'BTCUSDT',
        'SOLUSDT',
      ]);
      expect(cubit.state.isLoading, isFalse);
      expect(cubit.state.marketsLoaded, isTrue);
      expect(cubit.state.favourites, contains('BTCUSDT'));
      await cubit.close();
    });

    test('load takes every row price from the roster', () async {
      final WatchlistCubit cubit = WatchlistCubit(
        storage: _FakeWatchlistStorage(),
        summaries: _FakeSummaries(),
      );

      await cubit.load();

      expect(_entry(cubit, 'BTCUSDT').price, Money.parse('67421.35'));
      expect(_entry(cubit, 'ETHUSDT').price, Money.parse('2500.00'));
      expect(_entry(cubit, 'SOLUSDT').price, Money.parse('142.10'));
      expect(_entry(cubit, 'ETHUSDT').changeBasisPoints, -12);
      await cubit.close();
    });

    test('a poll folds the roster prices back into every row', () async {
      final _FakeSummaries summaries = _FakeSummaries();
      final WatchlistCubit cubit = WatchlistCubit(
        storage: _FakeWatchlistStorage(),
        summaries: summaries,
      );
      await cubit.load();
      final int callsBefore = summaries.marketCalls;

      summaries.markets = <MarketInfo>[
        _market(
          symbol: 'BTCUSDT',
          display: 'BTC/USDT',
          name: 'Bitcoin',
          glyph: 'B',
          lastPrice: '67500.00',
          changeBasisPoints: 30,
        ),
        _market(
          symbol: 'ETHUSDT',
          display: 'ETH/USDT',
          name: 'Ethereum',
          glyph: 'E',
          lastPrice: '2600.00',
          changeBasisPoints: 400,
        ),
        _market(
          symbol: 'SOLUSDT',
          display: 'SOL/USDT',
          name: 'Solana',
          glyph: 'S',
          lastPrice: '142.10',
          changeBasisPoints: 5,
        ),
      ];

      await cubit.refreshPrices();

      expect(summaries.marketCalls, callsBefore + 1);
      expect(_entry(cubit, 'BTCUSDT').price, Money.parse('67500.00'));
      expect(_entry(cubit, 'BTCUSDT').changeBasisPoints, 30);
      expect(_entry(cubit, 'ETHUSDT').price, Money.parse('2600.00'));
      expect(_entry(cubit, 'ETHUSDT').changeBasisPoints, 400);
      // A row whose roster value did not move keeps its value.
      expect(_entry(cubit, 'SOLUSDT').price, Money.parse('142.10'));
      await cubit.close();
    });

    test('a failed poll leaves the last known prices in place', () async {
      final _FakeSummaries summaries = _FakeSummaries();
      final WatchlistCubit cubit = WatchlistCubit(
        storage: _FakeWatchlistStorage(),
        summaries: summaries,
      );
      await cubit.load();
      final WatchlistEntry before = _entry(cubit, 'ETHUSDT');

      summaries.failMarkets = true;
      await cubit.refreshPrices();

      // An unavailable read never invents a movement: the row is untouched.
      expect(_entry(cubit, 'ETHUSDT'), before);
      await cubit.close();
    });

    test('a poll already in flight absorbs the next one', () async {
      final _FakeSummaries summaries = _FakeSummaries();
      final WatchlistCubit cubit = WatchlistCubit(
        storage: _FakeWatchlistStorage(),
        summaries: summaries,
      );
      await cubit.load();
      final int callsBefore = summaries.marketCalls;

      // Both calls start before either read completes; only one may reach the
      // repository.
      await Future.wait(<Future<void>>[
        cubit.refreshPrices(),
        cubit.refreshPrices(),
      ]);

      expect(summaries.marketCalls, callsBefore + 1);
      await cubit.close();
    });

    test('a reorder updates the state immediately and persists it', () async {
      final _FakeWatchlistStorage storage = _FakeWatchlistStorage();
      final WatchlistCubit cubit = WatchlistCubit(
        storage: storage,
        summaries: _FakeSummaries(),
      );
      await cubit.load();

      await cubit.reorder(0, 2);

      expect(_symbolsOf(cubit.state), <String>[
        'ETHUSDT',
        'BTCUSDT',
        'SOLUSDT',
      ]);
      expect(storage.order, <String>['ETHUSDT', 'BTCUSDT', 'SOLUSDT']);
      expect(storage.saveOrderCalls, 1);
      expect(cubit.state.failure, isNull);
      await cubit.close();
    });

    test(
      'a failing store rolls the order back and surfaces the error',
      () async {
        final _FakeWatchlistStorage storage = _FakeWatchlistStorage();
        final WatchlistCubit cubit = WatchlistCubit(
          storage: storage,
          summaries: _FakeSummaries(),
        );
        await cubit.load();
        await cubit.reorder(0, 2);
        final List<String> persisted = _symbolsOf(cubit.state);

        storage.failWrites = true;
        await cubit.reorder(0, 2);

        expect(
          _symbolsOf(cubit.state),
          persisted,
          reason: 'the previous order is restored when the write fails',
        );
        expect(cubit.state.failure, isNotNull);
        expect(storage.order, persisted);
        await cubit.close();
      },
    );

    test('a reorder to the same position is a no-op', () async {
      final _FakeWatchlistStorage storage = _FakeWatchlistStorage();
      final WatchlistCubit cubit = WatchlistCubit(
        storage: storage,
        summaries: _FakeSummaries(),
      );
      await cubit.load();

      await cubit.reorder(1, 1);
      expect(storage.saveOrderCalls, 0);
      await cubit.close();
    });

    test('remove and undoRemove round-trip the order', () async {
      final _FakeWatchlistStorage storage = _FakeWatchlistStorage();
      final WatchlistCubit cubit = WatchlistCubit(
        storage: storage,
        summaries: _FakeSummaries(),
      );
      await cubit.load();
      final List<String> before = _symbolsOf(cubit.state);

      await cubit.remove('ETHUSDT');
      expect(_symbolsOf(cubit.state), <String>['BTCUSDT', 'SOLUSDT']);

      await cubit.undoRemove();
      expect(_symbolsOf(cubit.state), before);
      await cubit.close();
    });

    test('a failing remove does not lose the row', () async {
      final _FakeWatchlistStorage storage = _FakeWatchlistStorage();
      final WatchlistCubit cubit = WatchlistCubit(
        storage: storage,
        summaries: _FakeSummaries(),
      );
      await cubit.load();
      final List<String> before = _symbolsOf(cubit.state);

      storage.failWrites = true;
      await cubit.remove('ETHUSDT');

      expect(_symbolsOf(cubit.state), before);
      expect(cubit.state.failure, isNotNull);
      await cubit.close();
    });

    test(
      'toggling a favourite persists and is reflected in the state',
      () async {
        final _FakeWatchlistStorage storage = _FakeWatchlistStorage();
        final WatchlistCubit cubit = WatchlistCubit(
          storage: storage,
          summaries: _FakeSummaries(),
        );
        await cubit.load();

        await cubit.toggleFavourite('ETHUSDT');
        expect(cubit.state.favourites, contains('ETHUSDT'));
        expect(storage.favourites, contains('ETHUSDT'));
        expect(_entry(cubit, 'ETHUSDT').isFavourite, isTrue);

        await cubit.toggleFavourite('ETHUSDT');
        expect(cubit.state.favourites, isNot(contains('ETHUSDT')));
        expect(_entry(cubit, 'ETHUSDT').isFavourite, isFalse);
        await cubit.close();
      },
    );

    test('pin promotes a row and persists the pin', () async {
      final _FakeWatchlistStorage storage = _FakeWatchlistStorage();
      final WatchlistCubit cubit = WatchlistCubit(
        storage: storage,
        summaries: _FakeSummaries(),
      );
      await cubit.load();

      await cubit.pin('SOLUSDT');
      expect(cubit.state.pinnedSymbol, 'SOLUSDT');
      expect(storage.pinned, 'SOLUSDT');
      expect(
        cubit.state.entries.first.symbol,
        'SOLUSDT',
        reason: 'pinning to the top has to move the row, not only mark it',
      );
      expect(
        storage.order.first,
        'SOLUSDT',
        reason: 'the promoted order is what survives a restart',
      );
      expect(
        cubit.state.entries
            .firstWhere((WatchlistEntry e) => e.symbol == 'SOLUSDT')
            .isPinned,
        isTrue,
      );

      await cubit.unpin();
      expect(cubit.state.pinnedSymbol, isNull);
      expect(
        cubit.state.entries.first.symbol,
        'SOLUSDT',
        reason: 'unpinning clears the mark, it does not undo the move',
      );
      await cubit.close();
    });

    test(
      'the filter narrows the visible entries without losing the order',
      () async {
        final _FakeWatchlistStorage storage = _FakeWatchlistStorage();
        final WatchlistCubit cubit = WatchlistCubit(
          storage: storage,
          summaries: _FakeSummaries(),
        );
        await cubit.load();

        cubit.setFilter(WatchlistFilter.favourites);
        expect(
          <String>[
            for (final WatchlistEntry entry in cubit.state.visibleEntries)
              entry.symbol,
          ],
          <String>['BTCUSDT'],
        );
        expect(cubit.state.entries.length, 3);

        cubit.setFilter(WatchlistFilter.all);
        expect(cubit.state.visibleEntries.length, 3);
        await cubit.close();
      },
    );
  });
}
