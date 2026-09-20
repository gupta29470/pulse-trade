package protocol

import (
	"encoding/json"
	"strings"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

// ClientMessage is one decoded, validated client frame.
type ClientMessage interface {
	Type() MessageType
}

// Hello identifies the client for logs and metrics. The device id is a random
// per-install value, never a hardware identifier.
type Hello struct {
	ClientVersion string `json:"clientVersion"`
	Platform      string `json:"platform"`
	DeviceID      string `json:"deviceId"`
}

func (Hello) Type() MessageType { return TypeHello }

// Subscribe replaces the session's subscription atomically.
type Subscribe struct {
	Symbol   string   `json:"symbol"`
	Interval string   `json:"interval"`
	Channels []string `json:"channels"`
}

func (Subscribe) Type() MessageType { return TypeSubscribe }

// Unsubscribe removes channels from the current subscription.
type Unsubscribe struct {
	Channels []string `json:"channels"`
}

func (Unsubscribe) Type() MessageType { return TypeUnsubscribe }

// SetInterval is shorthand for re-subscribing to a different interval.
type SetInterval struct {
	Interval string `json:"interval"`
}

func (SetInterval) Type() MessageType { return TypeSetInterval }

// Ping is the client-initiated RTT pulse.
type Ping struct {
	ID           int64 `json:"id"`
	ClientTimeMs int64 `json:"clientTimeMs"`
}

func (Ping) Type() MessageType { return TypePing }

// LatencyReport is the client's measured transport health. It is the only input to
// the backend's tier decision, which is why the client does the measuring: it owns
// the round trip.
type LatencyReport struct {
	RTTMs        float64 `json:"rttMs"`
	JitterMs     float64 `json:"jitterMs"`
	Samples      int     `json:"samples"`
	ClientTimeMs int64   `json:"clientTimeMs"`
	Window       string  `json:"window"`
	MissedPongs  int     `json:"missedPongs"`
	Capped       int     `json:"cappedSamples"`
}

func (LatencyReport) Type() MessageType { return TypeLatencyReport }

// TierOverride forces a delivery tier for this connection. Debug builds only.
type TierOverride struct {
	Tier string `json:"tier"`
}

func (TierOverride) Type() MessageType { return TypeTierOverride }

// DecodeClientMessage parses one client frame. Unknown fields are ignored so a
// newer client can talk to an older server; unknown types and invalid values are
// rejected with a typed error.
func DecodeClientMessage(data []byte) (ClientMessage, error) {
	var hdr header
	if err := json.Unmarshal(data, &hdr); err != nil {
		return nil, NewError(CodeMalformedFrame, "frame is not valid JSON: %v", err)
	}
	if strings.TrimSpace(hdr.Type) == "" {
		return nil, NewError(CodeValidationFailed, "frame has no type")
	}
	if hdr.Version > Version {
		return nil, NewFatalError(CodeProtocolVersion,
			"client asked for protocol version %d, server speaks %d", hdr.Version, Version)
	}

	unmarshal := func(v any) error {
		if err := json.Unmarshal(data, v); err != nil {
			return NewError(CodeValidationFailed, "invalid %s payload: %v", hdr.Type, err)
		}
		return nil
	}

	switch MessageType(hdr.Type) {
	case TypeHello:
		var msg Hello
		if err := unmarshal(&msg); err != nil {
			return nil, err
		}
		return msg, nil

	case TypeSubscribe:
		var msg Subscribe
		if err := unmarshal(&msg); err != nil {
			return nil, err
		}
		if err := msg.validate(); err != nil {
			return nil, err
		}
		return msg, nil

	case TypeUnsubscribe:
		var msg Unsubscribe
		if err := unmarshal(&msg); err != nil {
			return nil, err
		}
		if len(msg.Channels) == 0 {
			return nil, NewError(CodeValidationFailed, "unsubscribe requires at least one channel")
		}
		for _, c := range msg.Channels {
			if !ValidChannel(c) {
				return nil, NewError(CodeUnsupportedChannel, "channel %q is not supported", c)
			}
		}
		return msg, nil

	case TypeSetInterval:
		var msg SetInterval
		if err := unmarshal(&msg); err != nil {
			return nil, err
		}
		if _, err := domain.ParseInterval(msg.Interval); err != nil {
			return nil, NewError(CodeUnsupportedInterval, "interval %q is not supported", msg.Interval)
		}
		return msg, nil

	case TypePing:
		var msg Ping
		if err := unmarshal(&msg); err != nil {
			return nil, err
		}
		return msg, nil

	case TypeLatencyReport:
		var msg LatencyReport
		if err := unmarshal(&msg); err != nil {
			return nil, err
		}
		if err := msg.validate(); err != nil {
			return nil, err
		}
		return msg, nil

	case TypeTierOverride:
		var msg TierOverride
		if err := unmarshal(&msg); err != nil {
			return nil, err
		}
		if _, err := parseTierOrAuto(msg.Tier); err != nil {
			return nil, err
		}
		return msg, nil

	default:
		return nil, NewError(CodeUnknownMessageType, "unknown message type %q", hdr.Type)
	}
}

func (s Subscribe) validate() error {
	if s.Symbol == "" {
		return NewError(CodeValidationFailed, "subscribe requires a symbol")
	}
	if s.Interval == "" {
		return NewError(CodeValidationFailed, "subscribe requires an interval")
	}
	if _, err := domain.ParseInterval(s.Interval); err != nil {
		return NewError(CodeUnsupportedInterval, "interval %q is not supported", s.Interval)
	}
	for _, c := range s.Channels {
		if !ValidChannel(c) {
			return NewError(CodeUnsupportedChannel, "channel %q is not supported", c)
		}
	}
	return nil
}

// validate enforces plausibility on a client-measured metric. The backend cannot
// verify the measurement, but it can refuse values that are physically impossible
// rather than poisoning the tier machine with them.
func (r LatencyReport) validate() error {
	if r.RTTMs < 0 {
		return NewError(CodeValidationFailed, "rttMs must not be negative")
	}
	if r.JitterMs < 0 {
		return NewError(CodeValidationFailed, "jitterMs must not be negative")
	}
	if r.RTTMs > 60_000 {
		return NewError(CodeValidationFailed, "rttMs %v exceeds the 60s ceiling", r.RTTMs)
	}
	if r.JitterMs > 60_000 {
		return NewError(CodeValidationFailed, "jitterMs %v exceeds the 60s ceiling", r.JitterMs)
	}
	if r.Samples < 0 || r.Samples > 1_000 {
		return NewError(CodeValidationFailed, "samples %d is out of range", r.Samples)
	}
	return nil
}

// parseTierOrAuto accepts the four override values, including AUTO which clears
// the override.
func parseTierOrAuto(v string) (domain.DeliveryTier, error) {
	if strings.EqualFold(v, "AUTO") {
		return "", nil
	}
	tier, err := domain.ParseTier(v)
	if err != nil {
		return "", NewError(CodeTierOverrideRejected, "tier %q must be one of AUTO, FULL, DEGRADED, MINIMAL", v)
	}
	return tier, nil
}

// ParseTierOrAuto is the exported form used by the delivery layer.
func ParseTierOrAuto(v string) (tier domain.DeliveryTier, isAuto bool, err error) {
	if strings.EqualFold(strings.TrimSpace(v), "AUTO") {
		return "", true, nil
	}
	parsed, err := domain.ParseTier(v)
	if err != nil {
		return "", false, NewError(CodeTierOverrideRejected, "tier %q must be one of AUTO, FULL, DEGRADED, MINIMAL", v)
	}
	return parsed, false, nil
}
