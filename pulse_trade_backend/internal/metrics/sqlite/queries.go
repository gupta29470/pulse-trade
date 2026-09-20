package sqlite

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// SummaryStats counts the windowed rows behind the metrics summary. Every count
// is a single indexed aggregate; the raw latency values are read separately
// because percentiles need the samples themselves.
func (r *Repository) SummaryStats(ctx context.Context, from, to time.Time) (metrics.SummaryStats, error) {
	stats := metrics.SummaryStats{TierDistribution: map[string]int{}}
	if r.isClosed() {
		return stats, ErrDatabaseClosed
	}
	lo, hi := encodeTime(from), encodeTime(to)

	type countQuery struct {
		target *int64
		sql    string
		args   []any
	}
	queries := []countQuery{
		{&stats.TotalSessions, `SELECT COUNT(*) FROM sessions`, nil},
		{&stats.ActiveSessions, `SELECT COUNT(*) FROM sessions WHERE disconnected_at IS NULL OR disconnected_at = ''`, nil},
		{&stats.Reconnects, `SELECT COUNT(*) FROM sessions WHERE disconnect_reason IN ('client_reconnect', 'reconnect')`, nil},
		{&stats.LatencySamples, `SELECT COUNT(*) FROM latency_samples WHERE server_time >= ? AND server_time <= ?`, []any{lo, hi}},
		{&stats.DeliveryWindows, `SELECT COUNT(*) FROM delivery_windows WHERE window_start >= ? AND window_start <= ?`, []any{lo, hi}},
		{&stats.TierTransitions, `SELECT COUNT(*) FROM tier_transitions WHERE at >= ? AND at <= ?`, []any{lo, hi}},
		{&stats.EngineEvents, `SELECT COUNT(*) FROM engine_events WHERE at >= ? AND at <= ?`, []any{lo, hi}},
		{&stats.CandleInvariants, `SELECT COUNT(*) FROM engine_events WHERE event = 'INVARIANT_VIOLATION' AND at >= ? AND at <= ?`, []any{lo, hi}},
		{&stats.CandleCloses, `SELECT COUNT(*) FROM candle_closes WHERE closed_at >= ? AND closed_at <= ?`, []any{lo, hi}},
		{&stats.BookRecoveries, `SELECT COUNT(*) FROM book_sync_events WHERE event = 'RECOVERY_STARTED' AND at >= ? AND at <= ?`, []any{lo, hi}},
		{&stats.BookGapsDetected, `SELECT COUNT(*) FROM book_sync_events WHERE event = 'GAP_DETECTED' AND at >= ? AND at <= ?`, []any{lo, hi}},
		{&stats.MalformedMessages, `SELECT COALESCE(SUM(count), 0) FROM protocol_events WHERE kind = 'MALFORMED_FRAME' AND at >= ? AND at <= ?`, []any{lo, hi}},
		{&stats.DuplicateDeltas, `SELECT COALESCE(SUM(count), 0) FROM protocol_events WHERE kind = 'DUPLICATE_DELTA' AND at >= ? AND at <= ?`, []any{lo, hi}},
		{&stats.StaleDeltas, `SELECT COALESCE(SUM(count), 0) FROM protocol_events WHERE kind = 'STALE_DELTA' AND at >= ? AND at <= ?`, []any{lo, hi}},
		{&stats.OutOfOrderTrades, `SELECT COALESCE(SUM(count), 0) FROM protocol_events WHERE kind = 'OUT_OF_ORDER_TRADE' AND at >= ? AND at <= ?`, []any{lo, hi}},
	}
	for _, q := range queries {
		if err := r.db.QueryRowContext(ctx, q.sql, q.args...).Scan(q.target); err != nil {
			return stats, fmt.Errorf("metrics/sqlite: summary count %q: %w", summariseSQL(q.sql), err)
		}
	}

	rows, err := r.db.QueryContext(ctx, `
		SELECT COALESCE(NULLIF(final_tier, ''), initial_tier) AS tier, COUNT(*)
		FROM sessions GROUP BY tier`)
	if err != nil {
		return stats, fmt.Errorf("metrics/sqlite: tier distribution: %w", err)
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var tier sql.NullString
		var n int
		if err := rows.Scan(&tier, &n); err != nil {
			return stats, fmt.Errorf("metrics/sqlite: scan tier distribution: %w", err)
		}
		if tier.Valid && tier.String != "" {
			stats.TierDistribution[tier.String] += n
		}
	}
	if err := rows.Err(); err != nil {
		return stats, fmt.Errorf("metrics/sqlite: iterate tier distribution: %w", err)
	}
	return stats, nil
}

