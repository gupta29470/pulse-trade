package market

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

// EventKind discriminates canonical events on the bus.
type EventKind uint8

const (
	EventTrade EventKind = iota + 1
	EventBookWindow
	EventCandleChanged
	EventCandleClosed
	EventMarketStatus
)

func (k EventKind) String() string {
	switch k {
	case EventTrade:
		return "trade"
	case EventBookWindow:
		return "book_window"
	case EventCandleChanged:
		return "candle_changed"
	case EventCandleClosed:
		return "candle_closed"
	case EventMarketStatus:
		return "market_status"
	default:
		return "unknown"
	}
}

// Event is one canonical event. Pointer fields are owned by the publisher and
// must be treated as read-only by subscribers; anything a subscriber keeps must
// be copied first.
type Event struct {
	Kind   EventKind
	Trade  *domain.Trade
	Book   *BookWindow
	Candle *domain.Candle
	Status *MarketStatus
}

// MarketStatus describes the engine's lifecycle state as published to clients.
type MarketStatus struct {
	State   State
	Epoch   uint64
	Message string
	At      time.Time
}

// Subscription is one subscriber's mailbox. Each subscriber drains it on its own
// goroutine; the bus never blocks on a slow consumer.
//
// The data channel is never closed. Closing it would race with the engine, which
// publishes from its own goroutine and may hold a reference to this subscription
// from an in-flight fan-out: a send on a closed channel panics, and taking a lock
// around every send would put the engine behind a slow consumer. Instead, Done is
// closed to signal that the subscription has gone away.
type Subscription struct {
	name      string
	ch        chan Event
	done      chan struct{}
	closeOnce sync.Once
	dropped   atomic.Uint64
}

// Name identifies the subscriber for logs and metrics.
func (s *Subscription) Name() string { return s.name }

// Events returns the receive side of the mailbox.
func (s *Subscription) Events() <-chan Event { return s.ch }

// Done is closed when the subscription is removed. Consumers select on it to stop
// reading, and the bus uses it to avoid waiting on a mailbox nobody will drain.
func (s *Subscription) Done() <-chan struct{} { return s.done }

// Dropped returns how many intermediate events were discarded for this
// subscriber. Dropping is safe because every event carries complete state rather
// than a partial update, so the newest event supersedes the ones it displaced.
func (s *Subscription) Dropped() uint64 { return s.dropped.Load() }

func (s *Subscription) isDone() bool {
	select {
	case <-s.done:
		return true
	default:
		return false
	}
}

func (s *Subscription) close() {
	s.closeOnce.Do(func() { close(s.done) })
}

// Bus fans canonical events out to subscribers.
//
// It holds no business logic: it does not decide tiers, coalesce, or drop
// selectively. Its only policy is that a full mailbox loses the incoming event
// rather than stalling the engine, except for candle closes, which are marked
// critical because a client that misses a close cannot finalise a candle.
type Bus struct {
	mu   sync.RWMutex
	subs map[*Subscription]struct{}
}

// NewBus creates an empty bus.
func NewBus() *Bus {
	return &Bus{subs: make(map[*Subscription]struct{})}
}

// Subscribe registers a subscriber with the given mailbox capacity.
func (b *Bus) Subscribe(name string, capacity int) *Subscription {
	if capacity <= 0 {
		capacity = 64
	}
	sub := &Subscription{name: name, ch: make(chan Event, capacity), done: make(chan struct{})}
	b.mu.Lock()
	b.subs[sub] = struct{}{}
	b.mu.Unlock()
	return sub
}

// Unsubscribe removes a subscriber. It signals the subscriber rather than closing
// the data channel, so an in-flight publish cannot send on a closed channel.
func (b *Bus) Unsubscribe(sub *Subscription) {
	if sub == nil {
		return
	}
	b.mu.Lock()
	delete(b.subs, sub)
	b.mu.Unlock()
	sub.close()
}

// SubscriberCount returns how many subscribers are attached.
func (b *Bus) SubscriberCount() int {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return len(b.subs)
}

// Publish delivers an event to every subscriber without blocking.
//
// It returns the names of subscribers whose mailbox was full, so the caller can
// record the drop. Candle closes and market-status changes are delivered with a
// short blocking send instead: losing them would leave a client unable to
// finalise a candle or learn that the market reset.
func (b *Bus) Publish(ev Event) []string {
	critical := ev.Kind == EventCandleClosed || ev.Kind == EventMarketStatus

	b.mu.RLock()
	subs := make([]*Subscription, 0, len(b.subs))
	for sub := range b.subs {
		subs = append(subs, sub)
	}
	b.mu.RUnlock()

	var dropped []string
	for _, sub := range subs {
		if sub.isDone() {
			continue
		}
		if critical {
			select {
			case sub.ch <- ev:
				continue
			case <-sub.done:
				// The subscriber left between the snapshot and this send.
				continue
			case <-time.After(50 * time.Millisecond):
				// Deliberately not recorded as a plain drop: the caller treats a
				// missed critical event as a reason to resynchronise the session.
				dropped = append(dropped, sub.name+":critical")
				continue
			}
		}
		select {
		case sub.ch <- ev:
		default:
			sub.dropped.Add(1)
			dropped = append(dropped, sub.name)
		}
	}
	return dropped
}

// Close removes every subscriber.
func (b *Bus) Close() {
	b.mu.Lock()
	subs := make([]*Subscription, 0, len(b.subs))
	for sub := range b.subs {
		subs = append(subs, sub)
	}
	b.subs = make(map[*Subscription]struct{})
	b.mu.Unlock()

	for _, sub := range subs {
		sub.close()
	}
}
