package domain

import "time"

// Clock is the single source of time in the backend. Everything that needs time
// takes a Clock, which is what makes bucketing, hysteresis streaks, report age
// and summary expiry testable without sleeping.
type Clock interface {
	Now() time.Time
}

type systemClock struct{}

// SystemClock returns a clock backed by time.Now, normalised to UTC.
func SystemClock() Clock { return systemClock{} }

func (systemClock) Now() time.Time { return time.Now().UTC() }

// EqualLevels reports whether two level slices carry identical prices and
// quantities in the same order. Used by tests and by the coalescing equivalence
// check, which must compare books exactly.
func EqualLevels(a, b []Level) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// EqualTrades reports whether two trades carry identical values.
func EqualTrades(a, b Trade) bool {
	return a.ID == b.ID &&
		a.Symbol == b.Symbol &&
		a.Timestamp.Equal(b.Timestamp) &&
		a.Price == b.Price &&
		a.Quantity == b.Quantity &&
		a.Side == b.Side
}
