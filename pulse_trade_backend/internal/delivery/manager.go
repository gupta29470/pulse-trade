package delivery

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/market"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
	"github.com/pulsetrade/pulse-trade-backend/internal/protocol"
)

// ManagerConfig carries the manager's dependencies and defaults.
type ManagerConfig struct {
	// Registry maps every live market to its engine. A session resolves the
	// market a client asks for here.
	Registry *market.Registry
	// DefaultSymbol is the market a new session is bound to before the client
	// subscribes, which is what lets the welcome frame name a market.
	DefaultSymbol domain.Symbol
	ServerVersion string
	Policy        Policy
	Logger        *observability.Logger
	// MetricsRegistry carries the process counters and gauges.
	MetricsRegistry *observability.Registry
	Recorder        Recorder
	Clock           domain.Clock
	DefaultChannels map[string]bool

	OutboundCapacity int
	WriteTimeout     time.Duration
	ClientMsgPerSec  int
	ReadLimitBytes   int64
	BookWindow       int
	HistoryLimit     int
	TradesLimit      int
	DebugControls    bool
	BusCapacity      int
}

// Manager owns the set of connected sessions.
type Manager struct {
	cfg ManagerConfig

	mu       sync.RWMutex
	sessions map[string]*Session

	totalSessions  atomic.Int64
	activeSessions atomic.Int64
	reconnects     atomic.Int64

	// deviceSeen tracks which installations have connected before. Reconnects are
	// counted from the client's hello frame rather than inferred from session churn:
	// every reconnect creates a new session, so counting sessions would report the
	// number of connections rather than the number of reconnections.
	deviceMu   sync.Mutex
	deviceSeen map[string]struct{}
}

// NewManager creates an empty manager.
func NewManager(cfg ManagerConfig) *Manager {
	if cfg.Clock == nil {
		cfg.Clock = domain.SystemClock()
	}
	if cfg.Policy == nil {
		cfg.Policy = NewDefaultPolicy(Thresholds{
			FullMaxRTTMs: 150, FullMaxJitterMs: 50, MinimalMinRTTMs: 500, MinimalMinJitterMs: 150,
			DegradeStreak: 3, RecoverStreak: 5, ReportHold: 5 * time.Second, ReportDegrade: 10 * time.Second,
		}, 10, 2, 0.5)
	}
	if cfg.BusCapacity <= 0 {
		cfg.BusCapacity = 256
	}
	return &Manager{cfg: cfg, sessions: make(map[string]*Session), deviceSeen: make(map[string]struct{})}
}

// Register creates a session for a connection and adds it to the registry. The
// session is not started; the caller runs it, which keeps registration and
// execution separable for tests.
func (m *Manager) Register(conn Conn, hello *protocol.Hello) *Session {
	id, shortID := newSessionID(m.cfg.Clock.Now())

	channels := make(map[string]bool, len(m.cfg.DefaultChannels))
	for c := range m.cfg.DefaultChannels {
		channels[c] = true
	}
	if len(channels) == 0 {
		for _, c := range protocol.DefaultChannels() {
			channels[c] = true
		}
	}

	cfg := SessionConfig{
		ID:               id,
		ShortID:          shortID,
		Symbol:           m.cfg.DefaultSymbol,
		Interval:         domain.Interval1m,
		Channels:         channels,
		Policy:           m.cfg.Policy,
		Logger:           m.cfg.Logger,
		Registry:         m.cfg.Registry,
		MetricsRegistry:  m.cfg.MetricsRegistry,
		Recorder:         m.cfg.Recorder,
		Clock:            m.cfg.Clock,
		OutboundCapacity: m.cfg.OutboundCapacity,
		WriteTimeout:     m.cfg.WriteTimeout,
		ClientMsgPerSec:  m.cfg.ClientMsgPerSec,
		ReadLimitBytes:   m.cfg.ReadLimitBytes,
		BookWindow:       m.cfg.BookWindow,
		HistoryLimit:     m.cfg.HistoryLimit,
		TradesLimit:      m.cfg.TradesLimit,
		DebugControls:    m.cfg.DebugControls,
		OnHello:          m.NotifyHello,
	}

	session := NewSession(cfg, conn, m.defaultEngine(), m.cfg.Clock)
	m.mu.Lock()
	m.sessions[id] = session
	m.mu.Unlock()

	m.totalSessions.Add(1)
	m.activeSessions.Add(1)
	_ = hello
	return session
}

// defaultEngine returns the market a session is bound to before it subscribes.
// A registry without that market leaves the session engine-less, which Run
// reports as ErrNoEngine.
func (m *Manager) defaultEngine() *market.Engine {
	if m.cfg.Registry == nil {
		return nil
	}
	engine, _ := m.cfg.Registry.Lookup(m.cfg.DefaultSymbol)
	return engine
}

