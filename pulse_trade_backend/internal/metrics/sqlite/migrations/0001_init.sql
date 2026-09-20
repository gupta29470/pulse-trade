-- 0001_init.sql — the complete metrics schema.
--
-- Every timestamp column is written by the Go layer as RFC3339 with
-- milliseconds in UTC ("2026-09-17T12:41:03.235Z"). That format is
-- fixed-width and UTC-only, so lexicographic TEXT comparison is also
-- chronological comparison and windowed queries stay index-friendly
-- without any date function on the column.
--
-- Prices and quantities in candle_closes are exact decimal TEXT, never REAL:
-- the audit trail must not round.

-- 1. One row per connected session (lifecycle)
CREATE TABLE sessions (
  session_id        TEXT PRIMARY KEY,
  device_id         TEXT,
  client_version    TEXT,
  platform          TEXT,
  remote_addr       TEXT,
  symbol            TEXT NOT NULL,
  interval          TEXT NOT NULL,
  connected_at      TIMESTAMP NOT NULL,
  disconnected_at   TIMESTAMP,
  disconnect_reason TEXT,
  initial_tier      TEXT NOT NULL,
  final_tier        TEXT,
  override_tier     TEXT,
  uptime_ms         INTEGER,
  messages_sent     INTEGER DEFAULT 0,
  messages_received INTEGER DEFAULT 0,
  bytes_sent        INTEGER DEFAULT 0,
  protocol_errors   INTEGER DEFAULT 0
);

-- 2. Every latency sample
CREATE TABLE latency_samples (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT NOT NULL REFERENCES sessions(session_id),
  seq          INTEGER NOT NULL,          -- sample index within the session
  rtt_ms       REAL NOT NULL,
  jitter_ms    REAL NOT NULL,
  samples      INTEGER NOT NULL,          -- window size used
  client_time  TIMESTAMP,
  server_time  TIMESTAMP NOT NULL,
  capped       BOOLEAN NOT NULL DEFAULT 0,-- outlier cap applied
  missed_pong  BOOLEAN NOT NULL DEFAULT 0
);
CREATE INDEX idx_latency_session_time ON latency_samples(session_id, server_time);
CREATE INDEX idx_latency_time         ON latency_samples(server_time);

-- 3. Every health report as received (before policy)
CREATE TABLE health_reports (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id        TEXT NOT NULL,
  received_at       TIMESTAMP NOT NULL,
  rtt_ms            REAL NOT NULL,
  jitter_ms         REAL NOT NULL,
  age_since_last_ms INTEGER,
  band              TEXT NOT NULL          -- GOOD | DEGRADED_BAND | MINIMAL_BAND
);
CREATE INDEX idx_health_session_time ON health_reports(session_id, received_at);

-- 4. Every tier transition with its reason
CREATE TABLE tier_transitions (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id  TEXT NOT NULL,
  at          TIMESTAMP NOT NULL,
  from_tier   TEXT NOT NULL,
  to_tier     TEXT NOT NULL,
  reason      TEXT NOT NULL,               -- GOOD_HEALTH|HIGH_RTT|HIGH_JITTER|MISSING_REPORTS|FORCED_OVERRIDE|RECOVERY
  rtt_ms      REAL,
  jitter_ms   REAL,
  streak      INTEGER,
  override    TEXT                         -- value in force at transition time
);
CREATE INDEX idx_tier_session_time ON tier_transitions(session_id, at);

-- 5. Delivered-vs-target rate windows (every 5 s per session)
CREATE TABLE delivery_windows (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id         TEXT NOT NULL,
  window_start       TIMESTAMP NOT NULL,
  window_ms          INTEGER NOT NULL,
  tier               TEXT NOT NULL,
  target_rate        REAL NOT NULL,
  candle_updates     INTEGER NOT NULL,
  trade_messages     INTEGER NOT NULL,
  book_deltas        INTEGER NOT NULL,
  health_messages    INTEGER NOT NULL,
  coalesced_count    INTEGER NOT NULL,
  suppressed_count   INTEGER NOT NULL,
  bytes_sent         INTEGER NOT NULL,
  effective_rate     REAL NOT NULL
);
CREATE INDEX idx_delivery_session_time ON delivery_windows(session_id, window_start);

-- 6. Order-book synchronization events (engine side and session side)
CREATE TABLE book_sync_events (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  at             TIMESTAMP NOT NULL,
  session_id     TEXT,                     -- NULL = engine-internal event
  scope          TEXT NOT NULL,            -- ENGINE | SESSION
  event          TEXT NOT NULL,            -- SNAPSHOT_APPLIED|GAP_DETECTED|RECOVERY_STARTED|RECOVERY_COMPLETE|RECOVERY_FAILED|EPOCH_CHANGED|COALESCED
  epoch          INTEGER NOT NULL,
  from_update_id INTEGER,
  to_update_id   INTEGER,
  gap_size       INTEGER,
  duration_ms    INTEGER,
  attempt        INTEGER
);
CREATE INDEX idx_book_sync_time ON book_sync_events(at);

-- 7. Protocol anomalies
CREATE TABLE protocol_events (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  at           TIMESTAMP NOT NULL,
  session_id   TEXT,
  kind         TEXT NOT NULL,   -- MALFORMED_FRAME|UNKNOWN_TYPE|VALIDATION_FAILED|RATE_LIMITED|DUPLICATE_DELTA|STALE_DELTA|OUT_OF_ORDER_TRADE|MISSED_PONG|UNKNOWN_MESSAGE
  detail       TEXT,
  count        INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_protocol_time ON protocol_events(at);

-- 8. Generator / engine events
CREATE TABLE engine_events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  at          TIMESTAMP NOT NULL,
  event       TEXT NOT NULL,   -- START|WARMUP_COMPLETE|PAUSE|RESUME|RESET|BURST_START|BURST_END|INVARIANT_VIOLATION|SHUTDOWN
  epoch       INTEGER,
  event_index INTEGER,
  update_id   INTEGER,
  trade_id    INTEGER,
  detail      TEXT,
  duration_ms INTEGER
);
CREATE INDEX idx_engine_events_time ON engine_events(at);

-- 9. Candle closes (audit trail proving candle truth)
CREATE TABLE candle_closes (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  symbol        TEXT NOT NULL,
  interval      TEXT NOT NULL,
  start_time    TIMESTAMP NOT NULL,
  open          TEXT NOT NULL,   -- exact decimal strings
  high          TEXT NOT NULL,
  low           TEXT NOT NULL,
  close         TEXT NOT NULL,
  volume        TEXT NOT NULL,
  trade_count   INTEGER NOT NULL,
  closed_at     TIMESTAMP NOT NULL,
  epoch         INTEGER NOT NULL,
  UNIQUE(symbol, interval, start_time, epoch)
);

-- 10. Fault injection audit (debug builds)
CREATE TABLE fault_injections (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  at          TIMESTAMP NOT NULL,
  session_id  TEXT,
  fault       TEXT NOT NULL,
  parameters  TEXT,
  applied     BOOLEAN NOT NULL
);

-- 11. Schema versioning
--
-- schema_migrations is created by the migration runner before any file is read,
-- so it is deliberately NOT created here: the runner must be able to record that
-- it has already applied this file, which is impossible if the file is what
-- creates the bookkeeping table.
