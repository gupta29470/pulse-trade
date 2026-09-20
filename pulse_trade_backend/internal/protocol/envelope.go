package protocol

import (
	"encoding/json"
	"fmt"
	"time"
)

// timeFormat is the single wire timestamp format: RFC3339 with milliseconds, UTC.
const timeFormat = "2006-01-02T15:04:05.000Z"

// FormatTime renders a timestamp for the wire.
func FormatTime(t time.Time) string { return t.UTC().Format(timeFormat) }

// ParseTime reads a wire timestamp.
func ParseTime(v string) (time.Time, error) {
	t, err := time.Parse(time.RFC3339Nano, v)
	if err != nil {
		return time.Time{}, fmt.Errorf("invalid timestamp %q: %w", v, err)
	}
	return t.UTC(), nil
}

// Envelope is the frame every server-to-client message uses.
//
// One envelope for everything buys versioning, a consistent server time and a
// per-connection sequence number, which is what makes a client-side protocol trace
// readable.
type Envelope struct {
	Type       MessageType     `json:"type"`
	Version    int             `json:"version"`
	ServerTime string          `json:"serverTime"`
	Seq        uint64          `json:"seq"`
	Payload    json.RawMessage `json:"payload,omitempty"`
}

// Encode builds one server frame. Passing a nil payload omits the payload member.
func Encode(t MessageType, seq uint64, serverTime time.Time, payload any) ([]byte, error) {
	env := Envelope{
		Type:       t,
		Version:    Version,
		ServerTime: FormatTime(serverTime),
		Seq:        seq,
	}
	if payload != nil {
		body, err := json.Marshal(payload)
		if err != nil {
			return nil, fmt.Errorf("protocol: encode %s payload: %w", t, err)
		}
		env.Payload = body
	}
	frame, err := json.Marshal(env)
	if err != nil {
		return nil, fmt.Errorf("protocol: encode %s envelope: %w", t, err)
	}
	return frame, nil
}

// header is decoded first so an unknown or malformed type can be rejected without
// interpreting the rest of the frame.
type header struct {
	Type      string `json:"type"`
	Version   int    `json:"version"`
	RequestID string `json:"requestId"`
}

// DecodeEnvelope validates a server frame. It is used by protocol tests and by any
// tooling that wants to check what the backend produced.
func DecodeEnvelope(data []byte) (Envelope, error) {
	var env Envelope
	if err := json.Unmarshal(data, &env); err != nil {
		return Envelope{}, NewError(CodeMalformedFrame, "frame is not valid JSON: %v", err)
	}
	if env.Type == "" {
		return Envelope{}, NewError(CodeValidationFailed, "frame has no type")
	}
	if env.Version == 0 {
		return Envelope{}, NewError(CodeValidationFailed, "frame has no version")
	}
	if env.Version > Version {
		return Envelope{}, NewFatalError(CodeProtocolVersion,
			"client supports protocol version %d, server speaks %d", env.Version, Version)
	}
	return env, nil
}