// Unregister removes a session and releases its resources.
func (m *Manager) Unregister(sessionID string) {
	m.mu.Lock()
	session, ok := m.sessions[sessionID]
	if ok {
		delete(m.sessions, sessionID)
	}
	m.mu.Unlock()
	if !ok {
		return
	}
	m.activeSessions.Add(-1)
	session.Drop("unregistered")
}

// Session looks up a live session.
func (m *Manager) Session(sessionID string) (*Session, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.sessions[sessionID]
	return s, ok
}

// Sessions returns a snapshot of the live sessions.
func (m *Manager) Sessions() []*Session {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		out = append(out, s)
	}
	return out
}

// Count returns how many sessions are connected.
func (m *Manager) Count() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.sessions)
}

// TotalSessions returns how many sessions have ever been created.
func (m *Manager) TotalSessions() int64 { return m.totalSessions.Load() }

// NotifyHello records a client's installation id and counts a repeat as a
// reconnect. The device id is a random per-install value, so it identifies a client
// without identifying a person.
func (m *Manager) NotifyHello(deviceID string) {
	if deviceID == "" {
		return
	}
	m.deviceMu.Lock()
	_, seen := m.deviceSeen[deviceID]
	m.deviceSeen[deviceID] = struct{}{}
	m.deviceMu.Unlock()
	if seen {
		m.reconnects.Add(1)
	}
}

// Reconnects returns the reconnect counter, which the diagnostics endpoint reports.
func (m *Manager) Reconnects() int64 { return m.reconnects.Load() }

// TierDistribution counts sessions per delivery tier.
func (m *Manager) TierDistribution() map[string]int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := map[string]int{
		string(domain.TierFull):     0,
		string(domain.TierDegraded): 0,
		string(domain.TierMinimal):  0,
	}
	for _, s := range m.sessions {
		out[string(s.Tier())]++
	}
	return out
}

// Drop terminates one session by id, which is how the debug control and the
// fault-injection demo disconnect a specific client.
func (m *Manager) Drop(sessionID, reason string) bool {
	session, ok := m.Session(sessionID)
	if !ok {
		return false
	}
	session.Drop(reason)
	return true
}

// ApplyFaults installs a fault configuration on one session.
func (m *Manager) ApplyFaults(sessionID string, cfg FaultConfig) bool {
	session, ok := m.Session(sessionID)
	if !ok {
		return false
	}
	session.ApplyFaults(cfg)
	return true
}

// CloseAll drains every session with a reason and waits for them to finish.
func (m *Manager) CloseAll(reason string, wait time.Duration) {
	sessions := m.Sessions()
	for _, s := range sessions {
		s.Drop(reason)
	}
	deadline := m.cfg.Clock.Now().Add(wait)
	for m.Count() > 0 && m.cfg.Clock.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
}

// --- session ids ------------------------------------------------------------

// Crockford base32, as used by ULID: no I, L, O or U, so an id read aloud or
// copied out of a log cannot be mistyped into a different valid id.
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// newSessionID returns a sortable, opaque session id plus a six-character display
// id. The full id carries a millisecond timestamp so sessions sort chronologically
// in the database; the short id is what the diagnostics screen shows.
func newSessionID(now time.Time) (id string, shortID string) {
	var raw [16]byte
	ms := uint64(now.UnixMilli())
	raw[0] = byte(ms >> 40)
	raw[1] = byte(ms >> 32)
	raw[2] = byte(ms >> 24)
	raw[3] = byte(ms >> 16)
	raw[4] = byte(ms >> 8)
	raw[5] = byte(ms)
	if _, err := rand.Read(raw[6:]); err != nil {
		// crypto/rand failure is not survivable for id uniqueness; fall back to a
		// timestamp-derived suffix rather than panicking in a request path.
		binary.BigEndian.PutUint64(raw[8:], uint64(now.UnixNano()))
	}

	var encoded [26]byte
	// 128 bits encode into 26 base32 characters (130 bits) with the top two bits
	// unused.
	var acc uint32
	var bits uint
	idx := 0
	for _, b := range raw {
		acc = acc<<8 | uint32(b)
		bits += 8
		for bits >= 5 && idx < len(encoded) {
			bits -= 5
			encoded[idx] = crockford[(acc>>bits)&0x1F]
			idx++
		}
	}
	for idx < len(encoded) {
		encoded[idx] = crockford[acc&0x1F]
		idx++
	}
	full := "sess_" + string(encoded[:25])

	short := make([]byte, 6)
	for i := range short {
		short[i] = crockford[raw[10+i%6]&0x1F]
	}
	return full, string(short)
}

// ErrNoEngine is returned when a session is started without an engine attached.
var ErrNoEngine = fmt.Errorf("delivery: session has no engine")

// SetEngine binds a session to one market's engine. It is separate from Register
// so tests can build a session against a stub.
func (s *Session) SetEngine(engine *market.Engine) {
	s.engine = engine
}
