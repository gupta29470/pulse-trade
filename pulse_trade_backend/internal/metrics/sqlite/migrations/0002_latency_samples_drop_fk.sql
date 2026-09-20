-- 0002: drop the foreign key from latency_samples.
--
-- Why this is a migration rather than an edit to 0001: an applied migration is
-- immutable, and the runner verifies a recorded checksum, so changing 0001 in
-- place would refuse to start against any database created before the change.
--
-- Why the constraint had to go: telemetry tables are an append-only event log
-- written best-effort through one batched transaction. The foreign key made a
-- session's telemetry insertable only after that session's row had committed, so
-- a sample that arrived before (or without) a sessions row failed the whole
-- batch — losing every other record in it, including records for other sessions.
-- One missing row is not a reason to discard unrelated telemetry, and the
-- referential check buys nothing here: session_id is written from the same
-- process, the sessions table still carries its own primary key, and the column
-- keeps its index so per-session queries and joins still work.
--
-- SQLite cannot drop a constraint, so the table is rebuilt and its rows copied.

CREATE TABLE latency_samples_v2 (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT NOT NULL,
  seq          INTEGER NOT NULL,
  rtt_ms       REAL NOT NULL,
  jitter_ms    REAL NOT NULL,
  samples      INTEGER NOT NULL,
  client_time  TIMESTAMP,
  server_time  TIMESTAMP NOT NULL,
  capped       BOOLEAN NOT NULL DEFAULT 0,
  missed_pong  BOOLEAN NOT NULL DEFAULT 0
);

INSERT INTO latency_samples_v2
  (id, session_id, seq, rtt_ms, jitter_ms, samples, client_time, server_time, capped, missed_pong)
SELECT
  id, session_id, seq, rtt_ms, jitter_ms, samples, client_time, server_time, capped, missed_pong
FROM latency_samples;

DROP TABLE latency_samples;

ALTER TABLE latency_samples_v2 RENAME TO latency_samples;

CREATE INDEX idx_latency_session_time ON latency_samples(session_id, server_time);
CREATE INDEX idx_latency_time         ON latency_samples(server_time);
