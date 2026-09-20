/// The typed failure hierarchy that every layer above `data/` speaks.
///
/// A sealed hierarchy rather than an exception type so a `switch` over a failure
/// is exhaustive at compile time, and so no widget can ever receive a raw
/// `DioException` or `WebSocketChannelException` (see [FailureMapper], the only
/// place that knows about those types).
sealed class AppFailure implements Exception {
  /// Base constructor. [message] is user-visible copy; [code] mirrors the
  /// backend error vocabulary from `protocol/codes.go` when one applies.
  const AppFailure({
    required this.message,
    this.code,
    this.cause,
    this.retryable = false,
  });

  /// Short, user-facing description of what went wrong.
  final String message;

  /// Backend error code (`UNSUPPORTED_INTERVAL`, `INTERNAL`, …) when known.
  final String? code;

  /// The original error, kept for logging only. Never rendered.
  final Object? cause;

  /// Whether the UI should offer a Retry action.
  final bool retryable;

  /// Value equality ignores [cause] because a wrapped socket error has no
  /// meaningful equality and comparing it would make test assertions brittle.
  @override
  bool operator ==(Object other) =>
      other is AppFailure &&
      other.runtimeType == runtimeType &&
      other.message == message &&
      other.code == code &&
      other.retryable == retryable;

  @override
  int get hashCode => Object.hash(runtimeType, message, code, retryable);

  @override
  String toString() => '$runtimeType($message, code: $code)';
}

/// The connectivity gate refused the call before any transport work happened.
final class OfflineFailure extends AppFailure {
  /// Creates an offline failure. Not retryable: recovery is automatic and
  /// driven by the connectivity stream, never by a Retry button.
  const OfflineFailure({
    super.message = 'Device is offline',
    super.code = 'OFFLINE',
    super.cause,
    super.retryable = false,
  });
}

/// DNS failure, connection refused, socket reset.
final class NetworkFailure extends AppFailure {
  /// Creates a transport-level failure.
  const NetworkFailure({
    super.message = "Couldn't reach the backend",
    super.code,
    super.cause,
    super.retryable = true,
  });
}

/// A connect or receive timeout elapsed.
final class TimeoutFailure extends AppFailure {
  /// Creates a timeout failure.
  const TimeoutFailure({
    super.message = 'The backend took too long to answer',
    super.code = 'TIMEOUT',
    super.cause,
    super.retryable = true,
  });
}

/// A 5xx response, carrying the backend's correlation id when present.
final class ServerFailure extends AppFailure {
  /// Creates a server failure.
  const ServerFailure({
    super.message = 'Server error',
    super.code,
    super.cause,
    this.correlationId,
    super.retryable = true,
  });

  /// Correlation id echoed in the backend error body, shown in diagnostics.
  final String? correlationId;

  @override
  bool operator ==(Object other) =>
      super == other &&
      other is ServerFailure &&
      other.correlationId == correlationId;

  @override
  int get hashCode => Object.hash(super.hashCode, correlationId);
}

/// A 400/404 with a typed backend code: the request itself was wrong.
final class ValidationFailure extends AppFailure {
  /// Creates a validation failure. Not retryable by definition.
  const ValidationFailure({
    required super.message,
    super.code,
    super.cause,
    super.retryable = false,
  });
}

/// A malformed frame, an unknown message type or a protocol version mismatch.
final class ProtocolFailure extends AppFailure {
  /// Creates a protocol failure.
  const ProtocolFailure({
    super.message = 'Protocol error — resynchronising',
    super.code,
    super.cause,
    super.retryable = false,
  });
}

/// Order-book recovery exhausted its attempt budget.
final class OrderBookSyncFailure extends AppFailure {
  /// Creates a book-sync failure.
  const OrderBookSyncFailure({
    super.message = 'Order book could not be resynchronised',
    super.code,
    super.cause,
    super.retryable = true,
  });
}

/// Candle history could not be loaded or contained nothing usable.
final class HistoryFailure extends AppFailure {
  /// Creates a history failure.
  const HistoryFailure({
    super.message = 'No historical data available',
    super.code,
    super.cause,
    super.retryable = false,
  });
}

/// A cache read or write failed. Diagnostics-only: never user-visible alone.
final class CacheFailure extends AppFailure {
  /// Creates a cache failure.
  const CacheFailure({
    super.message = 'Cache unavailable',
    super.code = 'CACHE',
    super.cause,
    super.retryable = false,
  });
}

/// Last resort. Always logged with a correlation id before it is shown.
final class UnexpectedFailure extends AppFailure {
  /// Creates an unexpected failure.
  const UnexpectedFailure({
    super.message = 'Something went wrong',
    super.code = 'INTERNAL',
    super.cause,
    super.retryable = false,
  });
}
