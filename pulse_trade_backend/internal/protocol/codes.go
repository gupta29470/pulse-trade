// Package protocol defines the application's wire format: the message envelope,
// the typed client and server messages, and the error-code vocabulary shared with
// the Flutter client. It performs validation and knows nothing about state.
package protocol

import "fmt"

// Version is the protocol version carried on every server frame. Additive fields
// do not bump it; removing, renaming or re-typing a field does.
const Version = 1

// MessageType discriminates frames in both directions.
type MessageType string

// Server to client.
const (
	TypeWelcome           MessageType = "welcome"
	TypeSubscribed        MessageType = "subscribed"
	TypeUnsubscribed      MessageType = "unsubscribed"
	TypePong              MessageType = "pong"
	TypePing              MessageType = "ping"
	TypeMarketStatus      MessageType = "market_status"
	TypeOrderBookSnapshot MessageType = "order_book_snapshot"
	TypeOrderBookDelta    MessageType = "order_book_delta"
	TypeTrade             MessageType = "trade"
	TypeTradeBatch        MessageType = "trade_batch"
	TypeCandleUpdate      MessageType = "candle_update"
	TypeCandleClosed      MessageType = "candle_closed"
	TypeMarketSummary     MessageType = "market_summary"
	TypeHealth            MessageType = "health"
	TypeError             MessageType = "error"
	TypeGoodbye           MessageType = "goodbye"
)

// Client to server.
const (
	TypeHello         MessageType = "hello"
	TypeSubscribe     MessageType = "subscribe"
	TypeUnsubscribe   MessageType = "unsubscribe"
	TypeSetInterval   MessageType = "set_interval"
	TypeLatencyReport MessageType = "latency_report"
	TypeTierOverride  MessageType = "tier_override"
)

// Error codes. The client maps these to user-visible copy in one place, so the
// vocabulary has to stay small and stable.
const (
	CodeMalformedFrame       = "MALFORMED_FRAME"
	CodeUnknownMessageType   = "UNKNOWN_MESSAGE_TYPE"
	CodeValidationFailed     = "VALIDATION_FAILED"
	CodeUnsupportedSymbol    = "UNSUPPORTED_SYMBOL"
	CodeUnsupportedInterval  = "UNSUPPORTED_INTERVAL"
	CodeUnsupportedChannel   = "UNSUPPORTED_CHANNEL"
	CodeRateLimited          = "RATE_LIMITED"
	CodeTierOverrideRejected = "TIER_OVERRIDE_REJECTED"
	CodeDebugDisabled        = "DEBUG_DISABLED"
	CodeSubscriptionRequired = "SUBSCRIPTION_REQUIRED"
	CodeSlowConsumer         = "SLOW_CONSUMER"
	CodeProtocolVersion      = "PROTOCOL_VERSION_UNSUPPORTED"
	CodeServerShutdown       = "SERVER_SHUTDOWN"
	CodeInternal             = "INTERNAL"
)

// Error is a typed protocol error. Fatal errors close the connection; the rest are
// reported and the socket stays usable, because a single bad frame should not tear
// down a healthy feed.
type Error struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Fatal     bool   `json:"fatal"`
	RequestID string `json:"requestId,omitempty"`
}

func (e *Error) Error() string { return fmt.Sprintf("%s: %s", e.Code, e.Message) }

// NewError builds a non-fatal protocol error.
func NewError(code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

// NewFatalError builds an error that closes the connection.
func NewFatalError(code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...), Fatal: true}
}

// Channels a client may subscribe to.
const (
	ChannelOrderBook = "order_book"
	ChannelTrades    = "trades"
	ChannelCandles   = "candles"
	ChannelSummary   = "summary"
	ChannelHealth    = "health"
)

// Channels returns every valid channel name.
func Channels() []string {
	return []string{ChannelOrderBook, ChannelTrades, ChannelCandles, ChannelSummary, ChannelHealth}
}

// ValidChannel reports whether a channel name is recognised.
func ValidChannel(name string) bool {
	for _, c := range Channels() {
		if c == name {
			return true
		}
	}
	return false
}

// DefaultChannels is the subscription applied when a client subscribes without
// naming channels.
func DefaultChannels() []string {
	return []string{ChannelOrderBook, ChannelTrades, ChannelCandles, ChannelSummary, ChannelHealth}
}
