package delivery

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/market"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
	"github.com/pulsetrade/pulse-trade-backend/internal/protocol"
)

// Conn is the socket surface a session needs. It is declared here, by the
// consumer, so the delivery layer can be exercised without a real WebSocket and so
// the transport package stays replaceable.
type Conn interface {
	// WriteMessage writes one frame, honouring its own write deadline.
	WriteMessage(ctx context.Context, data []byte) error
	// ReadMessage blocks for the next frame.
	ReadMessage(ctx context.Context) ([]byte, error)
	// Close releases the connection.
	Close() error
	// RemoteAddr identifies the peer for logs and session records.
	RemoteAddr() string
}

// Recorder is the metrics surface the delivery layer needs.
type Recorder interface {
	RecordLatency(observability.LatencySample)
	RecordHealthReport(observability.HealthReportRow)
	RecordTierTransition(observability.TierTransitionRow)
	RecordDeliveryWindow(observability.DeliveryWindow)
	RecordBookEvent(observability.BookSyncEvent)
	RecordProtocolEvent(observability.ProtocolEvent)
	RecordSessionStart(observability.SessionRow)
	RecordSessionEnd(observability.SessionRow)
	RecordFaultInjection(observability.FaultInjectionRow)
}

// FaultConfig is the set of delivery-path faults that can be injected into one
// connection. They exist so that client-side recovery paths can be demonstrated and
// tested against the real server rather than a mock of it.
type FaultConfig struct {
	// SkipBookDeltas makes the next N deltas start past what the client can apply,
	// which is a missing order-book update from the client's point of view.
	SkipBookDeltas int
	// DuplicateDelta re-sends the previous delta, which the client must ignore
	// idempotently.
	DuplicateDelta bool
	// ReverseDeltas holds one delta and sends the following one first.
	ReverseDeltas bool
	// MalformedFrames writes N deliberately invalid frames.
	MalformedFrames int
	// WriteDelay adds latency to every write; WriteJitter randomises it.
	WriteDelay  time.Duration
	WriteJitter time.Duration
	// HoldWrites blocks the writer, which forces write-deadline failures and
	// exercises the slow-consumer path.
	HoldWrites time.Duration
	// SkipCandleClosed suppresses the next close event, which should force a
	// resynchronisation rather than silently losing a closed bucket.
	SkipCandleClosed bool
}

// SessionConfig carries everything one connection needs.
type SessionConfig struct {
	ID       string
	ShortID  string
	Symbol   domain.Symbol
	Interval domain.Interval
	Channels map[string]bool
	Policy   Policy
	Logger   *observability.Logger
	// Registry maps every live market to its engine; a subscribe command
	// rebinds the session through it.
	Registry *market.Registry
	// MetricsRegistry carries the process counters and gauges.
	MetricsRegistry *observability.Registry
	Recorder        Recorder
	Clock           domain.Clock

	OutboundCapacity int
	WriteTimeout     time.Duration
	ClientMsgPerSec  int
	ReadLimitBytes   int64
	BookWindow       int
	HistoryLimit     int
	TradesLimit      int
	DebugControls    bool
	// OnHello receives the client's installation id from its hello frame, which is
	// how the manager counts reconnects.
	OnHello func(deviceID string)
}

// Session is one connected client.
//
// It runs four loops: a reader, a writer, a delivery loop and a watchdog folded
// into the delivery loop's select. The writer is the only goroutine that touches the
// socket, and the delivery loop is the only goroutine that mutates delivery state,
// which is what keeps the tier machine, the coalescer and the scheduler free of
// locks.
type Session struct {
	cfg    SessionConfig
	conn   Conn
	engine *market.Engine
	sub    *market.Subscription

	tierMachine *TierMachine
	health      *HealthTracker
	coalescer   *Coalescer

	outbound chan outbound
	commands chan protocol.ClientMessage
	// retune asks the delivery loop to re-arm its flush ticker after a tier change.
	retune chan struct{}

	cancel      context.CancelFunc
	done        chan struct{}
	dropped     atomic.Int64
	writeFails  atomic.Int64
	closeReason atomic.Value // string

	// Delivery accounting for the current measurement window.
	window            deliveryWindow
	windowStarted     time.Time
	messagesSent      atomic.Int64
	messagesReceived  atomic.Int64
	bytesSent         atomic.Int64
	protocolErrors    atomic.Int64
	reconnects        atomic.Int64
	lastSeq           atomic.Uint64
	lastReportAgeMs   atomic.Int64
	lastEffectiveRate atomic.Int64 // milli-units, to avoid a lock on a float

	// Fault injection state. Only mutated from the delivery loop or the debug API.
	faultsMu    sync.Mutex
	faults      FaultConfig
	lastDelta   []byte
	heldDelta   []byte
	rng         *rand.Rand
	connectedAt time.Time
}

type outbound struct {
	data     []byte
	kind     protocol.MessageType
	critical bool
}

type deliveryWindow struct {
	tier           domain.DeliveryTier
	candleUpdates  int64
	tradeMessages  int64
	bookDeltas     int64
	healthMessages int64
	coalesced      int64
	suppressed     int64
	bytes          int64
}

// NewSession builds a session. The engine subscription is attached by Run so a
// session that is never started does not exist on the bus.
func NewSession(cfg SessionConfig, conn Conn, engine *market.Engine, clock domain.Clock) *Session {
	if cfg.Policy == nil {
		cfg.Policy = NewDefaultPolicy(Thresholds{
			FullMaxRTTMs: 150, FullMaxJitterMs: 50, MinimalMinRTTMs: 500, MinimalMinJitterMs: 150,
			DegradeStreak: 3, RecoverStreak: 5, ReportHold: 5 * time.Second, ReportDegrade: 10 * time.Second,
		}, 10, 2, 0.5)
	}
	if clock == nil {
		clock = domain.SystemClock()
	}
	if cfg.BookWindow < 10 {
		cfg.BookWindow = 15
	}
	if cfg.OutboundCapacity <= 0 {
		cfg.OutboundCapacity = 256
	}
	if cfg.WriteTimeout <= 0 {
		cfg.WriteTimeout = 5 * time.Second
	}
	if cfg.ClientMsgPerSec <= 0 {
		cfg.ClientMsgPerSec = 20
	}
	if cfg.HistoryLimit <= 0 {
		cfg.HistoryLimit = 500
	}
	if cfg.TradesLimit <= 0 {
		cfg.TradesLimit = 50
	}
	if cfg.Interval == "" {
		cfg.Interval = domain.Interval1m
	}
	if cfg.Channels == nil {
		cfg.Channels = map[string]bool{}
		for _, c := range protocol.DefaultChannels() {
			cfg.Channels[c] = true
		}
	}

	s := &Session{
		cfg:         cfg,
		conn:        conn,
		engine:      engine,
		tierMachine: NewTierMachine(cfg.Policy),
		health:      NewHealthTracker(cfg.Policy),
		coalescer:   NewCoalescer(cfg.Symbol),
		outbound:    make(chan outbound, cfg.OutboundCapacity),
		commands:    make(chan protocol.ClientMessage, 64),
		retune:      make(chan struct{}, 1),
		done:        make(chan struct{}),
		rng:         rand.New(rand.NewPCG(uint64(time.Now().UnixNano()), uint64(len(cfg.ID)))),
		connectedAt: clock.Now(),
	}
	s.closeReason.Store("unknown")
	s.windowStarted = clock.Now()
	s.window.tier = s.tierMachine.Tier()
	return s
}

