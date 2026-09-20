package domain

import (
	"fmt"
	"time"
)

// Candle is one OHLCV bucket. Only the active candle is mutable; a closed
// candle is immutable, which is what makes cross-tier candle identity provable.
type Candle struct {
	Symbol         string    `json:"symbol"`
	Interval       Interval  `json:"interval"`
	StartTime      time.Time `json:"startTime"`
	Open           Price     `json:"-"`
	High           Price     `json:"-"`
	Low            Price     `json:"-"`
	Close          Price     `json:"-"`
	Volume         Qty       `json:"-"`
	TradeCount     int       `json:"tradeCount"`
	SourceSequence uint64    `json:"sourceSequence"`
}

// NewCandle opens a candle from the first trade in a bucket.
func NewCandle(symbol string, iv Interval, t Trade) Candle {
	return Candle{
		Symbol:         symbol,
		Interval:       iv,
		StartTime:      iv.BucketStart(t.Timestamp),
		Open:           t.Price,
		High:           t.Price,
		Low:            t.Price,
		Close:          t.Price,
		Volume:         t.Quantity,
		TradeCount:     1,
		SourceSequence: t.ID,
	}
}

// Apply folds a trade into the candle. The caller is responsible for having
// established that the trade belongs to this bucket (see CandleAggregator).
func (c *Candle) Apply(t Trade) {
	if t.Price.Cmp(c.High) > 0 {
		c.High = t.Price
	}
	if t.Price.Cmp(c.Low) < 0 {
		c.Low = t.Price
	}
	c.Close = t.Price
	c.Volume = c.Volume.Add(t.Quantity)
	c.TradeCount++
	c.SourceSequence = t.ID
}

// Validate checks the OHLCV invariants. A violation means the aggregation path
// is broken, so it is reported rather than tolerated.
func (c Candle) Validate() error {
	if c.TradeCount <= 0 {
		return fmt.Errorf("%w: tradeCount=%d", ErrCandleInvariant, c.TradeCount)
	}
	if c.Volume.IsNegative() {
		return fmt.Errorf("%w: negative volume", ErrCandleInvariant)
	}
	if c.High.Cmp(MaxPrice(c.Open, c.Close)) < 0 {
		return fmt.Errorf("%w: high %d < max(open,close)", ErrCandleInvariant, c.High)
	}
	if c.Low.Cmp(MinPrice(c.Open, c.Close)) > 0 {
		return fmt.Errorf("%w: low %d > min(open,close)", ErrCandleInvariant, c.Low)
	}
	if c.High.Cmp(c.Low) < 0 {
		return fmt.Errorf("%w: high < low", ErrCandleInvariant)
	}
	if c.StartTime.Location() != time.UTC {
		return fmt.Errorf("%w: candle timestamp is not UTC", ErrCandleInvariant)
	}
	return nil
}

// EqualValue reports whether two candles carry identical market values for the
// same identity. Used by the cross-tier test to prove tier independence.
func (c Candle) EqualValue(o Candle) bool {
	return c.Symbol == o.Symbol &&
		c.Interval == o.Interval &&
		c.StartTime.Equal(o.StartTime) &&
		c.Open == o.Open &&
		c.High == o.High &&
		c.Low == o.Low &&
		c.Close == o.Close &&
		c.Volume == o.Volume
}
