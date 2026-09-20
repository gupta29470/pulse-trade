# PulseTrade Backend

The market-data authority for PulseTrade: a deterministic synthetic market, a canonical market engine, and a per-connection adaptive delivery layer.

```bash
go run ./cmd/server        # listens on 0.0.0.0:8080, WebSocket on /ws
```

`../README.md` explains the design; this file covers working on the backend itself.

## Layout

```text
cmd/server/                 wiring only — config → logger → metrics → provider → engine → delivery → transport
internal/domain/            fixed-point money, symbols, interval registry, errors, Clock (stdlib only)
internal/exchange/          the upstream boundary
  synthetic/                the running market: seeded price process + book ladder + pacing
  replay/                   JSONL fixture replay, for tests and controlled demos
  faultinject/              decorator adding gaps, duplicates, reordering and delay
internal/market/            canonical engine: OrderBook, CandleAggregator, Summary24h, TradeRing, Bus, Engine
internal/delivery/          Session, Manager, TierMachine, Policy, HealthTracker, Coalescer
internal/protocol/          wire types, validation, error-code vocabulary
internal/metrics/           non-blocking Recorder, driver registry, memory + sqlite repositories
internal/observability/     JSON logger, counters/gauges, telemetry payload types, log field constants
internal/transport/         HTTP handlers and middleware, WebSocket handler + Conn adapter
internal/config/            environment parsing and validation
internal/testutil/          fakes used by tests
```

Dependencies point inward. `depguard` in `.golangci.yml` enforces it: `domain` imports nothing internal, `market` may not import `delivery`, and the metrics store is reached only through interfaces each consumer declares.

## Build and test

Go's build and module caches are kept **inside the module** so the toolchain works in sandboxed environments and after one download:

```bash
export GOCACHE="$PWD/.cache/go-build"
export GOMODCACHE="$PWD/.cache/gomod"
export GOPATH="$PWD/.cache/gopath"          # keeps the checksum database local too

go build ./...
go vet ./...
go test ./... -race -count=1
gofmt -l .                                   # must print nothing
```

Equivalently from the repository root: `make backend-run`, `make backend-test`, `make backend-lint`.

## Configuration

`.env.example` is the contract, and a test asserts its key set matches `config.go` exactly so the documentation cannot drift. Every value is validated at startup and **all** problems are reported together rather than one per restart. `DEBUG_BUILD=false` forces `ENABLE_DEBUG_CONTROLS` off, so a release binary has no debug surface at all.

The metrics database defaults to `./data/pulsetrade.db` (created if missing) and is pruned on a timer. `make reset-data` deletes it.

## What to know before changing things

- **One writer of canonical state.** Only the engine tick loop mutates the book, candles, summary and trade ring, under the engine lock. Readers copy under the read lock and never hold it across I/O.
- **`CandleAggregator.Apply` takes only a trade.** Do not add a parameter that could carry delivery information; tier independence depends on that signature staying narrow.
- **An update id covers a state transition, not a level.** A churn cycle touching several levels is one update id, which is what makes the delta range meaningful.
- **The engine window is authoritative and is replaced, not merged.** `Coalescer.OnBookWindow` must receive the complete published window; deletions are derived by diffing it against what the client holds.
- **Never close a subscriber's channel.** `Bus.Unsubscribe` closes `Done` instead, because the engine may be mid-publish from its own goroutine and a send on a closed channel panics.
- **Book deltas are never dropped.** If a session cannot accept one, it is resynchronised from a fresh snapshot.
- **Nothing on the hot path touches the database.** `Record*` calls are non-blocking sends onto a bounded queue; overflow drops the newest record and increments a counter.
- **Logging is structured.** `msg` is a slug from `logfields.go`; all variable data goes in its own field. Never interpolate values into a message.

## Debug endpoints

Registered only when `DEBUG_BUILD=true` and `ENABLE_DEBUG_CONTROLS=true`:

```bash
curl -X POST localhost:8080/api/v1/debug/generator/pause
curl -X POST localhost:8080/api/v1/debug/generator/resume
curl -X POST localhost:8080/api/v1/debug/generator/reset
curl -X POST "localhost:8080/api/v1/debug/generator/burst?seconds=5"
curl -X POST "localhost:8080/api/v1/debug/generator/empty-history?on=true"
curl -s      localhost:8080/api/v1/debug/sessions | jq
curl -X POST localhost:8080/api/v1/debug/sessions/<id>/drop
curl -X POST localhost:8080/api/v1/debug/sessions/<id>/tier?tier=MINIMAL
curl -X POST localhost:8080/api/v1/debug/sessions/<id>/faults \
     -H 'content-type: application/json' -d '{"skipBookDeltas":3}'
```

Fault request fields: `skipBookDeltas`, `duplicateDelta`, `reverseDeltas`, `malformedFrames`, `writeDelayMs`, `writeJitterMs`, `holdWritesMs`, `skipCandleClosed`.

## Inspecting the metrics database

```bash
sqlite3 data/pulsetrade.db "select count(*) from latency_samples;"
sqlite3 data/pulsetrade.db "select from_tier, to_tier, reason, streak from tier_transitions order by id desc limit 10;"
sqlite3 data/pulsetrade.db "select interval, count(*), min(close), max(close) from candle_closes group by interval;"
```

The table definitions and the reason each column exists are documented in
`internal/metrics/sqlite/migrations/`; `internal/metrics/query.go` holds the read API.