// ID returns the session identifier.
func (s *Session) ID() string { return s.cfg.ID }

// ShortID returns the compact identifier shown in diagnostics.
func (s *Session) ShortID() string { return s.cfg.ShortID }

// Tier returns the effective delivery tier.
func (s *Session) Tier() domain.DeliveryTier { return s.tierMachine.Tier() }

// Override returns the forced tier, if any.
func (s *Session) Override() string {
	if o := s.tierMachine.Override(); o != nil {
		return string(*o)
	}
	return ""
}

// RemoteAddr returns the peer address.
func (s *Session) RemoteAddr() string { return s.conn.RemoteAddr() }

// ConnectedAt returns when the session was created.
func (s *Session) ConnectedAt() time.Time { return s.connectedAt }

// Health returns the current transport health.
func (s *Session) Health() HealthSnapshot { return s.health.Snapshot(s.cfg.Clock.Now()) }

// Stats returns the session's counters, for the session record.
func (s *Session) Stats() (sent, received, bytesSent, protocolErrors int64) {
	return s.messagesSent.Load(), s.messagesReceived.Load(), s.bytesSent.Load(), s.protocolErrors.Load()
}

// ApplyFaults replaces the injected fault configuration.
func (s *Session) ApplyFaults(cfg FaultConfig) {
	s.faultsMu.Lock()
	s.faults = cfg
	s.faultsMu.Unlock()
}

func (s *Session) currentFaults() FaultConfig {
	s.faultsMu.Lock()
	defer s.faultsMu.Unlock()
	return s.faults
}

// InjectCommand queues a client message as if the app had sent it. The debug API
// uses it so forcing a tier goes through exactly the same code path as the app,
// which is what makes the demo evidence meaningful.
func (s *Session) InjectCommand(msg protocol.ClientMessage) bool {
	select {
	case s.commands <- msg:
		return true
	case <-s.done:
		return false
	default:
		return false
	}
}

// Drop closes the session with a reason, which is how the debug control and the
// slow-consumer path terminate a connection.
func (s *Session) Drop(reason string) {
	s.closeReason.Store(reason)
	if s.cancel != nil {
		s.cancel()
	}
}

// CloseReason returns why the session ended.
func (s *Session) CloseReason() string {
	if v, ok := s.closeReason.Load().(string); ok {
		return v
	}
	return "unknown"
}

// Run starts the session's loops and blocks until the connection ends.
func (s *Session) Run(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	s.cancel = cancel
	defer cancel()
	defer close(s.done)

	if s.engine == nil {
		return ErrNoEngine
	}

	s.sub = s.engine.Subscribe("sess:"+s.cfg.ShortID, s.cfg.OutboundCapacity)
	defer func() {
		// Release whichever subscription is current at exit: a rebind through
		// subscribe replaces both the engine and the subscription.
		if s.sub != nil && s.engine != nil {
			s.engine.Bus().Unsubscribe(s.sub)
		}
	}()

	s.logger().Info(observability.MsgWSConnected,
		observability.FieldRemoteAddr, s.conn.RemoteAddr(),
		observability.FieldSymbol, s.cfg.Symbol.ID,
		observability.FieldInterval, string(s.cfg.Interval),
		observability.FieldEpoch, s.engine.Epoch(),
	)

	s.recordSessionStart()
	s.registryInc(observability.CounterWSConnectionsTotal)
	s.registryInc(observability.CounterWSConnectionsActive)
	s.registrySetGauge(observability.GaugeSessionsActive, int64(s.engine.Bus().SubscriberCount()))

	defer func() {
		reason := s.CloseReason()
		s.registryDec(observability.CounterWSConnectionsActive)
		s.recordSessionEnd(reason)
		// Give the peer an explicit reason before the socket goes away, so a client
		// can distinguish a deliberate shutdown from a network drop instead of
		// discovering a dead socket.
		s.send(ctx, protocol.TypeGoodbye, protocol.GoodbyePayload{Reason: reason}, true)
		_ = s.conn.Close()
		s.logger().Info(observability.MsgWSDisconnected,
			observability.FieldReason, reason,
			observability.FieldUptime, s.cfg.Clock.Now().Sub(s.connectedAt).String())
	}()

	if err := s.sendWelcome(); err != nil {
		return err
	}

	go s.writeLoop(ctx)
	go s.readLoop(ctx)

	s.deliveryLoop(ctx)
	return nil
}

// --- loops ------------------------------------------------------------------

func (s *Session) deliveryLoop(ctx context.Context) {
	flush := time.NewTicker(s.cfg.Policy.FlushInterval(s.tierMachine.Tier()))
	defer flush.Stop()
	health := time.NewTicker(protocol.HealthInterval)
	defer health.Stop()
	watchdog := time.NewTicker(250 * time.Millisecond)
	defer watchdog.Stop()
	window := time.NewTicker(5 * time.Second)
	defer window.Stop()
	// The 24h summary is a slow-moving figure, so it is sent on its own 1 Hz tick
	// rather than riding the chart cadence. A throttled client still gets a current
	// price card.
	summary := time.NewTicker(time.Second)
	defer summary.Stop()
	// A server-side keepalive proves the socket is writable even when the client is
	// silent, and refreshes the peer's read deadline. It is not used for RTT: the
	// client owns the round-trip measurement.
	keepalive := time.NewTicker(protocol.ServerHeartbeatInterval)
	defer keepalive.Stop()

	for {
		select {
		case <-ctx.Done():
			return

		case cmd := <-s.commands:
			s.handleCommand(ctx, cmd)

		case <-s.sub.Done():
			return

		case ev := <-s.sub.Events():
			s.handleEvent(ctx, ev)

		case <-flush.C:
			s.flush(ctx)

		case <-health.C:
			s.sendHealth(ctx)

		case <-watchdog.C:
			if transition := s.tierMachine.OnMissingReports(s.health.Snapshot(s.cfg.Clock.Now()).Age, s.cfg.Clock.Now()); transition.Changed {
				s.onTierChanged(ctx, transition)
			}
			s.lastReportAgeMs.Store(s.health.Snapshot(s.cfg.Clock.Now()).Age.Milliseconds())

		case <-summary.C:
			s.flushSummary(ctx)

		case <-keepalive.C:
			s.send(ctx, protocol.TypePing, protocol.PingPayload{ID: s.cfg.Clock.Now().UnixMilli()}, false)

		case <-window.C:
			s.recordDeliveryWindow()

		case <-s.retune:
			// The tier changed; re-arm the flush ticker to the new cadence.
			flush.Reset(s.cfg.Policy.FlushInterval(s.tierMachine.Tier()))
		}
	}
}

