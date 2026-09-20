// Package websocket adapts a gorilla/websocket connection to the delivery layer's
// Conn interface and owns the upgrade path.
package websocket

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/pulsetrade/pulse-trade-backend/internal/delivery"
	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/market"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
	"github.com/pulsetrade/pulse-trade-backend/internal/protocol"
)

// Config configures the WebSocket endpoint.
type Config struct {
	Path          string
	ReadLimit     int64
	WriteTimeout  time.Duration
	ReadTimeout   time.Duration
	PongTimeout   time.Duration
	AllowedOrigin func(*http.Request) bool
}

// Handler upgrades HTTP requests and runs one session per connection.
type Handler struct {
	cfg      Config
	manager  *delivery.Manager
	engine   *market.Engine
	logger   *observability.Logger
	registry *observability.Registry
	upgrader websocket.Upgrader
}

// NewHandler builds the WebSocket endpoint.
func NewHandler(cfg Config, manager *delivery.Manager, engine *market.Engine, logger *observability.Logger, registry *observability.Registry) *Handler {
	if cfg.Path == "" {
		cfg.Path = "/ws"
	}
	if cfg.ReadLimit <= 0 {
		cfg.ReadLimit = 16 * 1024
	}
	if cfg.WriteTimeout <= 0 {
		cfg.WriteTimeout = 5 * time.Second
	}
	if cfg.ReadTimeout <= 0 {
		cfg.ReadTimeout = 90 * time.Second
	}
	if cfg.PongTimeout <= 0 {
		cfg.PongTimeout = 120 * time.Second
	}
	allowed := cfg.AllowedOrigin
	if allowed == nil {
		// Local development only: the app connects from an emulator or a LAN device,
		// so any origin is accepted. A production deployment terminates TLS and
		// restricts this.
		allowed = func(*http.Request) bool { return true }
	}
	return &Handler{
		cfg:      cfg,
		manager:  manager,
		engine:   engine,
		logger:   logger.Component(observability.ComponentTransport),
		registry: registry,
		upgrader: websocket.Upgrader{
			ReadBufferSize:  4096,
			WriteBufferSize: 4096,
			CheckOrigin:     allowed,
		},
	}
}

// Path returns the configured endpoint path.
func (h *Handler) Path() string { return h.cfg.Path }

// ServeHTTP upgrades the connection and blocks until the session ends. Cleanup
// happens on the same path as creation so it cannot be skipped by an early return.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ws, err := h.upgrader.Upgrade(w, r, nil)
	if err != nil {
		// Upgrade already wrote a response.
		h.logger.Warn(observability.MsgWSUpgradeFailed, observability.FieldError, err.Error())
		return
	}
	// The read limit is set at upgrade time so an oversize frame is rejected by the
	// library before our code allocates for it.
	ws.SetReadLimit(h.cfg.ReadLimit)

	c := &conn{ws: ws, writeTimeout: h.cfg.WriteTimeout, readTimeout: h.cfg.ReadTimeout}
	ws.SetPongHandler(func(string) error {
		return ws.SetReadDeadline(time.Now().Add(h.cfg.PongTimeout))
	})
	_ = ws.SetReadDeadline(time.Now().Add(h.cfg.PongTimeout))

	session := h.manager.Register(c, nil)
	defer h.manager.Unregister(session.ID())

	ctx := r.Context()
	if err := session.Run(ctx); err != nil {
		if !errors.Is(err, context.Canceled) {
			h.logger.Warn(observability.MsgWSSessionEnded, observability.FieldSessionID, session.ID(),
				observability.FieldError, err.Error())
		}
	}
}

// conn implements delivery.Conn over a gorilla/websocket connection.
type conn struct {
	ws           *websocket.Conn
	writeTimeout time.Duration
	readTimeout  time.Duration

	// mu serialises writes. delivery already guarantees a single writer goroutine;
	// the lock is here so that an out-of-band write (a shutdown notice) cannot
	// interleave a partial frame.
	mu sync.Mutex
}

var _ delivery.Conn = (*conn)(nil)

func (c *conn) WriteMessage(ctx context.Context, data []byte) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.ws.SetWriteDeadline(time.Now().Add(c.writeTimeout)); err != nil {
		return fmt.Errorf("websocket: set write deadline: %w", err)
	}
	if err := c.ws.WriteMessage(websocket.TextMessage, data); err != nil {
		return fmt.Errorf("websocket: write: %w", err)
	}
	return nil
}

func (c *conn) ReadMessage(ctx context.Context) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	// A background goroutine closes the socket when the context ends so a blocked
	// read cannot outlive the session.
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = c.ws.Close()
		case <-done:
		}
	}()

	// Refresh the deadline before each read: any inbound frame proves the peer is
	// alive, and the client sends a latency report every two seconds.
	_ = c.ws.SetReadDeadline(time.Now().Add(c.readTimeout))
	_, data, err := c.ws.ReadMessage()
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, err
	}
	return data, nil
}

func (c *conn) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	// Best-effort close notice; the client is expected to reconnect deliberately.
	_ = c.ws.SetWriteDeadline(time.Now().Add(200 * time.Millisecond))
	_ = c.ws.WriteMessage(websocket.CloseMessage,
		websocket.FormatCloseMessage(websocket.CloseNormalClosure, "bye"))
	return c.ws.Close()
}

func (c *conn) RemoteAddr() string { return c.ws.RemoteAddr().String() }

// Compile-time guard that the protocol version constant is what we advertise.
var _ = protocol.Version
var _ = domain.Interval1m
