package market

import "github.com/pulsetrade/pulse-trade-backend/internal/domain"

// Registry maps every live market to the engine that serves it.
//
// Each engine owns one market and its own bus, so a client is always bound to
// exactly one market at a time: a session, an HTTP request or a debug control
// resolves the engine here and then works with that engine alone.
type Registry struct {
	engines map[string]*Engine
	order   []domain.Symbol
}

// NewRegistry builds a registry over the given engines, keeping the order they
// are passed in. A nil engine is skipped, and a duplicate symbol keeps its first
// engine so a market is never served twice.
func NewRegistry(engines ...*Engine) *Registry {
	r := &Registry{engines: make(map[string]*Engine, len(engines))}
	for _, engine := range engines {
		if engine == nil {
			continue
		}
		id := engine.Symbol().ID
		if _, exists := r.engines[id]; exists {
			continue
		}
		r.engines[id] = engine
		r.order = append(r.order, engine.Symbol())
	}
	return r
}

// Lookup returns the engine serving a symbol.
func (r *Registry) Lookup(sym domain.Symbol) (*Engine, bool) {
	if r == nil {
		return nil, false
	}
	engine, ok := r.engines[sym.ID]
	return engine, ok
}

// Symbols returns the registered markets in registration order.
func (r *Registry) Symbols() []domain.Symbol {
	if r == nil {
		return nil
	}
	return append([]domain.Symbol(nil), r.order...)
}

// Engines returns the registered engines in registration order.
func (r *Registry) Engines() []*Engine {
	if r == nil {
		return nil
	}
	out := make([]*Engine, 0, len(r.order))
	for _, sym := range r.order {
		out = append(out, r.engines[sym.ID])
	}
	return out
}

// Len returns how many markets are registered.
func (r *Registry) Len() int {
	if r == nil {
		return 0
	}
	return len(r.order)
}