// readLoop parses client frames and hands them to the delivery loop. It never
// mutates session state itself, which is what keeps that state single-writer.
func (s *Session) readLoop(ctx context.Context) {
	limiter := newRateLimiter(s.cfg.ClientMsgPerSec)
	for {
		if ctx.Err() != nil {
			return
		}
		data, err := s.conn.ReadMessage(ctx)
		if err != nil {
			if !errors.Is(err, context.Canceled) {
				s.closeReason.Store(classifyReadError(err))
			}
			s.Drop("read_error")
			return
		}
		s.messagesReceived.Add(1)

		if !limiter.allow(s.cfg.Clock.Now()) {
			s.registryInc(observability.CounterRateLimitedTotal)
			s.recordProtocolEvent(observability.ProtocolRateLimited, "client exceeded the message rate")
			s.sendError(ctx, protocol.NewError(protocol.CodeRateLimited, "too many messages, slow down"))
			continue
		}

		msg, err := protocol.DecodeClientMessage(data)
		if err != nil {
			var perr *protocol.Error
			if errors.As(err, &perr) {
				s.protocolErrors.Add(1)
				s.recordProtocolEvent(kindForCode(perr.Code), perr.Message)
				s.registryInc(counterForCode(perr.Code))
				s.sendError(ctx, perr)
				if perr.Fatal {
					s.closeReason.Store("protocol_fatal:" + perr.Code)
					s.Drop(perr.Code)
					return
				}
				continue
			}
			s.sendError(ctx, protocol.NewError(protocol.CodeMalformedFrame, "%v", err))
			continue
		}
		if msg.Type() == protocol.TypePing {
			// Pongs take the fast path: they are the RTT measurement, so they must
			// not queue behind chart updates.
			s.sendPong(ctx, msg.(protocol.Ping))
			continue
		}

		select {
		case s.commands <- msg:
		case <-ctx.Done():
			return
		default:
			// A full command queue means the client is flooding; drop the command
			// rather than stalling the reader.
			s.recordProtocolEvent(observability.ProtocolRateLimited, "command queue full")
		}
	}
}

// writeLoop is the only goroutine that writes to the socket.
func (s *Session) writeLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case msg := <-s.outbound:
			if err := s.writeWithFaults(ctx, msg); err != nil {
				s.writeFails.Add(1)
				s.registryInc(observability.CounterSlowConsumersTotal)
				s.recordProtocolEvent(observability.ProtocolSlowConsumer, err.Error())
				s.closeReason.Store("slow_consumer")
				s.Drop("slow_consumer")
				return
			}
			s.writeFails.Store(0)
		}
	}
}

