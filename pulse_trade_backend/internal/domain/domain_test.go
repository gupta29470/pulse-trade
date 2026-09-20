package domain_test

import (
	"errors"
	"testing"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

func TestParseAndFormatScaledRoundTrip(t *testing.T) {
	t.Parallel()
	sym := domain.BTCUSDT
	cases := []struct {
		in     string
		price  domain.Price
		pretty string // canonical rendering: always fixed decimal places
	}{
		{"67421.35", 6742135, "67421.35"},
		{"0.01", 1, "0.01"},
		{"0", 0, "0.00"},
		{"100000.00", 10000000, "100000.00"},
		{"67421.30", 6742130, "67421.30"},
		{"+67421.35", 6742135, "67421.35"},
	}
	for _, tc := range cases {
		t.Run(tc.in, func(t *testing.T) {
			got, err := sym.ParsePrice(tc.in)
			if err != nil {
				t.Fatalf("ParsePrice(%q): %v", tc.in, err)
			}
			if got != tc.price {
				t.Fatalf("ParsePrice(%q) = %d, want %d", tc.in, got, tc.price)
			}
			if formatted := sym.FormatPrice(got); formatted != tc.pretty {
				t.Fatalf("FormatPrice(%d) = %q, want %q", got, formatted, tc.pretty)
			}
		})
	}
}

func TestParseScaledRejectsExcessPrecision(t *testing.T) {
	t.Parallel()
	sym := domain.BTCUSDT
	// 1e-3 is more precision than a 2-decimal symbol allows.
	if _, err := sym.ParsePrice("67421.345"); !errors.Is(err, domain.ErrInexactValue) {
		t.Fatalf("want ErrInexactValue, got %v", err)
	}
	// Trailing zeros beyond the scale are still exactly representable.
	got, err := sym.ParsePrice("67421.3500")
	if err != nil {
		t.Fatalf("trailing zeros should parse: %v", err)
	}
	if got != 6742135 {
		t.Fatalf("got %d, want 6742135", got)
	}
}

func TestParseScaledRejectsMalformed(t *testing.T) {
	t.Parallel()
	for _, in := range []string{"", "  ", "abc", "1.2.3", "1e5", "1,000.00", "--1"} {
		if _, err := domain.BTCUSDT.ParsePrice(in); err == nil {
			t.Fatalf("ParsePrice(%q) unexpectedly succeeded", in)
		}
	}
}

func TestQtyHasEightDecimals(t *testing.T) {
	t.Parallel()
	q, err := domain.BTCUSDT.ParseQty("0.18400000")
	if err != nil {
		t.Fatalf("ParseQty: %v", err)
	}
	if q != 18_400_000 {
		t.Fatalf("got %d, want 18400000", q)
	}
	if got := domain.BTCUSDT.FormatQty(q); got != "0.18400000" {
		t.Fatalf("FormatQty = %q", got)
	}
	if _, err := domain.BTCUSDT.ParseQty("0.000000001"); !errors.Is(err, domain.ErrInexactValue) {
		t.Fatalf("want ErrInexactValue for sub-step quantity, got %v", err)
	}
}

func TestMulDiv(t *testing.T) {
	t.Parallel()
	cases := []struct {
		a, b, c int64
		want    int64
	}{
		{10, 10, 2, 50},
		{-10, 10, 2, -50},
		{10, -10, 2, -50},
		{-10, -10, 2, 50},
		{10, 10, -2, -50},
		{7, 3, 2, 10}, // truncated toward zero
		{1 << 40, 1 << 20, 1 << 10, 1 << 50},
	}
	for _, tc := range cases {
		got, err := domain.MulDiv(tc.a, tc.b, tc.c)
		if err != nil {
			t.Fatalf("MulDiv(%d,%d,%d): %v", tc.a, tc.b, tc.c, err)
		}
		if got != tc.want {
			t.Fatalf("MulDiv(%d,%d,%d) = %d, want %d", tc.a, tc.b, tc.c, got, tc.want)
		}
	}
	if _, err := domain.MulDiv(1, 1, 0); !errors.Is(err, domain.ErrDivideByZero) {
		t.Fatalf("want ErrDivideByZero, got %v", err)
	}
	if _, err := domain.MulDiv(1<<62, 1<<10, 1); !errors.Is(err, domain.ErrOverflow) {
		t.Fatalf("want ErrOverflow, got %v", err)
	}
}

func TestChangeBasisPoints(t *testing.T) {
	t.Parallel()
	bp, err := domain.ChangeBasisPoints(67395_20, 67421_35)
	if err != nil {
		t.Fatalf("ChangeBasisPoints: %v", err)
	}
	// (67421.35-67395.20)/67395.20 = 0.0388% => ~3.88 bp, integer truncation to 3.
	if bp < 3 || bp > 4 {
		t.Fatalf("got %d bp, want 3 or 4", bp)
	}
	down, err := domain.ChangeBasisPoints(10000, 9900)
	if err != nil {
		t.Fatalf("ChangeBasisPoints: %v", err)
	}
	if down != -100 {
		t.Fatalf("got %d bp, want -100", down)
	}
	if _, err := domain.ChangeBasisPoints(0, 1); !errors.Is(err, domain.ErrDivideByZero) {
		t.Fatalf("want ErrDivideByZero, got %v", err)
	}
}

func TestIntervalBucketingAlignsToUTC(t *testing.T) {
	t.Parallel()
	ts := time.Date(2026, 9, 17, 12, 41, 3, 235_000_000, time.UTC)
	if got := domain.Interval1m.BucketStart(ts); !got.Equal(time.Date(2026, 9, 17, 12, 41, 0, 0, time.UTC)) {
		t.Fatalf("1m bucket = %s", got)
	}
	if got := domain.Interval5m.BucketStart(ts); !got.Equal(time.Date(2026, 9, 17, 12, 40, 0, 0, time.UTC)) {
		t.Fatalf("5m bucket = %s", got)
	}
	if got := domain.Interval1h.BucketStart(ts); !got.Equal(time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)) {
		t.Fatalf("1h bucket = %s", got)
	}
	if got := domain.Interval1D.BucketStart(ts); !got.Equal(time.Date(2026, 9, 17, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("1D bucket = %s", got)
	}
	// A trade exactly on the boundary opens the next bucket.
	onBoundary := time.Date(2026, 9, 17, 12, 42, 0, 0, time.UTC)
	if got := domain.Interval1m.BucketStart(onBoundary); !got.Equal(onBoundary) {
		t.Fatalf("boundary bucket = %s, want %s", got, onBoundary)
	}
}

func TestParseInterval(t *testing.T) {
	t.Parallel()
	for _, id := range domain.IntervalIDs() {
		if _, err := domain.ParseInterval(id); err != nil {
			t.Fatalf("ParseInterval(%q): %v", id, err)
		}
	}
	if _, err := domain.ParseInterval("3m"); !errors.Is(err, domain.ErrUnsupportedInterval) {
		t.Fatalf("want ErrUnsupportedInterval, got %v", err)
	}
	if len(domain.Intervals()) != 6 {
		t.Fatalf("expected 6 intervals, got %d", len(domain.Intervals()))
	}
}

func TestCandleApplyAndValidate(t *testing.T) {
	t.Parallel()
	base := time.Date(2026, 9, 17, 12, 41, 0, 0, time.UTC)
	mk := func(id uint64, sec int, price domain.Price, qty domain.Qty) domain.Trade {
		return domain.Trade{
			ID: id, Symbol: "BTCUSDT",
			Timestamp: base.Add(time.Duration(sec) * time.Second),
			Price:     price, Quantity: qty, Side: domain.SideBuy,
		}
	}
	c := domain.NewCandle("BTCUSDT", domain.Interval1m, mk(1, 0, 100, 5))
	c.Apply(mk(2, 10, 130, 3))
	c.Apply(mk(3, 20, 90, 2))
	c.Apply(mk(4, 30, 110, 7))

	if err := c.Validate(); err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if c.Open != 100 || c.High != 130 || c.Low != 90 || c.Close != 110 {
		t.Fatalf("OHLC = %d/%d/%d/%d", c.Open, c.High, c.Low, c.Close)
	}
	if c.Volume != 17 {
		t.Fatalf("volume = %d, want 17", c.Volume)
	}
	if c.TradeCount != 4 {
		t.Fatalf("tradeCount = %d, want 4", c.TradeCount)
	}
	if c.SourceSequence != 4 {
		t.Fatalf("sourceSequence = %d, want 4", c.SourceSequence)
	}
}

func TestCandleValidateRejectsBrokenBucket(t *testing.T) {
	t.Parallel()
	c := domain.Candle{
		Symbol: "BTCUSDT", Interval: domain.Interval1m,
		StartTime: time.Date(2026, 9, 17, 12, 41, 0, 0, time.UTC),
		Open:      100, High: 90, Low: 95, Close: 100,
		Volume: 1, TradeCount: 1, SourceSequence: 1,
	}
	if err := c.Validate(); !errors.Is(err, domain.ErrCandleInvariant) {
		t.Fatalf("want ErrCandleInvariant, got %v", err)
	}
}

func TestOrderBookSnapshotValidate(t *testing.T) {
	t.Parallel()
	good := domain.OrderBookSnapshot{
		Symbol: "BTCUSDT", Epoch: 1, UpdateID: 10,
		Bids: []domain.Level{{Price: 100, Quantity: 1}, {Price: 99, Quantity: 1}},
		Asks: []domain.Level{{Price: 101, Quantity: 1}, {Price: 102, Quantity: 1}},
	}
	if err := good.Validate(); err != nil {
		t.Fatalf("valid snapshot rejected: %v", err)
	}
	spread, ok := good.Spread()
	if !ok || spread != 1 {
		t.Fatalf("spread = %d ok=%v, want 1 true", spread, ok)
	}

	crossed := good
	crossed.Bids = []domain.Level{{Price: 102, Quantity: 1}}
	if err := crossed.Validate(); !errors.Is(err, domain.ErrCrossedBook) {
		t.Fatalf("want ErrCrossedBook, got %v", err)
	}

	empty := good
	empty.Asks = nil
	if err := empty.Validate(); !errors.Is(err, domain.ErrEmptyBook) {
		t.Fatalf("want ErrEmptyBook, got %v", err)
	}

	unsorted := good
	unsorted.Bids = []domain.Level{{Price: 99, Quantity: 1}, {Price: 100, Quantity: 1}}
	if err := unsorted.Validate(); !errors.Is(err, domain.ErrCrossedBook) {
		t.Fatalf("want ordering failure, got %v", err)
	}
}

func TestSymbolLookup(t *testing.T) {
	t.Parallel()
	if _, err := domain.Lookup("BTCUSDT"); err != nil {
		t.Fatalf("Lookup(BTCUSDT): %v", err)
	}
	if _, err := domain.Lookup("NOPE"); !errors.Is(err, domain.ErrSymbolNotFound) {
		t.Fatalf("want ErrSymbolNotFound, got %v", err)
	}
	// Every roster market is live and carries the seed a synthetic feed anchors to.
	seen := map[domain.Price]string{}
	for _, s := range domain.AllSymbols() {
		if !s.Live {
			t.Fatalf("%s must be live", s.ID)
		}
		seed, ok := domain.SeedPrice(s.ID)
		if !ok {
			t.Fatalf("%s has no seed price", s.ID)
		}
		if seed <= 0 {
			t.Fatalf("%s seed price = %d, want positive", s.ID, seed)
		}
		if previous, ok := seen[seed]; ok {
			t.Fatalf("%s and %s share the seed price %d", previous, s.ID, seed)
		}
		seen[seed] = s.ID
	}
	if len(seen) != len(domain.AllSymbols()) {
		t.Fatalf("seed prices cover %d symbols, want %d", len(seen), len(domain.AllSymbols()))
	}
}

func TestDerivedSeedIsStableAndMarketSpecific(t *testing.T) {
	t.Parallel()
	const base = int64(20260917)
	bySeed := map[int64]string{}
	for _, s := range domain.AllSymbols() {
		got := domain.DerivedSeed(base, s.ID)
		if again := domain.DerivedSeed(base, s.ID); again != got {
			t.Fatalf("%s derived seed is not stable: %d then %d", s.ID, got, again)
		}
		if got == base {
			t.Fatalf("%s derived seed equals the base seed", s.ID)
		}
		if previous, ok := bySeed[got]; ok {
			t.Fatalf("%s and %s share derived seed %d", previous, s.ID, got)
		}
		bySeed[got] = s.ID
	}
	if other := domain.DerivedSeed(base+1, domain.BTCUSDT.ID); other == domain.DerivedSeed(base, domain.BTCUSDT.ID) {
		t.Fatal("changing the base seed did not change the derived seed")
	}
}
