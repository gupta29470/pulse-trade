package metrics

import (
	"sync"

	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// record is one queued metric. A tagged struct is used instead of an interface so
// enqueueing is a struct copy with no allocation and no method dispatch — this
// path runs on the market tick loop and on every session's delivery loop.
type record struct {
	latency  *observability.LatencySample
	health   *observability.HealthReportRow
	tier     *observability.TierTransitionRow
	delivery *observability.DeliveryWindow
	book     *observability.BookSyncEvent
	protocol *observability.ProtocolEvent
	session  *SessionWrite
	engine   *observability.EngineEvent
	candle   *CandleCloseRow
	fault    *observability.FaultInjectionRow
}

// toBatch converts an ordered run of records into the per-table batch a driver
// writes. Ordering within each record type is preserved, and grouping by table
// means a session row and the latency samples that reference it travel in the
// same transaction.
func toBatch(records []record) Batch {
	var b Batch
	for _, r := range records {
		switch {
		case r.latency != nil:
			b.Latency = append(b.Latency, *r.latency)
		case r.health != nil:
			b.Health = append(b.Health, *r.health)
		case r.tier != nil:
			b.Tiers = append(b.Tiers, *r.tier)
		case r.delivery != nil:
			b.Delivery = append(b.Delivery, *r.delivery)
		case r.book != nil:
			b.BookEvents = append(b.BookEvents, *r.book)
		case r.protocol != nil:
			b.Protocol = append(b.Protocol, *r.protocol)
		case r.session != nil:
			b.Sessions = append(b.Sessions, *r.session)
		case r.engine != nil:
			b.EngineEvts = append(b.EngineEvts, *r.engine)
		case r.candle != nil:
			b.CandleClose = append(b.CandleClose, *r.candle)
		case r.fault != nil:
			b.Faults = append(b.Faults, *r.fault)
		}
	}
	return b
}

// recordQueue is a bounded drop-oldest queue with a wake-up signal.
//
// Why not a channel: the store's overflow policy is drop-OLDEST, and a Go channel
// can only reject the newest item. A ring buffer plus a one-slot signal channel
// gives exact drop-oldest semantics while keeping the producer path free of
// blocking sends and free of allocations.
type recordQueue struct {
	mu    sync.Mutex
	buf   []record
	head  int
	count int
	// signal wakes the writer. Capacity one is enough: a pending wake-up already
	// covers any number of records pushed after it.
	signal chan struct{}
}

func newRecordQueue(capacity int) *recordQueue {
	if capacity < 1 {
		capacity = 1
	}
	return &recordQueue{
		buf:    make([]record, capacity),
		signal: make(chan struct{}, 1),
	}
}

// push appends a record. It returns false when the queue was full and the oldest
// record was discarded to make room — the caller counts that loss.
func (q *recordQueue) push(r record) bool {
	q.mu.Lock()
	dropped := false
	if q.count == len(q.buf) {
		// Drop-oldest: the newest record is the most diagnostically valuable, and
		// the oldest has waited longest for a consumer that never came.
		q.buf[q.head] = record{}
		q.head = (q.head + 1) % len(q.buf)
		q.count--
		dropped = true
	}
	q.buf[(q.head+q.count)%len(q.buf)] = r
	q.count++
	q.mu.Unlock()

	select {
	case q.signal <- struct{}{}:
	default:
	}
	return !dropped
}

// Drain removes up to max records in FIFO order. Records are handed back boxed in
// any so a driver package can consume them without being able to construct them;
// ToBatch turns the slice back into a typed batch.
func (q *recordQueue) Drain(max int) []any {
	q.mu.Lock()
	defer q.mu.Unlock()

	if q.count == 0 || max <= 0 {
		return nil
	}
	if max > q.count {
		max = q.count
	}
	out := make([]any, 0, max)
	for i := 0; i < max; i++ {
		out = append(out, q.buf[q.head])
		q.buf[q.head] = record{}
		q.head = (q.head + 1) % len(q.buf)
		q.count--
	}
	return out
}

// Depth reports the current occupancy.
func (q *recordQueue) Depth() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.count
}

// Notify returns the writer's wake-up channel.
func (q *recordQueue) Notify() <-chan struct{} { return q.signal }