func (s *Session) writeWithFaults(ctx context.Context, msg outbound) error {
	faults := s.currentFaults()

	if faults.HoldWrites > 0 {
		s.faultsMu.Lock()
		s.faults.HoldWrites = 0
		s.faultsMu.Unlock()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(faults.HoldWrites):
		}
	}
	if faults.WriteDelay > 0 || faults.WriteJitter > 0 {
		delay := faults.WriteDelay
		if faults.WriteJitter > 0 {
			delay += time.Duration(s.rng.Int64N(int64(faults.WriteJitter)))
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
	if faults.MalformedFrames > 0 {
		s.faultsMu.Lock()
		s.faults.MalformedFrames--
		s.faultsMu.Unlock()
		s.recordFault("malformed_frame", "wrote an invalid frame")
		if err := s.conn.WriteMessage(ctx, []byte("{not json at all")); err != nil {
			return err
		}
	}

	if err := s.conn.WriteMessage(ctx, msg.data); err != nil {
		return err
	}
	s.messagesSent.Add(1)
	s.bytesSent.Add(int64(len(msg.data)))

	switch msg.kind {
	case protocol.TypeCandleUpdate:
		s.window.candleUpdates++
	case protocol.TypeTrade, protocol.TypeTradeBatch:
		s.window.tradeMessages++
	case protocol.TypeOrderBookDelta:
		s.window.bookDeltas++
	case protocol.TypeHealth:
		s.window.healthMessages++
	}
	s.window.bytes += int64(len(msg.data))
	return nil
}

// --- event handling ---------------------------------------------------------

func (s *Session) handleEvent(ctx context.Context, ev market.Event) {
	switch ev.Kind {
	case market.EventBookWindow:
		if ev.Book != nil {
			s.coalescer.OnBookWindow(ev.Book.Epoch, ev.Book.UpdateID, ev.Book.Bids, ev.Book.Asks)
			if s.coalescer.NeedsSnapshot() {
				s.sendSnapshot(ctx)
			}
		}
	case market.EventCandleChanged:
		if ev.Candle != nil && ev.Candle.Interval == s.cfg.Interval {
			s.coalescer.OnCandle(*ev.Candle)
		}
	case market.EventCandleClosed:
		if ev.Candle == nil || ev.Candle.Interval != s.cfg.Interval {
			return
		}
		if s.consumeBoolFault(func(f *FaultConfig) bool {
			if f.SkipCandleClosed {
				f.SkipCandleClosed = false
				return true
			}
			return false
		}) {
			s.recordFault("skip_candle_closed", "suppressed a candle close")
			return
		}
		// A close is never coalesced: a client that misses it cannot finalise the
		// bucket, so it is written immediately even at the minimal tier.
		s.sendCandleClosed(ctx, *ev.Candle)
	case market.EventTrade:
		if ev.Trade != nil && s.cfg.Channels[protocol.ChannelTrades] {
			s.coalescer.OnTrade(*ev.Trade, s.tradeBatchLimit())
		}
	case market.EventMarketStatus:
		if ev.Status != nil {
			s.sendMarketStatus(ctx, *ev.Status)
		}
	}
}

// tradeBatchLimit bounds how many trades are held for one delivery. FULL sends
// every trade, so it holds as many as arrive within its flush interval.
func (s *Session) tradeBatchLimit() int {
	switch s.tierMachine.Tier() {
	case domain.TierFull:
		return 0
	case domain.TierDegraded:
		return 20
	default:
		return 1
	}
}

func (s *Session) flush(ctx context.Context) {
	s.flushBook(ctx)
	s.flushCandles(ctx)
	s.flushTrades(ctx)
}

func (s *Session) flushBook(ctx context.Context) {
	skip := s.faultsInt(func(f *FaultConfig) int {
		n := f.SkipBookDeltas
		f.SkipBookDeltas = 0
		return n
	})
	if skip > 0 {
		sent := s.coalescer.InjectGap()
		s.recordFault("book_gap", fmt.Sprintf("skipped %d update ids", sent))
		s.recordBookEvent(observability.BookEventGapDetected, 0, s.engine.UpdateID(), int64(sent), 0)
		// Fall through: the delta that follows is now discontiguous for this client.
	}

	epoch, first, last, bids, asks, ok := s.coalescer.TakeBookDelta()
	if !ok {
		return
	}
	payload := protocol.DeltaPayloadFrom(s.cfg.Symbol, epoch, first, last, bids, asks)
	frame, err := protocol.Encode(protocol.TypeOrderBookDelta, s.nextSeq(), s.cfg.Clock.Now(), payload)
	if err != nil {
		s.logger().Error(observability.MsgEncodeFailed,
			observability.FieldKind, string(protocol.TypeOrderBookDelta),
			observability.FieldError, err.Error())
		return
	}

	if s.consumeBoolFault(func(f *FaultConfig) bool {
		if f.ReverseDeltas {
			f.ReverseDeltas = false
			return true
		}
		return false
	}) {
		// Hold this delta and send the following one first. The client must treat
		// the older range as stale and ignore it.
		s.heldDelta = frame
		s.recordFault("out_of_order_delta", "held a delta to reverse the pair")
		return
	}
	if s.heldDelta != nil {
		held := s.heldDelta
		s.heldDelta = nil
		s.enqueue(outbound{data: frame, kind: protocol.TypeOrderBookDelta})
		s.enqueue(outbound{data: held, kind: protocol.TypeOrderBookDelta, critical: true})
		s.recordFault("out_of_order_delta", "sent the held delta after its successor")
		return
	}

	if !s.enqueue(outbound{data: frame, kind: protocol.TypeOrderBookDelta, critical: true}) {
		// Book deltas are never dropped. A client that cannot accept one is
		// resynchronised instead, which is the only honest option.
		s.recordBookEvent(observability.BookEventRecoveryStarted, first, last, 0, 0)
		s.requestResync(ctx, "outbound queue full for a book delta")
		return
	}
	s.coalescer.Stats()

	if s.consumeBoolFault(func(f *FaultConfig) bool {
		if f.DuplicateDelta {
			f.DuplicateDelta = false
			return true
		}
		return false
	}) {
		s.recordFault("duplicate_delta", "re-sent the previous delta")
		s.enqueue(outbound{data: frame, kind: protocol.TypeOrderBookDelta, critical: true})
	} else {
		s.lastDelta = frame
	}
}

func (s *Session) flushCandles(ctx context.Context) {
	if !s.cfg.Channels[protocol.ChannelCandles] {
		return
	}
	for {
		candle, ok := s.coalescer.TakeCandle(s.cfg.Interval)
		if !ok {
			return
		}
		payload := protocol.CandleUpdatePayload{
			Symbol:         s.cfg.Symbol.ID,
			Interval:       string(candle.Interval),
			Candle:         protocol.CandlePayloadFrom(s.cfg.Symbol, candle, true),
			SourceSequence: candle.SourceSequence,
			Active:         true,
		}
		frame, err := protocol.Encode(protocol.TypeCandleUpdate, s.nextSeq(), s.cfg.Clock.Now(), payload)
		if err != nil {
			continue
		}
		if !s.enqueue(outbound{data: frame, kind: protocol.TypeCandleUpdate}) {
			// The queue is full: put the newest candle back and try next flush. A
			// chart update is the one message class where losing a frame is fine
			// and losing the newest value is not.
			s.coalescer.OnCandle(candle)
			s.window.suppressed++
			return
		}
	}
}

func (s *Session) flushTrades(ctx context.Context) {
	if !s.cfg.Channels[protocol.ChannelTrades] {
		return
	}
	trades, omitted, ok := s.coalescer.TakeTrades()
	if !ok {
		return
	}

	if s.tierMachine.Tier() == domain.TierFull {
		for i := range trades {
			payload := protocol.TradePayloadFrom(s.cfg.Symbol, trades[i])
			frame, err := protocol.Encode(protocol.TypeTrade, s.nextSeq(), s.cfg.Clock.Now(), payload)
			if err != nil {
				continue
			}
			if !s.enqueue(outbound{data: frame, kind: protocol.TypeTrade}) {
				s.window.suppressed += int64(len(trades) - i)
				return
			}
		}
		return
	}

	// Degraded and minimal clients receive a compacted batch, and the compaction
	// is reported rather than hidden.
	items := make([]protocol.TradePayload, 0, len(trades))
	for i := range trades {
		items = append(items, protocol.TradePayloadFrom(s.cfg.Symbol, trades[i]))
	}
	payload := protocol.TradeBatchPayload{
		Symbol:       s.cfg.Symbol.ID,
		Trades:       items,
		Compacted:    omitted > 0,
		OmittedCount: omitted,
	}
	frame, err := protocol.Encode(protocol.TypeTradeBatch, s.nextSeq(), s.cfg.Clock.Now(), payload)
	if err != nil {
		return
	}
	if !s.enqueue(outbound{data: frame, kind: protocol.TypeTradeBatch}) {
		s.window.suppressed += int64(len(trades))
	}
}

func (s *Session) flushSummary(ctx context.Context) {
	if !s.cfg.Channels[protocol.ChannelSummary] {
		return
	}
	payload := protocol.SummaryPayloadFrom(s.cfg.Symbol, s.engine.Summary())
	frame, err := protocol.Encode(protocol.TypeMarketSummary, s.nextSeq(), s.cfg.Clock.Now(), payload)
	if err != nil {
		return
	}
	s.enqueue(outbound{data: frame, kind: protocol.TypeMarketSummary})
}

// --- commands ---------------------------------------------------------------

func (s *Session) handleCommand(ctx context.Context, msg protocol.ClientMessage) {
	switch m := msg.(type) {
	case protocol.Hello:
		s.cfg.Logger = s.cfg.Logger.With("clientVersion", m.ClientVersion, "platform", m.Platform)
		if s.cfg.OnHello != nil {
			s.cfg.OnHello(m.DeviceID)
		}
		s.logger().Info(observability.MsgClientHello,
			observability.FieldClientVersion, m.ClientVersion,
			observability.FieldPlatform, m.Platform)

	case protocol.Subscribe:
		s.handleSubscribe(ctx, m.Symbol, m.Interval, m.Channels)

	case protocol.Unsubscribe:
		for _, c := range m.Channels {
			delete(s.cfg.Channels, c)
		}
		s.send(ctx, protocol.TypeUnsubscribed, protocol.UnsubscribedPayload{Channels: m.Channels}, false)

	case protocol.SetInterval:
		s.handleSubscribe(ctx, s.cfg.Symbol.ID, m.Interval, nil)

	case protocol.LatencyReport:
		s.handleLatencyReport(ctx, m)

	case protocol.TierOverride:
		s.handleTierOverride(ctx, m)
	}
}

func (s *Session) handleSubscribe(ctx context.Context, symbol, interval string, channels []string) {
	engine, sym, ok := s.resolveMarket(symbol)
	if !ok {
		s.sendError(ctx, protocol.NewError(protocol.CodeUnsupportedSymbol,
			"%s is not a market this server serves", symbol))
		return
	}
	iv, err := domain.ParseInterval(interval)
	if err != nil {
		s.sendError(ctx, protocol.NewError(protocol.CodeUnsupportedInterval,
			"interval %q is not supported", interval))
		return
	}
	if channels != nil {
		next := make(map[string]bool, len(channels))
		for _, c := range channels {
			if !protocol.ValidChannel(c) {
				s.sendError(ctx, protocol.NewError(protocol.CodeUnsupportedChannel, "channel %q is not supported", c))
				return
			}
			next[c] = true
		}
		next[protocol.ChannelHealth] = true
		s.cfg.Channels = next
	}

	previousInterval := s.cfg.Interval
	s.cfg.Interval = iv

	// Subscribing binds the session to the requested market. That is a rebind
	// when it names a different market: the bus subscription moves, the symbol
	// every payload is scaled and labelled with changes, and the coalescer is
	// rebuilt because its book and candles belong to the old market.
	if engine != s.engine {
		s.bindEngine(engine, sym)
	}

	s.logger().Info(observability.MsgWSSubscribe,
		observability.FieldSymbol, sym.ID,
		observability.FieldInterval, string(iv),
		observability.FieldPrevInterval, string(previousInterval),
		observability.FieldChannels, len(s.cfg.Channels),
	)

	// A snapshot always follows a subscription: it is what makes the client's book
	// well defined before any delta arrives.
	s.sendSnapshot(ctx)
	s.send(ctx, protocol.TypeSubscribed, protocol.SubscribedPayload{
		Symbol:   sym.ID,
		Interval: string(iv),
		Channels: channelList(s.cfg.Channels),
		Epoch:    engine.Epoch(),
	}, false)

	// Send the history-derived active candle immediately so a freshly subscribed
	// client draws something without waiting for the next trade.
	if active, ok := engine.ActiveCandle(iv); ok {
		s.sendCandleUpdate(ctx, active)
	}
	s.flushSummary(ctx)
}

// resolveMarket maps a wire symbol id to the engine that serves it.
func (s *Session) resolveMarket(id string) (*market.Engine, domain.Symbol, bool) {
	sym, err := domain.Lookup(id)
	if err != nil {
		return nil, domain.Symbol{}, false
	}
	if s.cfg.Registry != nil {
		engine, ok := s.cfg.Registry.Lookup(sym)
		return engine, sym, ok
	}
	// A session built without a registry serves only the market it is already
	// bound to, which keeps a single-engine embed working.
	if s.engine != nil && s.engine.Symbol().ID == sym.ID {
		return s.engine, sym, true
	}
	return nil, domain.Symbol{}, false
}

// bindEngine points the session at one market.
//
// It is only ever reached from handleCommand, which runs on the delivery loop,
// so the loop remains the single writer of the engine, symbol, coalescer and
// subscription that its select reads.
func (s *Session) bindEngine(engine *market.Engine, sym domain.Symbol) {
	if s.sub != nil && s.engine != nil {
		s.engine.Bus().Unsubscribe(s.sub)
	}
	s.engine = engine
	s.cfg.Symbol = sym
	// The coalescer holds per-market book and candle state; a different market
	// means a different book, so it is rebuilt rather than reused.
	s.coalescer = NewCoalescer(sym)
	s.sub = engine.Subscribe("sess:"+s.cfg.ShortID, s.cfg.OutboundCapacity)
}

func (s *Session) handleLatencyReport(ctx context.Context, m protocol.LatencyReport) {
	now := s.cfg.Clock.Now()
	rep := domain.HealthReport{
		RTTMs: m.RTTMs, JitterMs: m.JitterMs, Samples: m.Samples,
		ClientTimeMs: m.ClientTimeMs, ReceivedAt: now,
	}
	s.health.Ingest(rep)

	band := s.cfg.Policy.Classify(m.RTTMs, m.JitterMs)
	s.recorder().RecordHealthReport(observability.HealthReportRow{
		SessionID:      s.cfg.ID,
		ReceivedAt:     now,
		RTTMs:          m.RTTMs,
		JitterMs:       m.JitterMs,
		AgeSinceLastMs: s.health.Snapshot(now).Age.Milliseconds(),
		Band:           band.String(),
	})
	seq := s.health.Snapshot(now).TotalReports
	s.recorder().RecordLatency(observability.LatencySample{
		SessionID:    s.cfg.ID,
		Seq:          seq,
		RTTMs:        m.RTTMs,
		JitterMs:     m.JitterMs,
		Samples:      m.Samples,
		ClientTimeMs: m.ClientTimeMs,
		ServerTime:   now,
		Capped:       m.Capped > 0,
		MissedPong:   m.MissedPongs > 0,
	})
	s.registryInc(observability.CounterHealthReportsTotal)
	if m.MissedPongs > 0 {
		s.registryAdd(observability.CounterMissedPongsTotal, int64(m.MissedPongs))
		s.recordProtocolEvent(observability.ProtocolMissedPong, fmt.Sprintf("%d missed pongs", m.MissedPongs))
	}

	transition := s.tierMachine.Observe(rep, now)
	if transition.Changed {
		s.onTierChanged(ctx, transition)
	}
}

func (s *Session) handleTierOverride(ctx context.Context, m protocol.TierOverride) {
	if !s.cfg.DebugControls {
		s.sendError(ctx, protocol.NewError(protocol.CodeDebugDisabled, "tier override is disabled on this build"))
		return
	}
	tier, isAuto, err := protocol.ParseTierOrAuto(m.Tier)
	now := s.cfg.Clock.Now()
	var transition domain.TierTransition
	if err != nil {
		s.sendError(ctx, protocol.NewError(protocol.CodeTierOverrideRejected, "%v", err))
		return
	}
	if isAuto {
		transition = s.tierMachine.ClearOverride(now)
	} else {
		transition = s.tierMachine.Force(tier, now)
	}
	s.logger().Info(observability.MsgDebugControl, observability.FieldEvent, "tier_override",
		observability.FieldTier, string(s.tierMachine.Tier()), observability.FieldForce, m.Tier)
	if transition.Changed {
		s.onTierChanged(ctx, transition)
	} else {
		s.sendHealth(ctx)
	}
}

// onTierChanged performs the side effects of a tier transition. It is the single
// place they happen, so a report-driven and a watchdog-driven change behave
// identically.
func (s *Session) onTierChanged(ctx context.Context, transition domain.TierTransition) {
	transition.SessionID = s.cfg.ID
	if o := s.tierMachine.Override(); o != nil {
		transition.Override = string(*o)
	}
	s.recorder().RecordTierTransition(observability.TierTransitionRow{
		SessionID: s.cfg.ID,
		At:        transition.At,
		From:      string(transition.From),
		To:        string(transition.To),
		Reason:    string(transition.Reason),
		RTTMs:     transition.RTTMs,
		JitterMs:  transition.JitterMs,
		Streak:    transition.Streak,
		Override:  transition.Override,
	})
	s.registryInc(observability.CounterTierTransitionsTotal)
	s.registrySetGauge("gauge.tier."+string(transition.To), 1)
	select {
	case s.retune <- struct{}{}:
	default:
	}

	s.logger().Info(observability.MsgTierTransition,
		observability.FieldFromTier, string(transition.From),
		observability.FieldTier, string(transition.To),
		observability.FieldReason, string(transition.Reason),
		observability.FieldStreak, transition.Streak,
		observability.FieldRTTMs, transition.RTTMs,
		observability.FieldJitterMs, transition.JitterMs,
		observability.FieldOverride, transition.Override,
	)
	s.sendHealth(ctx)
}

// --- outbound helpers -------------------------------------------------------

// enqueue hands a frame to the writer. It never blocks on a data frame: a full
// queue means the client cannot keep up with what the tier already permits, and
// the caller decides what that means for its message class.
func (s *Session) enqueue(msg outbound) bool {
	select {
	case s.outbound <- msg:
		return true
	default:
		if msg.critical {
			// Control and book messages get one bounded chance to be delivered.
			select {
			case s.outbound <- msg:
				return true
			case <-time.After(2 * time.Second):
				return false
			}
		}
		s.dropped.Add(1)
		return false
	}
}

func (s *Session) send(ctx context.Context, kind protocol.MessageType, payload any, critical bool) {
	frame, err := protocol.Encode(kind, s.nextSeq(), s.cfg.Clock.Now(), payload)
	if err != nil {
		s.logger().Error(observability.MsgEncodeFailed,
			observability.FieldEvent, string(kind),
			observability.FieldError, err.Error())
		return
	}
	s.enqueue(outbound{data: frame, kind: kind, critical: critical})
}

func (s *Session) sendError(ctx context.Context, perr *protocol.Error) {
	s.protocolErrors.Add(1)
	s.send(ctx, protocol.TypeError, protocol.ErrorPayloadFrom(perr), true)
}

func (s *Session) sendWelcome() error {
	if !s.engine.WarmupComplete() {
		// The welcome frame is still sent: a client that connects during warmup gets
		// a valid, empty market and fills in as history lands, rather than being
		// refused or shown a spinner with no explanation.
		s.logger().Debug(observability.MsgWelcomeBeforeWarmup)
	}
	thresholds := s.cfg.Policy.Thresholds()
	payload := protocol.WelcomePayload{
		SessionID:   s.cfg.ID,
		ShortID:     s.cfg.ShortID,
		Symbol:      s.cfg.Symbol.ID,
		Epoch:       s.engine.Epoch(),
		EngineState: string(s.engine.State()),
		ServerTime:  protocol.FormatTime(s.cfg.Clock.Now()),
		ProtocolMin: protocol.Version,
		ProtocolMax: protocol.Version,
		Intervals:   domain.IntervalIDs(),
		Channels:    protocol.Channels(),
		HeartbeatMs: int(protocol.ClientHeartbeatInterval / time.Millisecond),
		TierRates: map[string]float64{
			string(domain.TierFull):     s.cfg.Policy.TargetRate(domain.TierFull),
			string(domain.TierDegraded): s.cfg.Policy.TargetRate(domain.TierDegraded),
			string(domain.TierMinimal):  s.cfg.Policy.TargetRate(domain.TierMinimal),
		},
		TierThresholds: protocol.TierThresholds{
			FullMaxRTTMs:       thresholds.FullMaxRTTMs,
			FullMaxJitterMs:    thresholds.FullMaxJitterMs,
			MinimalMinRTTMs:    thresholds.MinimalMinRTTMs,
			MinimalMinJitterMs: thresholds.MinimalMinJitterMs,
			DegradeStreak:      thresholds.DegradeStreak,
			RecoverStreak:      thresholds.RecoverStreak,
			ReportHoldMs:       thresholds.ReportHold.Milliseconds(),
			ReportDegradeMs:    thresholds.ReportDegrade.Milliseconds(),
		},
	}
	frame, err := protocol.Encode(protocol.TypeWelcome, s.nextSeq(), s.cfg.Clock.Now(), payload)
	if err != nil {
		return fmt.Errorf("delivery: encode welcome: %w", err)
	}
	if !s.enqueue(outbound{data: frame, kind: protocol.TypeWelcome, critical: true}) {
		return errors.New("delivery: could not queue welcome frame")
	}
	return nil
}

func (s *Session) sendPong(ctx context.Context, ping protocol.Ping) {
	s.send(ctx, protocol.TypePong, protocol.PongPayload{
		ID:           ping.ID,
		ClientTimeMs: ping.ClientTimeMs,
		ServerTimeMs: s.cfg.Clock.Now().UnixMilli(),
	}, true)
}

func (s *Session) sendSnapshot(ctx context.Context) {
	snapshot := s.engine.Book()
	if len(snapshot.Bids) > s.cfg.BookWindow {
		snapshot.Bids = snapshot.Bids[:s.cfg.BookWindow]
	}
	if len(snapshot.Asks) > s.cfg.BookWindow {
		snapshot.Asks = snapshot.Asks[:s.cfg.BookWindow]
	}
	payload := protocol.SnapshotPayloadFrom(s.cfg.Symbol, snapshot)
	started := s.cfg.Clock.Now()
	s.send(ctx, protocol.TypeOrderBookSnapshot, payload, true)
	s.coalescer.SnapshotSent(snapshot.Epoch, snapshot.UpdateID)
	s.recorder().RecordBookEvent(observability.BookSyncEvent{
		At:           started,
		SessionID:    s.cfg.ID,
		Scope:        observability.ScopeSession,
		Event:        observability.BookEventSnapshotApplied,
		Epoch:        snapshot.Epoch,
		FromUpdateID: 0,
		ToUpdateID:   snapshot.UpdateID,
		DurationMs:   s.cfg.Clock.Now().Sub(started).Milliseconds(),
	})
}

// requestResync sends a fresh snapshot and rebases the client's sequence. It is the
// only recovery mechanism on the server side, and it is used when a delta cannot be
// delivered rather than dropping it.
func (s *Session) requestResync(ctx context.Context, reason string) {
	s.recordProtocolEvent(observability.ProtocolSlowConsumer, reason)
	s.coalescer.Reset()
	s.sendSnapshot(ctx)
}

func (s *Session) sendCandleUpdate(ctx context.Context, candle domain.Candle) {
	payload := protocol.CandleUpdatePayload{
		Symbol:         s.cfg.Symbol.ID,
		Interval:       string(candle.Interval),
		Candle:         protocol.CandlePayloadFrom(s.cfg.Symbol, candle, true),
		SourceSequence: candle.SourceSequence,
		Active:         true,
	}
	s.send(ctx, protocol.TypeCandleUpdate, payload, false)
}

func (s *Session) sendCandleClosed(ctx context.Context, candle domain.Candle) {
	payload := protocol.CandleClosedPayload{
		Symbol:   s.cfg.Symbol.ID,
		Interval: string(candle.Interval),
		// A close is final: this payload is the last word on the bucket.
		Candle: protocol.CandlePayloadFrom(s.cfg.Symbol, candle, false),
		Epoch:  s.engine.Epoch(),
	}
	if !s.enqueueCritical(ctx, protocol.TypeCandleClosed, payload) {
		// A close that cannot be delivered is not silently lost: the session is
		// resynchronised so the client rebuilds the series from a snapshot.
		s.recordProtocolEvent(observability.ProtocolSlowConsumer, "candle close could not be delivered")
		s.requestResync(ctx, "candle close undeliverable")
	}
}

func (s *Session) sendMarketStatus(ctx context.Context, status market.MarketStatus) {
	s.send(ctx, protocol.TypeMarketStatus, protocol.MarketStatusPayload{
		State:   string(status.State),
		Epoch:   status.Epoch,
		Message: status.Message,
		At:      protocol.FormatTime(status.At),
	}, true)
}

func (s *Session) sendHealth(ctx context.Context) {
	now := s.cfg.Clock.Now()
	health := s.health.Snapshot(now)
	coalesced, suppressed := s.coalescer.Stats()

	payload := protocol.HealthPayload{
		Tier:                string(s.tierMachine.Tier()),
		Override:            s.Override(),
		Reason:              string(s.tierMachine.Reason()),
		TargetRatePerSec:    s.cfg.Policy.TargetRate(s.tierMachine.Tier()),
		EffectiveRatePerSec: float64(s.lastEffectiveRate.Load()) / 1000,
		RTTMs:               health.RTTMs,
		JitterMs:            health.JitterMs,
		LastReportAgeMs:     health.Age.Milliseconds(),
		UptimeMs:            now.Sub(s.connectedAt).Milliseconds(),
		BookEpoch:           s.engine.Epoch(),
		BookUpdateID:        s.engine.UpdateID(),
		CoalescedCount:      coalesced,
		SuppressedCount:     suppressed,
		QueuedMessages:      len(s.outbound),
		DroppedMessages:     s.dropped.Load(),
	}
	s.send(ctx, protocol.TypeHealth, payload, false)
}

func (s *Session) enqueueCritical(ctx context.Context, kind protocol.MessageType, payload any) bool {
	frame, err := protocol.Encode(kind, s.nextSeq(), s.cfg.Clock.Now(), payload)
	if err != nil {
		return false
	}
	return s.enqueue(outbound{data: frame, kind: kind, critical: true})
}

// recordDeliveryWindow writes one five-second delivery summary. It is what makes
// the difference between the tier's target rate and the rate actually achieved
// observable after the fact.
func (s *Session) recordDeliveryWindow() {
	now := s.cfg.Clock.Now()
	elapsed := now.Sub(s.windowStarted)
	if elapsed <= 0 {
		return
	}
	effective := float64(s.window.candleUpdates) / elapsed.Seconds()
	s.lastEffectiveRate.Store(int64(effective * 1000))

	s.recorder().RecordDeliveryWindow(observability.DeliveryWindow{
		SessionID:      s.cfg.ID,
		WindowStart:    s.windowStarted,
		WindowMs:       elapsed.Milliseconds(),
		Tier:           string(s.tierMachine.Tier()),
		TargetRate:     s.cfg.Policy.TargetRate(s.tierMachine.Tier()),
		EffectiveRate:  effective,
		CandleUpdates:  s.window.candleUpdates,
		TradeMessages:  s.window.tradeMessages,
		BookDeltas:     s.window.bookDeltas,
		HealthMessages: s.window.healthMessages,
		Coalesced:      s.window.coalesced,
		Suppressed:     s.window.suppressed,
		BytesSent:      s.window.bytes,
	})

	s.window = deliveryWindow{tier: s.tierMachine.Tier()}
	s.windowStarted = now
}

// --- session record, metrics helpers ---------------------------------------

func (s *Session) recordSessionStart() {
	s.recorder().RecordSessionStart(observability.SessionRow{
		SessionID:    s.cfg.ID,
		RemoteAddr:   s.conn.RemoteAddr(),
		Symbol:       s.cfg.Symbol.ID,
		Interval:     string(s.cfg.Interval),
		ConnectedAt:  s.connectedAt,
		InitialTier:  string(s.tierMachine.Tier()),
		MessagesSent: 0,
	})
}

func (s *Session) recordSessionEnd(reason string) {
	now := s.cfg.Clock.Now()
	sent, received, bytesSent, protocolErrors := s.Stats()
	disconnected := now
	s.recorder().RecordSessionEnd(observability.SessionRow{
		SessionID:        s.cfg.ID,
		RemoteAddr:       s.conn.RemoteAddr(),
		Symbol:           s.cfg.Symbol.ID,
		Interval:         string(s.cfg.Interval),
		ConnectedAt:      s.connectedAt,
		DisconnectedAt:   &disconnected,
		DisconnectReason: reason,
		FinalTier:        string(s.tierMachine.Tier()),
		OverrideTier:     s.Override(),
		UptimeMs:         now.Sub(s.connectedAt).Milliseconds(),
		MessagesSent:     sent,
		MessagesReceived: received,
		BytesSent:        bytesSent,
		ProtocolErrors:   protocolErrors,
	})
}

func (s *Session) recordBookEvent(event string, from, to uint64, gapSize, attempt int64) {
	s.recorder().RecordBookEvent(observability.BookSyncEvent{
		At:           s.cfg.Clock.Now(),
		SessionID:    s.cfg.ID,
		Scope:        observability.ScopeSession,
		Event:        event,
		Epoch:        s.engine.Epoch(),
		FromUpdateID: from,
		ToUpdateID:   to,
		GapSize:      gapSize,
		Attempt:      int(attempt),
	})
}

func (s *Session) recordProtocolEvent(kind, detail string) {
	s.recorder().RecordProtocolEvent(observability.ProtocolEvent{
		At:        s.cfg.Clock.Now(),
		SessionID: s.cfg.ID,
		Kind:      kind,
		Detail:    detail,
		Count:     1,
	})
}

func (s *Session) recordFault(fault, detail string) {
	s.recorder().RecordFaultInjection(observability.FaultInjectionRow{
		At:         s.cfg.Clock.Now(),
		SessionID:  s.cfg.ID,
		Fault:      fault,
		Parameters: detail,
		Applied:    true,
	})
}

func (s *Session) logger() *observability.Logger {
	if s.cfg.Logger == nil {
		return observability.New("info", "dev", false, nil).
			Component(observability.ComponentSession).
			Session(s.cfg.ID, s.cfg.ShortID)
	}
	return s.cfg.Logger.Component(observability.ComponentSession).Session(s.cfg.ID, s.cfg.ShortID)
}

func (s *Session) recorder() Recorder {
	if s.cfg.Recorder == nil {
		return nopRecorder{}
	}
	return s.cfg.Recorder
}

func (s *Session) registryInc(name string) {
	if s.cfg.MetricsRegistry != nil {
		s.cfg.MetricsRegistry.Inc(name)
	}
}

func (s *Session) registryAdd(name string, n int64) {
	if s.cfg.MetricsRegistry != nil {
		s.cfg.MetricsRegistry.Add(name, n)
	}
}

func (s *Session) registryDec(name string) {
	if s.cfg.MetricsRegistry != nil {
		s.cfg.MetricsRegistry.Add(name, -1)
	}
}

func (s *Session) registrySetGauge(name string, v int64) {
	if s.cfg.MetricsRegistry != nil {
		s.cfg.MetricsRegistry.SetGauge(name, v)
	}
}

func (s *Session) nextSeq() uint64 { return s.lastSeq.Add(1) }

// consumeBoolFault pops a one-shot boolean fault under the fault lock.
func (s *Session) consumeBoolFault(pop func(*FaultConfig) bool) bool {
	s.faultsMu.Lock()
	defer s.faultsMu.Unlock()
	return pop(&s.faults)
}

// faultsInt pops a one-shot integer fault under the fault lock.
func (s *Session) faultsInt(pop func(*FaultConfig) int) int {
	s.faultsMu.Lock()
	defer s.faultsMu.Unlock()
	return pop(&s.faults)
}

func channelList(channels map[string]bool) []string {
	out := make([]string, 0, len(channels))
	for _, c := range protocol.Channels() {
		if channels[c] {
			out = append(out, c)
		}
	}
	return out
}

func kindForCode(code string) string {
	switch code {
	case protocol.CodeMalformedFrame:
		return observability.ProtocolMalformedFrame
	case protocol.CodeUnknownMessageType:
		return observability.ProtocolUnknownType
	case protocol.CodeRateLimited:
		return observability.ProtocolRateLimited
	default:
		return observability.ProtocolValidationFailed
	}
}

func counterForCode(code string) string {
	switch code {
	case protocol.CodeMalformedFrame:
		return observability.CounterMalformedMessages
	case protocol.CodeUnknownMessageType:
		return observability.CounterUnknownMessages
	case protocol.CodeRateLimited:
		return observability.CounterRateLimitedTotal
	default:
		return observability.CounterValidationFailures
	}
}

func classifyReadError(err error) string {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "read_timeout"
	case errors.Is(err, context.Canceled):
		return "context_canceled"
	default:
		return "read_error"
	}
}

