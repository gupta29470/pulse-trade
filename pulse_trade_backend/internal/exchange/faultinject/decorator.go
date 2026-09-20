// Package faultinject wraps a MarketDataProvider and deliberately corrupts the
// event stream. It exists so that recovery paths can be demonstrated and tested
// against the real engine rather than against a mock: the decorator satisfies the
// same contract, so everything above it is byte-identical with faults enabled.
package faultinject

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange"
)

// Kind enumerates the event-level faults the decorator can apply. Wire-level
// faults (malformed frames, stale snapshots, slow consumers) are injected per
// session in the delivery layer instead, because they are properties of a
// connection rather than of the market.
type Kind string

const (
	// SkipBookDelta drops book-delta events, producing a sequence gap.
	SkipBookDelta Kind = "skip_book_delta"
	// DuplicateLast re-emits the previous event.
	DuplicateLast Kind = "duplicate_last"
	// ReversePair swaps the next two events, producing an out-of-order arrival.
	ReversePair Kind = "reverse_pair"
	// DelayTrade holds a trade for a given duration before emitting it.
	DelayTrade Kind = "delay_trade"
	// DropTrade removes trade events entirely, simulating upstream loss.
	DropTrade Kind = "drop_trade"
)

// Fault is one scheduled anomaly.
type Fault struct {
	Kind Kind `json:"kind"`
	// After is the number of events to pass through before the fault applies.
	After int `json:"after"`
	// Count is how many events the fault affects.
	Count int `json:"count"`
	// Delay is used by DelayTrade.
	Delay time.Duration `json:"delayMs"`
}

// Schedule is an ordered list of faults.
type Schedule struct {
	Faults []Fault `json:"faults"`
}

// Apply records that a fault was applied, for the audit trail.
type Apply struct {
	Kind      Kind
	At        time.Time
	EventType exchange.EventType
	Detail    string
}

// Observer is notified whenever a fault is applied. The metrics recorder
// implements it; tests can pass a collector.
type Observer interface {
	FaultApplied(Apply)
}

// Decorator wraps a provider.
type Decorator struct {
	inner    exchange.MarketDataProvider
	schedule Schedule
	observer Observer
	clock    domain.Clock

	mu      sync.Mutex
	seen    int
	applied []Apply
	pending []exchange.MarketEvent
}

var _ exchange.MarketDataProvider = (*Decorator)(nil)
var _ exchange.PaceController = (*Decorator)(nil)

// New wraps a provider. A nil observer and clock are both tolerated.
func New(inner exchange.MarketDataProvider, schedule Schedule, observer Observer, clock domain.Clock) *Decorator {
	if clock == nil {
		clock = domain.SystemClock()
	}
	return &Decorator{inner: inner, schedule: schedule, observer: observer, clock: clock}
}

// Inner returns the wrapped provider, so pace and debug controls can still reach it.
func (d *Decorator) Inner() exchange.MarketDataProvider { return d.inner }

// SetPace forwards to the inner provider when it supports pacing.
func (d *Decorator) SetPace(pace exchange.Pace) {
	if pc, ok := d.inner.(exchange.PaceController); ok {
		pc.SetPace(pace)
	}
}

// Pace reports the inner provider's pacing mode.
func (d *Decorator) Pace() exchange.Pace {
	if pc, ok := d.inner.(exchange.PaceController); ok {
		return pc.Pace()
	}
	return exchange.PaceRealtime
}

// Applied returns the faults applied so far.
func (d *Decorator) Applied() []Apply {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]Apply(nil), d.applied...)
}

// Snapshot passes through unchanged: the bootstrap book is not a fault target.
func (d *Decorator) Snapshot(ctx context.Context, symbol string) (domain.OrderBookSnapshot, error) {
	return d.inner.Snapshot(ctx, symbol)
}

// Stream wraps the inner stream and applies the schedule.
func (d *Decorator) Stream(ctx context.Context, symbol string) (<-chan exchange.MarketEvent, error) {
	src, err := d.inner.Stream(ctx, symbol)
	if err != nil {
		return nil, err
	}

	out := make(chan exchange.MarketEvent, 64)
	go func() {
		defer close(out)
		var last exchange.MarketEvent
		for {
			ev, ok := d.next(ctx, src)
			if !ok {
				return
			}
			if ev == nil {
				continue
			}

			faults := d.faultsFor(d.advance())

			emit := func(e exchange.MarketEvent) bool {
				if e == nil {
					return true
				}
				select {
				case <-ctx.Done():
					return false
				case out <- e:
					return true
				}
			}

			skip := false
			for _, f := range faults {
				switch f.Kind {
				case SkipBookDelta:
					if ev.EventType() == exchange.EventBookDelta {
						d.note(f, ev, "dropped book delta")
						skip = true
					}
				case DropTrade:
					if ev.EventType() == exchange.EventTrade {
						d.note(f, ev, "dropped trade")
						skip = true
					}
				case DuplicateLast:
					if last != nil {
						d.note(f, last, "re-emitted previous event")
						if !emit(last) {
							return
						}
					}
				case ReversePair:
					next, ok := d.next(ctx, src)
					if !ok {
						return
					}
					d.note(f, ev, "reversed a pair of events")
					if !emit(next) || !emit(ev) {
						return
					}
					last = ev
					continue
				case DelayTrade:
					if ev.EventType() == exchange.EventTrade {
						d.note(f, ev, fmt.Sprintf("delayed %s", f.Delay))
						select {
						case <-ctx.Done():
							return
						case <-time.After(f.Delay):
						}
					}
				}
			}
			if skip {
				continue
			}
			if !emit(ev) {
				return
			}
			last = ev
		}
	}()
	return out, nil
}

// next pulls one event from the source, draining anything the decorator held back.
func (d *Decorator) next(ctx context.Context, src <-chan exchange.MarketEvent) (exchange.MarketEvent, bool) {
	d.mu.Lock()
	if len(d.pending) > 0 {
		ev := d.pending[0]
		d.pending = d.pending[1:]
		d.mu.Unlock()
		return ev, true
	}
	d.mu.Unlock()

	select {
	case <-ctx.Done():
		return nil, false
	case ev, ok := <-src:
		if !ok {
			return nil, false
		}
		return ev, true
	}
}

func (d *Decorator) advance() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.seen++
	return d.seen
}

func (d *Decorator) faultsFor(seen int) []Fault {
	var out []Fault
	for _, f := range d.schedule.Faults {
		count := f.Count
		if count <= 0 {
			count = 1
		}
		if seen > f.After && seen <= f.After+count {
			out = append(out, f)
		}
	}
	return out
}

func (d *Decorator) note(f Fault, ev exchange.MarketEvent, detail string) {
	apply := Apply{
		Kind:      f.Kind,
		At:        d.clock.Now(),
		EventType: ev.EventType(),
		Detail:    detail,
	}
	d.mu.Lock()
	d.applied = append(d.applied, apply)
	d.mu.Unlock()
	if d.observer != nil {
		d.observer.FaultApplied(apply)
	}
}
