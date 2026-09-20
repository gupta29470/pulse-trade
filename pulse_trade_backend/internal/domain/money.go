// Package domain holds the value types, fixed-point arithmetic, registries and
// error vocabulary that the rest of the backend is built from. It imports
// nothing outside the standard library and never performs I/O.
package domain

import (
	"errors"
	"fmt"
	"math"
	"math/bits"
	"strconv"
	"strings"
)

// Price and Qty are fixed-point integers. The scale is carried by the Symbol
// they belong to (see Symbol.PriceScale/QtyScale) because a value on its own
// cannot know how many decimal places it represents.
//
// Arithmetic on these types is exact: no binary floating point is used anywhere
// in market-state computation. Parse helpers reject excess precision instead of
// rounding, because a silently rounded wire value is worse than a rejected one.
type (
	Price int64
	Qty   int64
)

// Sentinel errors. Callers use errors.Is; the transport layer maps them to wire
// codes so that no wire vocabulary leaks into this package.
var (
	ErrDivideByZero        = errors.New("domain: divide by zero")
	ErrOverflow            = errors.New("domain: fixed-point overflow")
	ErrInexactValue        = errors.New("domain: value has more precision than the symbol allows")
	ErrMalformedNumber     = errors.New("domain: malformed decimal number")
	ErrSymbolNotFound      = errors.New("domain: symbol not found")
	ErrUnsupportedInterval = errors.New("domain: unsupported interval")
	ErrInvalidLimit        = errors.New("domain: invalid limit")
	ErrCrossedBook         = errors.New("domain: best bid is not below best ask")
	ErrEmptyBook           = errors.New("domain: order book has no bids or no asks")
	ErrBookGap             = errors.New("domain: order book update sequence gap")
	ErrStaleUpdate         = errors.New("domain: stale order book update")
	ErrCandleInvariant     = errors.New("domain: candle invariants violated")
	ErrPriceNotTickAligned = errors.New("domain: price is not aligned to the symbol tick")
)

// maxSafeMagnitude bounds the values the engine will accept. Real market
// magnitudes are many orders of magnitude smaller; exceeding this indicates a
// bug rather than a legitimate value, so it is treated as an invariant failure.
const maxSafeMagnitude = int64(1) << 53

// --- Price arithmetic -------------------------------------------------------

func (p Price) Add(o Price) Price { return p + o }
func (p Price) Sub(o Price) Price { return p - o }
func (p Price) Cmp(o Price) int {
	switch {
	case p < o:
		return -1
	case p > o:
		return 1
	default:
		return 0
	}
}
func (p Price) Sign() int {
	switch {
	case p < 0:
		return -1
	case p > 0:
		return 1
	default:
		return 0
	}
}
func (p Price) IsZero() bool { return p == 0 }

func MaxPrice(a, b Price) Price {
	if a > b {
		return a
	}
	return b
}

func MinPrice(a, b Price) Price {
	if a < b {
		return a
	}
	return b
}

// --- Quantity arithmetic ----------------------------------------------------

func (q Qty) Add(o Qty) Qty { return q + o }
func (q Qty) Sub(o Qty) Qty { return q - o }
func (q Qty) Cmp(o Qty) int {
	switch {
	case q < o:
		return -1
	case q > o:
		return 1
	default:
		return 0
	}
}
func (q Qty) IsZero() bool     { return q == 0 }
func (q Qty) IsNegative() bool { return q < 0 }
func (q Qty) IsPositive() bool { return q > 0 }

func MaxQty(a, b Qty) Qty {
	if a > b {
		return a
	}
	return b
}

func MinQty(a, b Qty) Qty {
	if a < b {
		return a
	}
	return b
}

// --- Safe integer helpers ---------------------------------------------------

// absUint64 returns |v| as a uint64 and whether v was negative. It avoids the
// MinInt64 negation overflow that a naive -v would hit.
func absUint64(v int64) (uint64, bool) {
	if v >= 0 {
		return uint64(v), false
	}
	if v == math.MinInt64 {
		return uint64(1) << 63, true
	}
	return uint64(-v), true
}

