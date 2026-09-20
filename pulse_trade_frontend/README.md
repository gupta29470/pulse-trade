# PulseTrade Frontend

The Flutter client for the PulseTrade market feed. It renders every market the Go
backend simulates — each with its own live trades, order book, candles and 24h
summary — over REST and WebSocket, keeps rendering cached values while the
network is gone, and builds for Android only.

## Layout

```text
lib/
├── core/      connectivity, networking, cache, storage, clock, logging, telemetry
├── domain/    entities, order-book synchronizer, candle merger, calculators, repository interfaces
├── data/      DTOs and their generated codecs, mappers, repository implementations
├── app/       theme tokens, shared widgets, router, composition root
└── features/  one folder per bounded concern: connection, market, orderbook, watchlist,
               adaptive delivery, diagnostics, debug
```

Dependencies point inward. `domain` imports nothing internal, nothing under
`features/` or `domain/` reaches `dio` or the socket directly, and `fl_chart`
only draws data the app already owns; `test/architecture/import_boundary_test.dart`
reads the imports and enforces all three.

## Run it

```bash
flutter pub get
flutter run
```

The gateway is compiled into the build. The default is the host's LAN address, so
a fresh install on a physical device connects with no configuration. An emulator
build overrides it:

```bash
flutter run --dart-define=PULSETRADE_GATEWAY=http://10.0.2.2:8080
```

## Test it

```bash
dart format --set-exit-if-changed lib test
flutter analyze
flutter test
```

Tests run offline: no case needs a network, and the fixtures under `../fixtures/`
are the same ones the backend tests read, so both sides are checked against one
set of numbers.

## Notes

- Wire DTOs are generated from `data/dto/*.dart`. After changing one, run
  `dart run build_runner build --delete-conflicting-outputs`.
- The bottom bar has two destinations, Market and Watchlist. Diagnostics and the
  debug console are full-screen routes; the debug console is compiled out of
  release builds.
- Deep links are routed by the app itself: `pulsetrade://market/BTCUSDT` and
  `pulsetrade://watchlist`. Android forwards the intent over a `pulsetrade/deeplink`
  channel, and the Flutter engine's own deep linking is switched off so the two
  mechanisms cannot disagree.