// nopRecorder keeps a session usable when metrics are disabled.
type nopRecorder struct{}

func (nopRecorder) RecordLatency(observability.LatencySample)            {}
func (nopRecorder) RecordHealthReport(observability.HealthReportRow)     {}
func (nopRecorder) RecordTierTransition(observability.TierTransitionRow) {}
func (nopRecorder) RecordDeliveryWindow(observability.DeliveryWindow)    {}
func (nopRecorder) RecordBookEvent(observability.BookSyncEvent)          {}
func (nopRecorder) RecordProtocolEvent(observability.ProtocolEvent)      {}
func (nopRecorder) RecordSessionStart(observability.SessionRow)          {}
func (nopRecorder) RecordSessionEnd(observability.SessionRow)            {}
func (nopRecorder) RecordFaultInjection(observability.FaultInjectionRow) {}

// rateLimiter is a fixed-window counter for client messages. The window is one
// second, which is coarse enough to be cheap and fine enough to stop a flood.
type rateLimiter struct {
	limit  int
	window time.Time
	count  int
}

func newRateLimiter(limit int) *rateLimiter {
	return &rateLimiter{limit: limit}
}

func (r *rateLimiter) allow(now time.Time) bool {
	if r.window.IsZero() || now.Sub(r.window) >= time.Second {
		r.window = now
		r.count = 0
	}
	r.count++
	return r.count <= r.limit
}
