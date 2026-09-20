package observability

import (
	"context"
	"io"
	"log/slog"
	"os"
	"strings"
)

// Logger is the application's structured logger. Records are always JSON — there
// is no text mode — so a reviewer can pipe the output through jq and so the
// numeric subset of the schema lines up with the metrics database.
type Logger struct {
	*slog.Logger
	version string
	debug   bool
}

// contextKey is unexported so no other package can collide with it.
type contextKey struct{ name string }

var loggerKey = contextKey{name: "logger"}

// New builds a JSON logger writing to stdout.
func New(level, version string, debugBuild bool, w io.Writer) *Logger {
	if w == nil {
		w = os.Stdout
	}
	opts := &slog.HandlerOptions{
		Level:       parseLevel(level),
		AddSource:   false,
		ReplaceAttr: replaceAttr,
	}
	base := slog.New(slog.NewJSONHandler(w, opts)).With(
		slog.String(FieldService, "pulsetrade-backend"),
		slog.String(FieldVersion, version),
	)
	return &Logger{Logger: base, version: version, debug: debugBuild}
}

func parseLevel(level string) slog.Level {
	switch strings.ToLower(level) {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

// replaceAttr normalises the timestamp to RFC3339 with milliseconds, which is the
// wire format used everywhere else in the system.
func replaceAttr(_ []string, a slog.Attr) slog.Attr {
	if a.Key == slog.TimeKey {
		return slog.String(slog.TimeKey, a.Value.Time().UTC().Format("2006-01-02T15:04:05.000Z"))
	}
	return a
}

// With returns a logger with additional attributes.
func (l *Logger) With(args ...any) *Logger {
	return &Logger{Logger: l.Logger.With(args...), version: l.version, debug: l.debug}
}

// Component returns a logger tagged with a subsystem name.
func (l *Logger) Component(name string) *Logger {
	return l.With(slog.String(FieldComponent, name))
}

// Session returns a logger tagged with a session's identifiers. Passing both the
// full id and the short id means a log line can be matched to what the app shows
// the user without a lookup.
func (l *Logger) Session(sessionID, shortID string) *Logger {
	return l.With(
		slog.String(FieldSessionID, sessionID),
		slog.String(FieldShortID, shortID),
	)
}

// WithCorrelation attaches a correlation id, used for REST requests and injected
// faults so a user-visible error maps back to one log line.
func (l *Logger) WithCorrelation(correlationID string) *Logger {
	return l.With(slog.String(FieldCorrelationID, correlationID))
}

// DebugEnabled reports whether debug records will be emitted.
func (l *Logger) DebugEnabled() bool { return l.debug }

// WithContext attaches a logger to a context so downstream calls inherit the
// session and correlation attributes instead of rebuilding them.
func WithContext(ctx context.Context, logger *Logger) context.Context {
	return context.WithValue(ctx, loggerKey, logger)
}

// FromContext returns the logger attached to ctx, or the fallback.
func FromContext(ctx context.Context, fallback *Logger) *Logger {
	if ctx == nil {
		return fallback
	}
	if l, ok := ctx.Value(loggerKey).(*Logger); ok && l != nil {
		return l
	}
	return fallback
}
