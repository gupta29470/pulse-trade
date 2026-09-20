package domain

import (
	"fmt"
	"time"
)

// Interval identifies a candle timeframe. The set of intervals is data-driven:
// every consumer (REST, WS subscriptions, the aggregator set, the app's interval
// selector) reads it from this registry, so adding an interval is one entry here.
type Interval string

const (
	Interval1m  Interval = "1m"
	Interval5m  Interval = "5m"
	Interval15m Interval = "15m"
	Interval1h  Interval = "1h"
	Interval4h  Interval = "4h"
	Interval1D  Interval = "1D"
)

// IntervalSpec is one registry entry.
type IntervalSpec struct {
	ID           Interval
	Duration     time.Duration
	HistoryDepth int // how many candles the warmup can supply
}

// intervalSpecs keeps available history honest: warmup replays a bounded
// number of events, so longer intervals can supply fewer candles.
var intervalSpecs = []IntervalSpec{
	{ID: Interval1m, Duration: time.Minute, HistoryDepth: 500},
	{ID: Interval5m, Duration: 5 * time.Minute, HistoryDepth: 500},
	{ID: Interval15m, Duration: 15 * time.Minute, HistoryDepth: 500},
	{ID: Interval1h, Duration: time.Hour, HistoryDepth: 500},
	{ID: Interval4h, Duration: 4 * time.Hour, HistoryDepth: 180},
	{ID: Interval1D, Duration: 24 * time.Hour, HistoryDepth: 30},
}

// DefaultIntervals are the two intervals the app highlights by default. They
// are first in the registry, which is how the app identifies them.
var DefaultIntervals = []Interval{Interval1m, Interval5m}

func intervalSpec(id Interval) (IntervalSpec, error) {
	for _, s := range intervalSpecs {
		if s.ID == id {
			return s, nil
		}
	}
	return IntervalSpec{}, fmt.Errorf("%w: %q", ErrUnsupportedInterval, string(id))
}

// ParseInterval validates a wire interval id.
func ParseInterval(id string) (Interval, error) {
	for _, s := range intervalSpecs {
		if string(s.ID) == id {
			return s.ID, nil
		}
	}
	return "", fmt.Errorf("%w: %q", ErrUnsupportedInterval, id)
}

// Intervals returns every supported interval in registry order.
func Intervals() []Interval {
	out := make([]Interval, 0, len(intervalSpecs))
	for _, s := range intervalSpecs {
		out = append(out, s.ID)
	}
	return out
}

// IntervalIDs returns the wire ids, for API responses.
func IntervalIDs() []string {
	out := make([]string, 0, len(intervalSpecs))
	for _, s := range intervalSpecs {
		out = append(out, string(s.ID))
	}
	return out
}

// Valid reports whether an interval is registered.
func (i Interval) Valid() bool {
	_, err := intervalSpec(i)
	return err == nil
}

func (i Interval) String() string { return string(i) }

// Duration returns the bucket width. Panics on an unregistered interval, which
// can only happen if a value was constructed outside this package.
func (i Interval) Duration() time.Duration {
	s, err := intervalSpec(i)
	if err != nil {
		panic(err)
	}
	return s.Duration
}

// HistoryDepth returns how many candles warmup can supply for this interval.
func (i Interval) HistoryDepth() int {
	s, err := intervalSpec(i)
	if err != nil {
		return 0
	}
	return s.HistoryDepth
}

// BucketStart aligns a timestamp to the UTC bucket boundary. This is the single
// bucketing implementation in the system; candle correctness depends on it.
//
// Truncate works on absolute time since the Unix epoch, and every supported
// interval divides evenly into a day, so the result is always a UTC boundary.
func (i Interval) BucketStart(t time.Time) time.Time {
	return t.UTC().Truncate(i.Duration())
}

// BucketEnd returns the first instant of the following bucket.
func (i Interval) BucketEnd(t time.Time) time.Time {
	return i.BucketStart(t).Add(i.Duration())
}

// ExpectedNext returns the bucket that follows the bucket containing t.
func (i Interval) ExpectedNext(t time.Time) time.Time {
	return i.BucketStart(t).Add(i.Duration())
}
