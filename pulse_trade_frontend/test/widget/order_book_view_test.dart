import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/app/theme/app_theme.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/local_order_book.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/entities/top_of_book.dart';
import 'package:pulse_trade_frontend/domain/orderbook/order_book_synchronizer.dart';
import 'package:pulse_trade_frontend/features/orderbook/order_book_state.dart';
import 'package:pulse_trade_frontend/features/orderbook/widgets/order_book_view.dart';

/// Builds a book with [levels] per side, each side stepping 1.00 away from the
/// touch, and projects the best [depth] levels exactly as the bloc does.
TopOfBook _bookOf({required int levels, int depth = 10}) {
  final LocalOrderBook book = LocalOrderBook(
    symbol: 'BTCUSDT',
    epoch: 1,
    appliedUpdateId: 0,
  );

  final List<OrderBookLevel> bids = <OrderBookLevel>[];
  for (var i = 0; i < levels; i++) {
    bids.add(
      OrderBookLevel(
        price: Money.parse(_format(6742090 - i * 100)),
        quantity: Quantity.parse('0.${(100 + i).toString().padLeft(8, '0')}'),
      ),
    );
  }
  final List<OrderBookLevel> asks = <OrderBookLevel>[];
  for (var i = 0; i < levels; i++) {
    asks.add(
      OrderBookLevel(
        price: Money.parse(_format(6742110 + i * 100)),
        quantity: Quantity.parse('0.${(200 + i).toString().padLeft(8, '0')}'),
      ),
    );
  }

  book.applyLevels(bids, isBid: true);
  book.applyLevels(asks, isBid: false);
  return book.top(depth);
}

/// Renders a scaled integer as an exact decimal string with two digits.
String _format(int scaled) => Money.fromScaled(scaled, 100).format();

OrderBookStateModel _state(
  TopOfBook top, {
  OrderBookState syncState = OrderBookState.live,
  DataProvenance provenance = DataProvenance.live,
  DateTime? asOf,
}) {
  return OrderBookStateModel(
    syncState: syncState,
    top: top,
    epoch: 1,
    appliedUpdateId: 10431,
    lastAppliedFirstUpdateId: 10429,
    lastAppliedLastUpdateId: 10431,
    provenance: provenance,
    asOf: asOf,
    recoveryCount: 1,
  );
}

Future<void> _pump(WidgetTester tester, OrderBookStateModel state) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: 420, child: OrderBookView(state: state)),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('OrderBookView', () {
    testWidgets('renders exactly 10 rows per side from a deeper book', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _state(_bookOf(levels: 12)));

      // The best levels are on screen, each shown twice by design: the status
      // line's bid/ask badge and the first ladder row.
      expect(find.text('67420.90'), findsWidgets);
      expect(find.text('67421.10'), findsWidgets);
      // The tenth level of each side is on screen exactly once.
      expect(find.text('67411.90'), findsOneWidget);
      expect(find.text('67430.10'), findsOneWidget);

      // ...and the 11th and 12th levels of either side are not.
      expect(find.text('67410.90'), findsNothing);
      expect(find.text('67409.90'), findsNothing);
      expect(find.text('67431.10'), findsNothing);
      expect(find.text('67432.10'), findsNothing);
    });

    testWidgets('shows the best bid and ask with the exact spread', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _state(_bookOf(levels: 12)));

      // The column headers and the badges both carry these labels.
      expect(find.text('BEST BID'), findsWidgets);
      expect(find.text('BEST ASK'), findsWidgets);
      expect(find.textContaining('SPREAD'), findsOneWidget);
      expect(find.textContaining('0.20'), findsWidgets);
    });

    testWidgets('a shallow book still fills ten rows per side', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _state(_bookOf(levels: 3)));

      expect(find.text('67420.90'), findsWidgets);
      expect(find.text('67421.10'), findsWidgets);
      expect(find.text('67423.10'), findsOneWidget);
      // Nothing was invented to pad the missing levels.
      expect(find.text('67424.10'), findsNothing);
    });

    testWidgets(
      'an empty syncing book shows the waiting state, not fake rows',
      (WidgetTester tester) async {
        await _pump(
          tester,
          _state(
            const TopOfBook(
              bids: <OrderBookLevel>[],
              asks: <OrderBookLevel>[],
              bidCumulative: <Quantity>[],
              askCumulative: <Quantity>[],
            ),
            syncState: OrderBookState.syncing,
          ),
        );

        expect(find.textContaining('Waiting for order book'), findsOneWidget);
      },
    );

    testWidgets(
      'a stale book is labelled STALE or CACHED, never silently live',
      (WidgetTester tester) async {
        await _pump(
          tester,
          _state(
            _bookOf(levels: 12),
            syncState: OrderBookState.stale,
            provenance: DataProvenance.stale,
            asOf: DateTime.utc(2026, 9, 17, 12, 41, 3),
          ),
        );

        expect(find.textContaining('STALE'), findsWidgets);
      },
    );

    testWidgets('a steady book carries no warning tag', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _state(_bookOf(levels: 12)));

      expect(find.textContaining('STALE'), findsNothing);
      expect(find.textContaining('SYNCING'), findsNothing);
    });

    testWidgets('the layout survives a 1.3 text scale', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: 420,
                  child: OrderBookView(state: _state(_bookOf(levels: 12))),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
