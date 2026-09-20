# PulseTrade — Real-Time Crypto Market Data App

A production-shaped Android market-data client for one simulated cryptocurrency market, and the Go backend that generates, owns and adapts that market.

The problem is not "draw a live chart". It is: **adapt how often each connection receives chart updates to that connection's measured network quality, without ever changing what the market actually did.** Everything below exists to make that claim true, observable and testable.

```text
Synthetic market generator  →  Canonical market engine  →  Per-connection adaptive delivery  →  Flutter
   (deterministic)              (one source of truth)        (FULL / DEGRADED / MINIMAL)          (renders)
```

---

## Contents

- [Quick start](#quick-start)
- [What it does](#what-it-does)
- [Architecture](#architecture)
  - [Why BLoC, and why several BLoCs](#why-bloc-and-why-several-blocs)
  - [Why repositories](#why-repositories)
  - [How market state flows](#how-market-state-flows)
  - [Why the Go engine is separate from per-client delivery](#why-the-go-engine-is-separate-from-per-client-delivery)
- [Protocol](#protocol)
  - [REST endpoints](#rest-endpoints)
  - [WebSocket messages](#websocket-messages)
  - [Sequence semantics](#sequence-semantics)
  - [Candle semantics](#candle-semantics)
- [Order-book synchronization](#order-book-synchronization)
- [Candles](#candles)
- [Adaptive delivery](#adaptive-delivery)
- [Metrics, logging and diagnostics](#metrics-logging-and-diagnostics)
- [Caching, offline behaviour and lifecycle](#caching-offline-behaviour-and-lifecycle)
- [Debug controls](#debug-controls)
- [Precision and time](#precision-and-time)
- [Testing](#testing)
- [Packages](#packages)
- [Repository layout](#repository-layout)
- [Deployment (optional)](#deployment-optional)
- [Known limitations](#known-limitations)
- [Where the rest is documented](#where-the-rest-is-documented)

---

## Quick start

**Backend** (one command; no exchange account, no API key, no internet access required):

```bash
cd pulse_trade_backend
go run ./cmd/server
```

The server listens on `http://0.0.0.0:8080` and `/ws`, builds candle history for every market from a compressed deterministic replay (about four seconds, all markets warmed concurrently), then trades them live. Verify without the app:

```bash
curl -s localhost:8080/health | jq
curl -s "localhost:8080/api/v1/markets/BTCUSDT/candles?interval=1m&limit=5" | jq
curl -s localhost:8080/api/v1/markets/BTCUSDT/orderbook | jq '.bids[0:3]'
curl -s localhost:8080/api/v1/metrics/summary | jq
```

**App**, pointed at the backend you just started (Android emulator already booted):

```bash
cd pulse_trade_frontend
dart run build_runner build    # first checkout only: generates the wire codecs
flutter run --dart-define=PULSETRADE_GATEWAY=http://10.0.2.2:8080
```

`flutter run` with no flag talks to the deployed instance instead — that is what a shipped build does, and it needs no backend of your own. The table below lists both addresses.

| Environment | REST | WebSocket |
|---|---|---|
| Hosted — the shipped default | `https://pulse-trade-backend.onrender.com` | `wss://pulse-trade-backend.onrender.com/ws` |
| A backend on your own machine | `http://<your-lan-address>:8080` | `ws://<your-lan-address>:8080/ws` |

**A build with no `--dart-define` connects to the deployed backend**, so a fresh install works with no configuration. To run against a backend on your own machine, pass the address that reaches that machine: `http://10.0.2.2:8080` for an **emulator**, or the machine's LAN address for a **physical device**. To tunnel over USB instead, `adb reverse tcp:8080 tcp:8080` and use `http://localhost:8080` (re-run it after each reconnect — the rule is tied to the adb transport). `10.0.2.2` is the emulator's alias for the host loopback interface. Cleartext HTTP/WS is a **local development transport**; the hosted instance is HTTPS/WSS.

`make help` lists every convenience target. Nothing is built or tested by a pipeline — there is no CI/CD, and every command in this README runs on your machine. Keeping the optional deployed instance awake is a manual step too: `make ping`, which [Deployment](#deployment-optional) explains.

---

## What it does

- Generates a deterministic synthetic trade stream per market from one seed, so a session, a bug and a demonstration are all reproducible.
- Derives a canonical 100-level order book, trade-derived OHLCV candles for six intervals, a rolling 24-hour summary and a recent-trade tape for each of the six markets.
- Fans the same canonical state out to every connection, each at its own delivery tier, decided from that connection's own measured latency and jitter.
- Measures RTT and jitter in the app, reports them, and shows the resulting tier, override state and **actual** delivered rate.
- Builds the app's order book from a REST snapshot plus ordered deltas, detects a missing or out-of-order update, requests a fresh snapshot and resumes.
- Persists **every latency sample** and every operational metric to SQLite, and exposes them through a query API.
- Never fabricates data: when the feed stops, values stay on screen and are labelled with their age.

---

## Architecture

```text
pulse_trade_backend/
  cmd/server/                 wiring only: config → logger → metrics → provider → engine → delivery → transport
  internal/domain/            fixed-point money, symbols, intervals, errors, clock (stdlib only)
  internal/exchange/          the upstream boundary
    synthetic/                the running market: seeded price process + book ladder
    replay/                   fixture replay for tests and controlled demos
    faultinject/              decorator: gaps, duplicates, reordering, delay
  internal/market/            canonical engine (one per market) plus their registry: book, candles, 24h summary, trade tape, event bus
  internal/delivery/          sessions, tier machine, coalescing, scheduling, backpressure
  internal/protocol/          wire types, validation, error codes
  internal/metrics/           non-blocking recorder, SQLite store, query API
  internal/observability/     JSON logging, counters, telemetry payload types
  internal/transport/         HTTP handlers + WebSocket handler/loops

pulse_trade_frontend/
  lib/core/                   connectivity, networking, cache, storage, clock, logging, routing, errors
  lib/domain/                 entities, synchronizers, mergers, calculators, repository interfaces
  lib/features/               one folder per bounded concern: connection, market, orderbook, watchlist, adaptive delivery, diagnostics, debug
  lib/app/                    theme tokens, shared widgets, bootstrap (composition root)
```

Dependencies point inward and the rule is enforced by tooling, not convention: `domain` imports nothing internal, `market` cannot import `delivery`, and the metrics store is reached through a narrow interface each consumer declares itself.

### Why BLoC, and why several BLoCs

Market data is several independent streams with event-driven transitions, and the delivery tier changes how often each one ticks. One state object would rebuild the whole screen ten times a second; one god-bloc would also make the hard logic — order-book sequencing, interval races, tier response — impossible to test in isolation.

So there are seven bounded units, each with one reason to change:

| Unit | Owns | Never does |
|---|---|---|
| `ConnectionBloc` | socket lifecycle, reconnect backoff, heartbeat schedule, stale state | parse market payloads, decide a tier |
| `OrderBookBloc` | snapshot sync, delta application, sequencing, recovery, top-of-book projection | touch the candle list |
| `MarketBloc` | selected interval, history load, candle merge, active candle, trades, summary | touch the order book |
| `AdaptiveDeliveryCubit` | presentation of the backend's tier, override and rates | decide the tier |
| `WatchlistCubit` | ordering, favourites, persistence, optimistic reorder + rollback | call the network |
| `DiagnosticsCubit` | polled metrics, connection layers, counters | render market data |
| `DebugConsoleCubit` | generator and fault controls used to demonstrate the tiers | exist in a release build |

The split also makes the required tests trivial to write: `OrderBookSynchronizer` is a pure state machine with an injected clock, so the buffered-delta and gap-recovery tests need no socket, no widget tree and no timers.

### Why repositories

Widgets and blocs depend on domain interfaces (`MarketHistoryRepository`, `OrderBookRepository`, `MarketStreamRepository`, `MarketSummaryRepository`, `MetricsRepository`, `WatchlistStorage`), never on `dio`, `web_socket_channel` or `shared_preferences`. That is what allows:

- the offline decorator to wrap the API without any bloc knowing;
- the cache layer to sit behind the same interface;
- every test to substitute a fake with the same contract — `FakeMarketApi` and `MemoryCacheStore` are not test tricks, they are the same interfaces the app runs on.

Four narrow repositories rather than one `TradingRepository`, so a bloc depends only on what it calls.

### How market state flows

```text
generator tick (one goroutine per market, the only writer of that market's state)
  ├─ canonical book mutation            → one new update id
  ├─ every candle aggregator folds the trade        (no tier is reachable from here)
  ├─ rolling 24h summary, recent-trade ring
  └─ event bus publish
        └─ per-session mailbox (never blocks the engine)
              └─ session delivery loop: coalesce → flush at the tier rate → single socket writer
                    └─ Flutter: parse → synchronize/merge → bloc state → one widget rebuild
```

The engine never learns how many clients exist, and no client can influence canonical state.

### Why the Go engine is separate from per-client delivery

Because they answer different questions. "What did the market do?" has exactly one answer per trade, computed once. "How often should this phone hear about it?" has a different answer per connection and changes as the network changes.

Keeping them apart is what makes the central guarantee provable rather than hopeful:

- `CandleAggregator.Apply(trade)` takes **only a trade**. There is no parameter through which a tier could influence it, so tier-independence is a property of the type, not a promise in a comment.
- Sessions hold their own tier, pending state and scheduler; the engine holds none of that.
- Metrics and logging are observers. Nothing in the delivery path can change what the market did.

---

## Protocol

### REST endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness |
| `GET` | `/api/v1/health` | Engine state, epoch, update id, warmup, metrics-store health, session counts |
| `GET` | `/api/v1/markets` | Market registry: every market with its live last price and 24h change |
| `GET` | `/api/v1/markets/{symbol}/summary` | Rolling 24h open/high/low/volume/change |
| `GET` | `/api/v1/markets/{symbol}/orderbook` | Order-book snapshot |
| `GET` | `/api/v1/markets/{symbol}/candles?interval=1m&limit=500` | Candle history, ascending |
| `GET` | `/api/v1/markets/{symbol}/trades?limit=50` | Recent trades, newest first |
| `GET` | `/api/v1/metrics/summary` | Counters, tier distribution, RTT percentiles |
| `GET` | `/api/v1/metrics/latency?sessionId=&from=&to=&bucket=5s` | Bucketed RTT/jitter series |
| `GET` | `/api/v1/metrics/tiers?from=&to=` | Tier transitions with reasons |
| `GET` | `/api/v1/metrics/sessions?limit=50` | Session lifecycle records |
| `GET` | `/api/v1/metrics/delivery?sessionId=` | Delivered vs target rate, coalescing |
| `WS` | `/ws` | Application socket |

Errors are uniform: `{"error":{"code":"UNSUPPORTED_INTERVAL","message":"…","correlationId":"01J…"}}`. Status codes: `400` invalid input, `404` unknown symbol/route, `405` wrong method, `500` internal, `504` timeout. Debug routes are registered **only** when `DEBUG_BUILD=true` and `ENABLE_DEBUG_CONTROLS=true`, so a release binary has no debug surface at all rather than a disabled one.

### WebSocket messages

Every server frame uses one envelope:

```json
{"type":"candle_update","version":1,"serverTime":"2026-09-17T12:41:03.240Z","seq":1839202,"payload":{ }}
```

| Direction | Type | Payload |
|---|---|---|
| → | `welcome` | session ids, symbol, epoch, engine state, intervals, channels, tier rates and thresholds |
| → | `subscribed` / `unsubscribed` | accepted subscription |
| → | `pong` | `{id, clientTimeMs, serverTimeMs}` |
| → | `ping` | the server's idle keepalive, every 30 s; it needs no reply |
| → | `market_status` | `{state, epoch, message, at}` |
| → | `order_book_snapshot` | `{symbol, epoch, updateId, bids[[price,qty]], asks[[…]], serverTime}` |
| → | `order_book_delta` | `{symbol, epoch, firstUpdateId, lastUpdateId, bids, asks}` |
| → | `trade` / `trade_batch` | one trade, or a compacted batch with `omittedCount` |
| → | `candle_update` | the complete active candle (not a diff) |
| → | `candle_closed` | the final candle; never coalesced |
| → | `market_summary` | 24h values, 1 Hz |
| → | `health` | tier, override, reason, target and effective rate, RTT, jitter, sequence |
| → | `error` | `{code, message, fatal, requestId}` |
| ← | `hello`, `subscribe`, `unsubscribe`, `set_interval` | session setup. `subscribe` binds the session to the market it names, so opening another market reuses one socket instead of reconnecting |
| ← | `ping`, `latency_report` | RTT measurement and health reporting |
| ← | `tier_override` | debug override of the delivery tier |

Client frames carry their fields inline (no payload wrapper). Client frames are validated: size limit 16 KiB, at most 20 messages per second, unknown types and malformed JSON answered with a typed non-fatal error so one bad frame never tears down a healthy socket. Prices and quantities always travel as decimal **strings**.

### Sequence semantics

Three independent ordering domains, deliberately never overloaded:

| Counter | Scope | Meaning | Client reaction |
|---|---|---|---|
| `tradeId` | trades | execution ordering | ignore and count if `<= lastTradeId` |
| `updateId` | order book | one per book **state transition** | recover on a gap |
| `seq` | one socket | outbound frame ordering | diagnostics only |

An `updateId` covers a whole transition, not a level: a churn cycle touching five levels is one update id. That is what lets a delta declare a range and a client still prove continuity.

### Candle semantics

`candle_update` carries the complete candle rather than a diff, because a client that misses an intermediate message must still end up correct. `candle_closed` carries the final bucket. History and the active candle are separate: only closed candles are immutable, and a late trade for a closed bucket is counted and logged rather than rewriting history — that is what keeps cross-tier equality provable.

---

## Order-book synchronization

Two independent snapshot-plus-delta problems exist, and both use the same rules:

```text
exchange provider ──▶ Go engine        (bootstrap snapshot, then provider deltas)
Go engine         ──▶ Flutter          (REST snapshot, then ordered WS deltas)
```

**Snapshot protocol.** The snapshot carries `epoch`, `updateId` and 15 levels per side (the client displays 10, and the extra headroom is what keeps the displayed 10 correct while levels churn at the edge of the window).

**Delta protocol.** A delta declares the range it covers: `firstUpdateId`…`lastUpdateId`, with absolute quantities where `0` means delete.

**Why ranges rather than strict `+1`.** Per-tier throttling means a throttled client receives fewer book messages than the engine produces updates. With strict `+1` sequencing, any coalescing would look like a gap and trigger a pointless resynchronisation. With a declared range, the client applies a message when `firstUpdateId <= applied + 1 <= lastUpdateId` and can still detect a genuine gap. Coalescing therefore changes frequency, never provability.

**Buffering during the snapshot.** Deltas are buffered while the REST snapshot is in flight (bounded at 1000 ranges). When the snapshot arrives the buffer is drained in order; a range that ends at or before the snapshot's sequence is discarded as stale, and a range that starts beyond `applied + 1` is a gap.

**Gap detection and recovery.**

```text
applied = 10430, delta arrives for 10432
  → state = RECOVERING, the delta is NOT applied
  → request a fresh snapshot
  → snapshot at 10431: apply it, then the buffered 10432
  → resume LIVE at 10432
```

If a second gap occurs while recovering, the obsolete buffer is discarded and synchronisation restarts from the newest snapshot. After three failed attempts the book enters a terminal `error` state with a retry affordance, because pretending to be live is worse than admitting the feed is broken.

**Deletions.** The engine publishes the *whole* window each time and the session diffs it against what the client was last told. A level the client holds but the engine no longer publishes in the window is sent with quantity `0`. That is why the client's tenth level is never a price that no longer exists.

**Never silently drop a delta.** If a session cannot accept a book delta, it is resynchronised with a fresh snapshot rather than having the delta dropped. Chart updates may be coalesced away; book deltas may be coalesced but never lost.

---

## Candles

**History.** `GET /api/v1/markets/BTCUSDT/candles?interval=1m&limit=500`. Candle history is **trade-derived** — the engine aggregates it from the same trade stream that feeds live trading, using the same code path. At startup a compressed deterministic replay (default 200 000 events over 30 virtual days) fills the aggregators, so there is no seam between "history" and "live".

**Active candle.** `candle_update` replaces the active candle by its `(interval, startTime)` identity. Only the active bucket is mutable.

**Interval switching.** The app:

1. marks the chart `refreshing` and **keeps the previous candles rendered**;
2. increments a request generation id and requests history;
3. sends the new subscription;
4. commits the response only if the generation id is still current **and** the response's interval matches the selection;
5. merges any live candle that arrived during the swap by identity.

A late response for the previous interval is dropped and counted. That race is covered by a unit test rather than by hope.

**Duplicates and late data.**

| Case | Action |
|---|---|
| same identity, active candle | replace |
| same identity, newer `sourceSequence` | replace |
| same identity, older `sourceSequence` | ignore, counted |
| newer `startTime` | append, finalise the previous bucket |
| older `startTime` already closed | ignore and log |
| duplicate `tradeId` | collapse, counted |

---

## Adaptive delivery

The backend owns the tier. The app measures and reports; it never decides.

### RTT and jitter

```text
t_send (client monotonic clock) ──▶ ping{id, clientTimeMs}
                                   ◀── pong{id, clientTimeMs, serverTimeMs}
t_recv (client monotonic clock)
RTT_n = t_recv - t_send
```

- Heartbeat every **2 s**; the client-initiated pulse removes any dependence on clock agreement between device and server (the server time is echoed for diagnostics only). A ping without a pong within **4 s** is a missed sample: counted, excluded from the window, and treated as a report gap. The backend announces this cadence in the `welcome` frame, and the app refuses an announced cadence longer than the tier machine's own missing-report window — a slower one could never be honoured without every client being classified as silent. The server's own keepalive `ping` is a separate, slower 30 s cadence that only proves the socket is writable.
- **Jitter** is the mean absolute difference between consecutive RTT samples over a **10-sample** rolling window: `jitter_n = mean(|RTT_i - RTT_{i-1}|)`. The first sample is `0`, fewer than two samples is `0`, and samples above `3 ×` the window median are capped at that value and counted.
- Every completed sample is sent as a `latency_report` and **persisted to the database**, so the tier machine's input is auditable after the fact.

### Thresholds

| Tier | Entry criteria | Target chart rate | Trade delivery |
|---|---|---|---|
| `FULL` | RTT < 150 ms **and** jitter < 50 ms | 10 /s | every trade |
| `DEGRADED` | RTT ≥ 150 ms **or** jitter ≥ 50 ms | 2 /s | 500 ms batches |
| `MINIMAL` | RTT ≥ 500 ms **or** jitter ≥ 150 ms | 0.5 /s | 1 s batches, compacted |

All six numbers are configuration (`TIER_*`), shipped to the client in the `welcome` frame so the app displays the backend's real numbers instead of its own copy.

### Hysteresis

Degrade quickly, recover slowly:

| From | To | Condition |
|---|---|---|
| `FULL` | `DEGRADED` | 3 consecutive reports at degraded-band or worse |
| `DEGRADED` | `MINIMAL` | 3 consecutive minimal-band reports |
| `DEGRADED` | `FULL` | 5 consecutive good reports |
| `MINIMAL` | `DEGRADED` | 5 consecutive reports better than minimal-band |
| `MINIMAL` | `FULL` | **never directly** — recovery passes through `DEGRADED` |

Every transition stores its reason (`GOOD_HEALTH`, `HIGH_RTT`, `HIGH_JITTER`, `MISSING_REPORTS`, `FORCED_OVERRIDE`, `RECOVERY`) with the streak that caused it, so the diagnostics screen can explain *why* rather than only *what*.

### Missing reports

A client that stops reporting is not treated as healthy by default:

| `lastReportAge` | Action |
|---|---|
| < 5 s | keep the current tier |
| 5–10 s | drop exactly one tier |
| > 10 s | `MINIMAL` |
| socket disconnected | no live delivery; reconnect state |

The watchdog is idempotent — re-evaluating the same age never produces a second transition — and it can only degrade. Returning to a better tier still requires the full recovery streak, so a client that flaps its health reports cannot oscillate the server.

### Target rate, effective rate and market availability

These are three different numbers and the README distinguishes them deliberately:

- **Target rate** is the tier's ceiling: 10 / 2 / 0.5 per second.
- **Effective rate** is what was actually delivered over the last five seconds, and is what the app displays.
- **Market event availability** is how many times the market actually changed. RTT, jitter and rate all depend on how many trades and book transitions occurred; when the market is quiet, no tier invents updates.

**No trade is ever manufactured to hit a target rate.** The engine continues to process the complete trade stream at every tier; a slower tier changes how often the chart hears about it.

### Why throttling cannot corrupt a candle

- Aggregation happens in the engine's tick loop, before fan-out, over every generated trade.
- `CandleAggregator.Apply` accepts only a trade; no tier is reachable from it.
- Delivery reads candles, never writes them.
- Closing a bucket publishes `candle_closed`, which is **never coalesced**, because a client that misses it cannot finalise the bucket. If it cannot be delivered the session is resynchronised instead of silently missing it.

`TestCandleFinalsAreIdenticalRegardlessOfDeliveryFrequency` (Go) drives one engine with a full-fidelity observer and a throttled one, asserts both received a **different number** of updates (proving the throttling was real) and that every closed candle is **identical** between them.

---

## Metrics, logging and diagnostics

### Everything is persisted

Every latency sample, health report, tier transition, five-second delivery window, book-sync event, protocol anomaly, engine event, candle close and fault injection is written to SQLite (`modernc.org/sqlite`, no cgo) through a repository interface with `sqlite` and `memory` drivers.

- Producers never touch the database. `Record*` calls are non-blocking sends onto a bounded queue (default 4096) drained by a single writer goroutine that batches 128 records or 250 ms into one transaction.
- Queue overflow drops the newest record and increments `metrics_dropped_total` with a rate-limited WARN. A metric is never worth blocking a client's chart update.
- A failing store degrades `/health` (`metrics.status = degraded`) and never stops the market feed.
- Migrations are embedded SQL applied in a transaction with a checksum; a tampered migration is a fatal startup error rather than a silent re-apply.
- Retention deletes in bounded batches (latency 24 h, events 7 d, sessions 90 d, candle closes indefinitely).

```bash
sqlite3 pulse_trade_backend/data/pulsetrade.db \
  "select round(avg(rtt_ms),2), count(*) from latency_samples;" 
curl -s "localhost:8080/api/v1/metrics/latency?bucket=5s" | jq '.buckets[-3:]'
curl -s localhost:8080/api/v1/metrics/tiers | jq '.transitions[-3:]'
```

### Structured JSON logging

Both sides emit one JSON object per line, with `msg` as a stable slug and all variable data in its own field — no interpolated sentences. Fields are constants (`logfields.go`), so a name cannot drift, and numeric values are numbers so `jq` can aggregate them.

```json
{"time":"2026-09-17T12:41:03.240Z","level":"INFO","msg":"tier_transition","service":"pulsetrade-backend",
 "component":"tier","sessionId":"sess_01J8…","shortId":"a3f9c2","fromTier":"FULL","tier":"DEGRADED",
 "reason":"HIGH_RTT","streak":3,"rttMs":175.2,"jitterMs":19.4}
```

`LOG_LEVEL=debug` adds per-message protocol detail. Levels are used consistently: INFO for lifecycle, WARN for handled anomalies, ERROR for a broken invariant or dependency.

### Diagnostics screen

Everything the reviewer needs is in one place and is populated entirely from real state: the connectivity layers (internet / backend / engine / websocket kept separate), market state with "as of" age, order-book sync state with the last applied range, gap and recovery counts, tier with reason and override, target vs effective rate, RTT/jitter with min/avg/max from the metrics API, cache counters, offline-blocked calls, and `Copy diagnostics JSON`.

---

## Caching, offline behaviour and lifecycle

**Two cache tiers.** `shared_preferences` for small versioned metadata (the watchlist order, favourites and pin, plus the cache's own metadata entries) and a file store for payloads (candles per interval, book snapshot, trades, summary) with an 8 MB cap, LRU eviction and per-key TTLs. Every entry carries `schemaVersion`, `writtenAt` and `ttl`; a version mismatch or a decode failure deletes the entry and reports a miss. Reads never throw — cache is an optimisation, never a correctness dependency.

**There is no connection banner and no blocking offline screen.** Connection state is a compact always-present chip, and each section carries a `CACHED`/`STALE` tag with an "as of" time. The app renders from cache immediately on cold start and always shows something.

**No network call is attempted while the internet is unreachable.** `OfflineGate` is consulted by decorators around the REST client and the WebSocket client, so offline calls return a typed `OfflineFailure` immediately, without a dial or a timeout, and increment `offline_calls_blocked_total`. Reconnect attempts wait for the connectivity stream instead of burning the backoff schedule.

**Connectivity detection** follows the module already used in this codebase: `internet_connection_checker_plus` with a primary and a secondary endpoint, a 10 s poll, a **3 s debounce** on disconnect (Android reports transient drops during handovers) and disconnection events ignored while the app is paused (Android throttles background network access and produces false negatives).

**Lifecycle.** On background: heartbeats stop immediately, the socket is kept for a configurable timeout (default 30 s) and then closed, and the market is marked stale. On resume: reconnect → resubscribe → order-book snapshot sync → interval refresh, and only then `LIVE`. Cached values are never promoted to live — the transition requires fresh data — and at most one socket, one heartbeat timer and one reconnect timer exist at any time.

**Offline behaviour, in one sentence:** the market screen still shows the last known price, chart, book and trades, each labelled with its age, and the only thing that changes is the status chip.

---

## Debug controls

Available in debug builds through the backend debug endpoints and the in-app debug console, which is reached by long-pressing the tier chip on the market screen. A release build leaves it out unless it is built with `--dart-define=PULSETRADE_DEBUG_CONSOLE=true`, which is the flag to use when the APK being demonstrated has to be a release build.

| Control | Endpoint / message | What it demonstrates |
|---|---|---|
| Pause / resume / reset generator | `POST /api/v1/debug/generator/{pause,resume,reset}` (add `?symbol=` to pick a market; the configured default is used otherwise) | frozen market, epoch change and client resynchronisation |
| Volatility burst | `POST /api/v1/debug/generator/burst?seconds=5` | the chart under a fast market |
| Empty history | `POST /api/v1/debug/generator/empty-history?on=true` | the app's empty-history state |
| Force tier | `tier_override` message or `POST /api/v1/debug/sessions/{id}/tier?tier=AUTO\|FULL\|DEGRADED\|MINIMAL` | all three tiers without poor Wi-Fi; `AUTO` hands the decision straight back to the hysteresis machine |
| Drop connection | `POST /api/v1/debug/sessions/{id}/drop` | stale state and recovery |
| **Inject missing delta** | `POST /api/v1/debug/sessions/{id}/faults {"skipBookDeltas":3}` | a real sequence gap: the client detects it, snapshots and resumes |
| Inject duplicate delta | `{"duplicateDelta":true}` | duplicate ranges must be inert |
| Inject out-of-order delta | `{"reverseDeltas":true}` | an older range must be ignored |
| Inject malformed frame | `{"malformedFrames":2}` | protocol-anomaly isolation |
| Latency / jitter injection | `{"writeDelayMs":150,"writeJitterMs":200}` | tier degradation from real measured health |
| Slow consumer | `{"holdWritesMs":6000}` | write-deadline handling and forced recovery |
| List live sessions | `GET /api/v1/debug/sessions` | tier, override, RTT, jitter, message counts |

Faults are injected through the same code paths the app uses, and every injection is recorded in `fault_injections` with a correlation id, so "why did the client resync at 12:41:07" is answerable from the database.

---

## Precision and time

- Prices and quantities are **fixed-point integers** everywhere in market state: every symbol carries its own `PriceScale` (2 decimals on `BTCUSDT`, 3 on `ETHUSDT`, 4 on the cheaper markets) and a `QtyScale` of 1e8. Wire values are decimal strings; parsing a value with more precision than the symbol allows fails with `ErrInexactValue` rather than rounding.
- `MulDiv` uses a 128-bit intermediate and reports overflow instead of wrapping. `double` appears only at the chart-rendering boundary, in one adapter, with a comment saying so.
- All timestamps are UTC. Candle buckets align to UTC boundaries via a single `BucketStart` implementation.
- `updateId`, `tradeId` and `seq` are separate and named distinctly everywhere.
- The generator is deterministic from `GENERATOR_SEED`: the same seed reproduces the same trade sequence, book transitions and closed candles, byte for byte.

---

## Testing

Run everything locally (there is **no CI/CD** — see below):

```bash
make backend-test       # go test ./... -race -count=1        (all caches kept inside the repo)
make frontend-test      # flutter test
make backend-lint       # gofmt + go vet + golangci-lint
make frontend-analyze   # dart format --check + flutter analyze
```

The required tests, and what they actually prove:

| Test | Proves |
|---|---|
| `TestTierMachine_HysteresisTimeline` | three bad reports degrade, four good ones do not recover, the fifth does, and one noisy sample never oscillates |
| `TestTierMachine_MissingReportFallback` | hold < 5 s, one tier at 5–10 s, `MINIMAL` beyond 10 s, idempotent, and a fresh report cannot jump `MINIMAL → FULL` |
| `TestCoalescer_CoalescedRangeEqualsSequentialApplication` | a client receiving one coalesced range ends with exactly the book of a client that received every update — and received fewer messages |
| `TestCoalescer_InjectedGapForcesClientRecovery` | a skipped range is detected, the discontiguous delta is not applied, and recovery is required |
| `TestCoalescer_EmitsDeletionForLevelLeavingWindow` | a level leaving the tracked window is deleted on the client |
| `TestCandleFinalsAreIdenticalRegardlessOfDeliveryFrequency` | closed candles are identical across delivery rates while message counts differ |
| `internal/transport/websocket` integration tests | a real client gets welcome → snapshot → **contiguous** deltas → trades → candles → health; malformed frames are isolated; tiers follow health and override; two sessions are isolated |
| `internal/metrics` tests | every latency sample round-trips exactly, overflow is counted and non-blocking, a failing store degrades without blocking, retention and migrations behave |
| `OrderBookSynchronizer` tests (Dart) | a REST snapshot plus ordered deltas rebuilds the book; a live gap is detected and the discontiguous range is never applied; a fresh snapshot recovers and returns to `LIVE`; duplicate and stale ranges are inert; an epoch mismatch resynchronises; a connection loss freezes the book without clearing it; the delta buffer is bounded |
| `CandleMerger` and `IntervalRequestGuard` tests (Dart) | late history merges by candle identity rather than clobbering live buckets, closed buckets are immutable, and a history response for a superseded interval is discarded |
| `WatchlistCubit`, `MarketBloc`, `ConnectionBloc` tests (Dart) | an optimistic reorder rolls back when the write fails; switching market renders cached data first and resubscribes the new symbol; and a reconnect replays the market in force rather than the one the app started on |

The same tests pin the invariants that are easiest to get wrong: the generator's random source is initialised, the 24-hour ring expires stale buckets, canonical state is mutated only under the write lock, the tier machine sets an effective tier on the watchdog path, the coalescer replaces book windows rather than merging them, the coalescer advances its view of the client only after a message is sent, and the bus closes subscriber channels only once the engine can no longer send on them.

`fixtures/replay/` holds the JSONL trade tape the replay provider reads when `MARKET_PROVIDER=replay`, which is how a deterministic demo is driven. Every test in both suites states its own expectations, and the frontend tests run offline — no test needs a network.

---

## Packages

**Backend (Go 1.27):** `chi` (router), `gorilla/websocket` (transport), `modernc.org/sqlite` (pure-Go metrics store), `testify` (assertions), `log/slog` (JSON logging, stdlib). Everything else is the standard library. No ORM, no DI framework, no decimal library — the fixed-point type is 150 lines and has no allocation on the hot path.

**Frontend (Flutter):** `flutter_bloc` + `equatable` (state), `dio` (REST), `web_socket_channel` (WS), `internet_connection_checker_plus` + `rxdart` (reachability), `go_router` (routing and deep links), `shared_preferences` + `path_provider_android` (persistence and cache), `fl_chart` (candlestick rendering only), `intl`, `collection`, `json_annotation` + `json_serializable` + `build_runner` (wire DTOs), `mocktail` + `bloc_test` (tests).

`path_provider_android` is the Android implementation rather than the umbrella plugin: the umbrella also pulls in the
Apple implementation, whose transitive `objective_c` build hook requires a licensed Xcode at test time. This
deliverable builds Android, and iOS support is a documented extension that adds the Darwin implementation back with no
code change (`core/cache/cache_directory.dart` is the only boundary that touches it).

`fl_chart` renders data the app owns and performs no I/O. There is no WebView, and no code path from the chart package to `dio`, `web_socket_channel` or any repository — asserted by `test/architecture/import_boundary_test.dart`, which reads the imports and also pins the transport seams so no file under `features/` or `domain/` can reach `dio` or the socket directly.

---

## Repository layout

```text
pulse_trade/
├── README.md                     this file
├── Makefile                      convenience targets (not a pipeline)
├── pulse_trade_backend/          Go backend
├── pulse_trade_frontend/         Flutter app
└── fixtures/                     the replay tape for deterministic demos
```

---

## Deployment (optional)

Everything above runs locally, and that is all the exercise needs. A hosted instance is a convenience, so it is documented here rather than assumed.

A hosted service needs three settings: the backend's directory within this monorepo as its root directory, a build command, and the start command `HTTP_ADDR=0.0.0.0:$PORT ./app`. On Render those are `pulse_trade_backend`, `CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o app ./cmd/server`, and the start command above. The start command is what silently breaks a deploy if it is missed — the server reads `HTTP_ADDR`, not the `PORT` variable a host injects, so the injected port has to be passed in. There are no secrets to set: the feed is generated locally.

Two properties of a free instance are worth knowing before relying on one:

- **It sleeps** after roughly fifteen minutes without inbound traffic, and the next request pays the boot. Ping it before a demo — `make ping` calls `/health` and prints the status and the round trip — or point a free uptime monitor at `https://pulse-trade-backend.onrender.com/health` on a five-minute interval, which is the reliable option. This repository deliberately ships no scheduled workflow for it: a cron-driven job is delayed under load and stops being scheduled altogether after a period of inactivity, so an external monitor is the tool for the job. While the app is connected it keeps the service awake by itself, because its heartbeat and watchlist polling are inbound traffic.
- **Install the APK while it is warm.** Android fetches the app-link verification file at install time, and a sleeping instance can time out that fetch — which leaves the host unverified and sends every `https` link to the browser instead of the app. If that happens, wake the service and re-run verification: `adb shell pm verify-app-links --re-verify com.pulsetrade.pulse_trade_frontend`.
- **It warms up fully.** Warmup is budgeted at ten seconds for six markets, and the deployed free instance stays inside it: the service serves the full documented history (500 candles at `1m` and `1h`, ~180 at `4h`, ~31 at `1D`). On a smaller instance `WARMUP_MAX_EVENTS` trades history depth for warmup time.

The address is compiled in, and the default is the deployed service, so a plain build targets it:

```bash
flutter build apk --debug
```

Point a build at a backend on your own machine instead with `--dart-define=PULSETRADE_GATEWAY=http://<host>:8080`. `https` is upgraded to `wss` automatically, so the deployment needs no client change beyond the address.

The long-press that opens the debug console — and with it the forced tier change — exists in debug builds. A release build keeps it when built with the flag, which is how the APK attached to a submission can be a release build and still demonstrate all three tiers:

```bash
flutter build apk --release --dart-define=PULSETRADE_DEBUG_CONSOLE=true
```

The host also answers Android's app-link verification file, so `https://pulse-trade-backend.onrender.com/market/BTCUSDT` opens the app when it is tapped in a chat client — which a `pulsetrade://` link cannot do, because clients do not dispatch an unknown scheme. That only holds for a build whose signing certificate is listed in `internal/transport/http/applinks.go`: a release build signed with a different key has to add its SHA-256 there, or the link stays in the browser.

---

## Known limitations

Listed honestly; each is a deliberate scope decision rather than an oversight. Where a
behaviour is easy to misread — tier thresholds travelling in the `welcome` frame, retention
being three configurable windows, the debug fault endpoints being one JSON-body route — the
doc comment at that seam states the reason.

1. **History depth varies by interval.** Warmup covers 30 virtual days, so `1m`–`1h` supply 500 candles while `4h` supplies ~180 and `1D` ~30. History is trade-derived, and reconstructing years of daily candles from trades is not plausible at any generator rate.
2. **Warmup trade density is lower than live density.** Historical candles are exact for the trades that exist, but intra-bucket granularity is coarser than live. This affects history only, never the live candle.
3. **Closed candles are immutable.** A fault-injected late trade cannot rewrite a closed bucket; it is counted and logged. That is deliberate — it is what makes tier-independence provable — but it means history can differ from a "true" replay under reordering.
4. **Compressed warmup is generated, not recorded.** The 30-day history is produced by the same deterministic generator, so it is internally consistent and reproducible but not a record of a real market (there is no real market in this project).
5. **Six markets cost six warmups.** Cold start warms every market concurrently and takes about four seconds; each market keeps its own generator, engine and event bus, so the cost grows with the roster.
6. **SQLite retention is time-boxed** (latency samples 24 h by default). Longer retention or multi-process access would want Postgres; the repository interface is the seam.
7. **Metrics are best-effort.** A saturated queue drops the newest record. Correctness never depends on them, and drops are counted, but a metric can be lost under extreme load.
8. **Cleartext belongs to local development.** The hosted instance is HTTPS/WSS and the app upgrades `https` to `wss` on its own, so the deployed path is encrypted. A backend on your own machine is served over plain HTTP/WS; the manifest permits cleartext only for loopback addresses, so a physical device pointing at a LAN address may need that address added there.
9. **No authentication.** The data is public and read-only, and the only per-connection limits are message rate and frame size.
10. **Single process, single node.** Sessions live in one process, so a restart disconnects everyone. Scaling out would need a shared bus and sticky sessions.
11. **Chart zoom and pan are bounded by the library**, and the series is windowed to our own 500-candle retention.
12. **Cache is unencrypted and evictable.** It holds only public market data and UI preferences; the 8 MB cap means older interval history can be evicted and refetched.
13. **Offline data can be arbitrarily old.** The app shows the last known values with their true age and does not interpolate, estimate or fabricate movement.
14. **iOS is not built.** The core, domain, data and presentation layers are platform-agnostic and only the `android/` platform folder is configured; an iOS build needs its own platform folder and cache directory implementation behind `core/cache/cache_directory.dart`.
15. **No CI/CD by design.** Nothing is built, tested or deployed by a pipeline, and the repository ships no workflow at all: quality is enforced by the local commands above and by the mandatory test list. Keeping an optional deployed instance awake is a manual step (`make ping`) or an external uptime monitor — see [Deployment](#deployment-optional).
16. **The HTTP surface has no per-IP rate limit and no gzip.** The WebSocket path is limited (message rate, frame size, read limit), while the REST surface has neither a rate limiter nor compression, so no `429 RATE_LIMITED` is produced. Acceptable for a locally-run single-client backend on a trusted LAN; a public deployment needs both added at the transport seam.

---

## Where the rest is documented

| Place | Contents |
|---|---|
| `pulse_trade_backend/README.md` | backend layout, build and test commands, configuration, debug endpoints, querying the metrics database |
| `pulse_trade_frontend/README.md` | frontend layout, run and test commands, the architectural rules the code holds to |
| `pulse_trade_backend/.env.example` | every environment variable with its default |
| doc comments in the source | each package and library states its contract, and each non-obvious decision its reason, at the seam that owns it |