// LatencySamples returns raw samples in ascending server-time order. The ordering
// matters because it is the order the diagnostics chart draws.
func (r *Repository) LatencySamples(ctx context.Context, q metrics.LatencyQuery) ([]observability.LatencySample, error) {
	if r.isClosed() {
		return nil, ErrDatabaseClosed
	}
	sqlText, args := latencySelect(q, true)
	rows, err := r.db.QueryContext(ctx, sqlText, args...)
	if err != nil {
		return nil, fmt.Errorf("metrics/sqlite: query latency samples: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []observability.LatencySample
	for rows.Next() {
		var (
			s          observability.LatencySample
			serverTime string
			clientTime sql.NullString
			capped     int64
			missedPong int64
		)
		if err := rows.Scan(
			&s.SessionID, &s.Seq, &s.RTTMs, &s.JitterMs, &s.Samples,
			&clientTime, &serverTime, &capped, &missedPong,
		); err != nil {
			return nil, fmt.Errorf("metrics/sqlite: scan latency sample: %w", err)
		}
		s.ServerTime = decodeTime(serverTime)
		if clientTime.Valid && clientTime.String != "" {
			s.ClientTimeMs = decodeTime(clientTime.String).UnixMilli()
		}
		s.Capped = intToBool(capped)
		s.MissedPong = intToBool(missedPong)
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("metrics/sqlite: iterate latency samples: %w", err)
	}
	return out, nil
}

// latencySelect builds the sample query. Bucketing is done in Go rather than in
// SQL date arithmetic so both drivers aggregate with identical code.
func latencySelect(q metrics.LatencyQuery, ordered bool) (string, []any) {
	var (
		sb   strings.Builder
		args []any
	)
	sb.WriteString(`SELECT session_id, seq, rtt_ms, jitter_ms, samples, client_time, server_time, capped, missed_pong FROM latency_samples`)
	var where []string
	if q.SessionID != "" {
		where = append(where, "session_id = ?")
		args = append(args, q.SessionID)
	}
	if !q.From.IsZero() {
		where = append(where, "server_time >= ?")
		args = append(args, encodeTime(q.From))
	}
	if !q.To.IsZero() {
		where = append(where, "server_time <= ?")
		args = append(args, encodeTime(q.To))
	}
	if len(where) > 0 {
		sb.WriteString(" WHERE ")
		sb.WriteString(strings.Join(where, " AND "))
	}
	if ordered {
		sb.WriteString(" ORDER BY server_time ASC, id ASC")
	}
	if q.Limit > 0 {
		sb.WriteString(" LIMIT ?")
		args = append(args, q.Limit)
	}
	return sb.String(), args
}

// EngineEventCounters counts engine events in a window.
func (r *Repository) EngineEventCounters(ctx context.Context, from, to time.Time) (metrics.EngineEventCounters, error) {
	var c metrics.EngineEventCounters
	if r.isClosed() {
		return c, ErrDatabaseClosed
	}
	lo, hi := encodeTime(from), encodeTime(to)
	if err := r.db.QueryRowContext(ctx,
		`SELECT COUNT(*), COALESCE(SUM(CASE WHEN event = 'INVARIANT_VIOLATION' THEN 1 ELSE 0 END), 0)
		 FROM engine_events WHERE at >= ? AND at <= ?`, lo, hi,
	).Scan(&c.Total, &c.InvariantViolations); err != nil {
		return c, fmt.Errorf("metrics/sqlite: engine event counters: %w", err)
	}
	return c, nil
}

// TierTransitions returns transitions in descending time order.
func (r *Repository) TierTransitions(ctx context.Context, from, to time.Time, limit int) ([]observability.TierTransitionRow, error) {
	if r.isClosed() {
		return nil, ErrDatabaseClosed
	}
	var (
		sb   strings.Builder
		args []any
	)
	sb.WriteString(`SELECT session_id, at, from_tier, to_tier, reason, rtt_ms, jitter_ms, streak, override FROM tier_transitions`)
	var where []string
	if !from.IsZero() {
		where = append(where, "at >= ?")
		args = append(args, encodeTime(from))
	}
	if !to.IsZero() {
		where = append(where, "at <= ?")
		args = append(args, encodeTime(to))
	}
	if len(where) > 0 {
		sb.WriteString(" WHERE ")
		sb.WriteString(strings.Join(where, " AND "))
	}
	sb.WriteString(" ORDER BY at DESC, id DESC LIMIT ?")
	args = append(args, limit)

	rows, err := r.db.QueryContext(ctx, sb.String(), args...)
	if err != nil {
		return nil, fmt.Errorf("metrics/sqlite: query tier transitions: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []observability.TierTransitionRow
	for rows.Next() {
		var (
			t      observability.TierTransitionRow
			at     string
			rtt    sql.NullFloat64
			jitter sql.NullFloat64
			streak sql.NullInt64
			over   sql.NullString
		)
		if err := rows.Scan(&t.SessionID, &at, &t.From, &t.To, &t.Reason, &rtt, &jitter, &streak, &over); err != nil {
			return nil, fmt.Errorf("metrics/sqlite: scan tier transition: %w", err)
		}
		t.At = decodeTime(at)
		t.RTTMs = rtt.Float64
		t.JitterMs = jitter.Float64
		t.Streak = int(streak.Int64)
		t.Override = over.String
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("metrics/sqlite: iterate tier transitions: %w", err)
	}
	return out, nil
}

// Sessions returns lifecycle rows, most recent connection first.
func (r *Repository) Sessions(ctx context.Context, limit int) ([]observability.SessionRow, error) {
	if r.isClosed() {
		return nil, ErrDatabaseClosed
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT session_id, device_id, client_version, platform, remote_addr, symbol, interval,
		       connected_at, disconnected_at, disconnect_reason, initial_tier, final_tier,
		       override_tier, uptime_ms, messages_sent, messages_received, bytes_sent, protocol_errors
		FROM sessions ORDER BY connected_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("metrics/sqlite: query sessions: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []observability.SessionRow
	for rows.Next() {
		var (
			s              observability.SessionRow
			connectedAt    string
			disconnectedAt sql.NullString
			deviceID       sql.NullString
			clientVersion  sql.NullString
			platform       sql.NullString
			remoteAddr     sql.NullString
			disconnectWhy  sql.NullString
			finalTier      sql.NullString
			overrideTier   sql.NullString
			uptimeMs       sql.NullInt64
			messagesSent   sql.NullInt64
			messagesRecv   sql.NullInt64
			bytesSent      sql.NullInt64
			protocolErrs   sql.NullInt64
		)
		if err := rows.Scan(
			&s.SessionID, &deviceID, &clientVersion, &platform, &remoteAddr, &s.Symbol, &s.Interval,
			&connectedAt, &disconnectedAt, &disconnectWhy, &s.InitialTier, &finalTier,
			&overrideTier, &uptimeMs, &messagesSent, &messagesRecv, &bytesSent, &protocolErrs,
		); err != nil {
			return nil, fmt.Errorf("metrics/sqlite: scan session: %w", err)
		}
		s.DeviceID = deviceID.String
		s.ClientVersion = clientVersion.String
		s.Platform = platform.String
		s.RemoteAddr = remoteAddr.String
		s.ConnectedAt = decodeTime(connectedAt)
		s.DisconnectedAt = decodeTimePtr(disconnectedAt)
		s.DisconnectReason = disconnectWhy.String
		s.FinalTier = finalTier.String
		s.OverrideTier = overrideTier.String
		s.UptimeMs = uptimeMs.Int64
		s.MessagesSent = messagesSent.Int64
		s.MessagesReceived = messagesRecv.Int64
		s.BytesSent = bytesSent.Int64
		s.ProtocolErrors = protocolErrs.Int64
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("metrics/sqlite: iterate sessions: %w", err)
	}
	return out, nil
}

// DeliveryWindows returns delivery windows in descending time order.
func (r *Repository) DeliveryWindows(ctx context.Context, sessionID string, from, to time.Time, limit int) ([]observability.DeliveryWindow, error) {
	if r.isClosed() {
		return nil, ErrDatabaseClosed
	}
	var (
		sb   strings.Builder
		args []any
	)
	sb.WriteString(`SELECT session_id, window_start, window_ms, tier, target_rate, candle_updates,
		trade_messages, book_deltas, health_messages, coalesced_count, suppressed_count, bytes_sent, effective_rate
		FROM delivery_windows`)
	var where []string
	if sessionID != "" {
		where = append(where, "session_id = ?")
		args = append(args, sessionID)
	}
	if !from.IsZero() {
		where = append(where, "window_start >= ?")
		args = append(args, encodeTime(from))
	}
	if !to.IsZero() {
		where = append(where, "window_start <= ?")
		args = append(args, encodeTime(to))
	}
	if len(where) > 0 {
		sb.WriteString(" WHERE ")
		sb.WriteString(strings.Join(where, " AND "))
	}
	sb.WriteString(" ORDER BY window_start DESC, id DESC LIMIT ?")
	args = append(args, limit)

	rows, err := r.db.QueryContext(ctx, sb.String(), args...)
	if err != nil {
		return nil, fmt.Errorf("metrics/sqlite: query delivery windows: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []observability.DeliveryWindow
	for rows.Next() {
		var (
			w           observability.DeliveryWindow
			windowStart string
		)
		if err := rows.Scan(
			&w.SessionID, &windowStart, &w.WindowMs, &w.Tier, &w.TargetRate, &w.CandleUpdates,
			&w.TradeMessages, &w.BookDeltas, &w.HealthMessages, &w.Coalesced, &w.Suppressed,
			&w.BytesSent, &w.EffectiveRate,
		); err != nil {
			return nil, fmt.Errorf("metrics/sqlite: scan delivery window: %w", err)
		}
		w.WindowStart = decodeTime(windowStart)
		out = append(out, w)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("metrics/sqlite: iterate delivery windows: %w", err)
	}
	return out, nil
}