// MulDiv computes a*b/c with a 128-bit intermediate and reports overflow rather
// than wrapping. It is the only fixed-point operation that can overflow, so it
// is the only one that returns an error. Inputs may be negative; the result is
// truncated toward zero.
func MulDiv(a, b, c int64) (int64, error) {
	if c == 0 {
		return 0, ErrDivideByZero
	}
	ua, aneg := absUint64(a)
	ub, bneg := absUint64(b)
	uc, cneg := absUint64(c)

	hi, lo := bits.Mul64(ua, ub)
	if hi >= uc {
		return 0, ErrOverflow
	}
	q, _ := bits.Div64(hi, lo, uc)

	neg := aneg != bneg
	neg = neg != cneg

	if neg {
		if q > uint64(math.MaxInt64)+1 {
			return 0, ErrOverflow
		}
		if q == uint64(math.MaxInt64)+1 {
			return math.MinInt64, nil
		}
		return -int64(q), nil
	}
	if q > uint64(math.MaxInt64) {
		return 0, ErrOverflow
	}
	return int64(q), nil
}

// ChangeBasisPoints returns (last-open)*10000/open as integer basis points, so
// a 0.21% move is 21. Division happens last, exactly once.
func ChangeBasisPoints(open, last Price) (int64, error) {
	if open == 0 {
		return 0, ErrDivideByZero
	}
	delta := int64(last) - int64(open)
	return MulDiv(delta, 10_000, int64(open))
}

// FormatScaled renders a scaled integer as an exact decimal string with the
// given number of fractional digits.
func FormatScaled(v int64, digits int) string {
	neg := v < 0
	mag, _ := absUint64(v)
	s := strconv.FormatUint(mag, 10)
	if digits <= 0 {
		if neg {
			return "-" + s
		}
		return s
	}
	if len(s) <= digits {
		s = strings.Repeat("0", digits-len(s)+1) + s
	}
	intPart := s[:len(s)-digits]
	fracPart := s[len(s)-digits:]
	out := intPart + "." + fracPart
	if neg {
		return "-" + out
	}
	return out
}

// ParseScaled parses an exact decimal string into a scaled integer. It rejects
// inputs carrying more fractional digits than the scale supports instead of
// rounding them, and rejects exponent notation and thousands separators so a
// malformed upstream value cannot slip through unnoticed.
func ParseScaled(s string, scale int64, digits int) (int64, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, ErrMalformedNumber
	}
	neg := false
	switch s[0] {
	case '-':
		neg = true
		s = s[1:]
	case '+':
		s = s[1:]
	}
	if s == "" {
		return 0, ErrMalformedNumber
	}

	intPart := s
	fracPart := ""
	if dot := strings.IndexByte(s, '.'); dot >= 0 {
		intPart = s[:dot]
		fracPart = s[dot+1:]
	}
	if intPart == "" && fracPart == "" {
		return 0, ErrMalformedNumber
	}
	if len(fracPart) > digits {
		// More precision than the symbol allows. Distinguish "exactly
		// representable but over-specified" (e.g. 1.500 with 2 digits is fine
		// only if trailing zeros) from a genuinely inexact value.
		trimmed := strings.TrimRight(fracPart, "0")
		if len(trimmed) > digits {
			return 0, fmt.Errorf("%w: %q has %d fractional digits, symbol allows %d",
				ErrInexactValue, s, len(trimmed), digits)
		}
		fracPart = fracPart[:digits]
	}
	if intPart == "" {
		intPart = "0"
	}
	for _, r := range intPart {
		if r < '0' || r > '9' {
			return 0, fmt.Errorf("%w: %q", ErrMalformedNumber, s)
		}
	}
	for _, r := range fracPart {
		if r < '0' || r > '9' {
			return 0, fmt.Errorf("%w: %q", ErrMalformedNumber, s)
		}
	}

	fracPadded := fracPart + strings.Repeat("0", digits-len(fracPart))
	whole, err := strconv.ParseInt(intPart, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%w: %q", ErrMalformedNumber, s)
	}
	if whole > maxSafeMagnitude/scale {
		return 0, fmt.Errorf("%w: %q", ErrOverflow, s)
	}
	v := whole * scale
	if fracPadded != "" {
		frac, err := strconv.ParseInt(fracPadded, 10, 64)
		if err != nil {
			return 0, fmt.Errorf("%w: %q", ErrMalformedNumber, s)
		}
		v += frac
	}
	if neg {
		v = -v
	}
	return v, nil
}

// RoundToStep snaps a scaled value to the nearest multiple of step. Used by the
// generator only; wire values are never silently snapped.
func RoundToStep(v, step int64) int64 {
	if step <= 0 {
		return v
	}
	rem := v % step
	if rem == 0 {
		return v
	}
	if rem < 0 {
		rem = -rem
	}
	if rem*2 >= step {
		if v < 0 {
			return v - (step - rem)
		}
		return v + (step - rem)
	}
	if v < 0 {
		return v + rem
	}
	return v - rem
}
