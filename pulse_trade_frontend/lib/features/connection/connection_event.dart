import 'package:equatable/equatable.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/networking/connection_status.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';

/// Everything that can move the connection state machine.
///
/// The set is deliberately closed and small. Transport facts — a status
/// transition, a decoded frame, a typed failure — arrive on the repository's
/// streams and are consumed as *observations*, because they are not decisions
/// anyone makes. Only the things the UI or the lifecycle layer actually decide
/// are modelled here, which is what keeps [Connect] the single place that may
/// open a socket and makes the "at most one socket, one heartbeat timer, one
/// reconnect timer" invariant checkable by reading one file.
sealed class ConnectionEvent extends Equatable {
  /// Base constructor.
  const ConnectionEvent();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Opens the socket and starts observing it.
///
/// While the device is offline this event does **not** dial: it emits
/// `ConnectionOffline` and waits for reachability to return, so no DNS
/// lookup, timeout or battery is spent proving what the connectivity layer
/// already knows.
final class Connect extends ConnectionEvent {
  /// Creates a connect request.
  const Connect();
}

/// A periodic nudge that nothing is pending while the app is still not
/// connected.
///
/// The state machine has several paths that publish a state without arming a
/// retry — a socket that died while the app was backgrounded, an offline flag no
/// later event cleared. Any of them can strand the app on cached values forever,
/// so the watchdog is the backstop that makes recovery independent of whether
/// every event arrived.
final class ReconnectWatchdogFired extends ConnectionEvent {
  /// Creates a watchdog tick.
  const ReconnectWatchdogFired();

  @override
  List<Object?> get props => const <Object?>[];
}

/// A heartbeat pulse went unanswered past its timeout.
///
/// This is the only evidence a half-open socket ever produces. A peer that goes
/// away cleanly sends a close the transport reports; a wifi link that vanishes
/// sends nothing, so a socket that cannot answer a ping has to be declared dead
/// by the only party still asking.
final class HeartbeatMissed extends ConnectionEvent {
  /// Creates a missed-pong event.
  const HeartbeatMissed();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Closes the socket on purpose and releases every timer and subscription.
final class Disconnect extends ConnectionEvent {
  /// Creates a disconnect request.
  ///
  /// [reason] is logged, never rendered: a user-visible "why" would be a
  /// connection banner by another name.
  ///
  /// [resumeOnForeground] distinguishes the two things this event means. The
  /// background timeout closes the socket to stop spending battery on a screen
  /// nobody is looking at, and the session is expected to come back when the
  /// user does — that is the resumable case. A disconnect that ends the session
  /// outright is not, and must not silently reconnect later.
  const Disconnect({this.reason = 'client', this.resumeOnForeground = false});

  /// Why the socket is being closed, for the structured log.
  final String reason;

  /// Whether returning to the foreground should dial again.
  final bool resumeOnForeground;

  @override
  List<Object?> get props => <Object?>[reason, resumeOnForeground];
}

/// Cancels a pending backoff and dials now.
///
/// The user asked to stop waiting; a stable-connection reset is not implied,
/// because the attempt counter is only cleared by an actual connection.
final class ReconnectNow extends ConnectionEvent {
  /// Creates an immediate-reconnect request.
  const ReconnectNow();
}

/// The app returned to the foreground.
final class AppForegrounded extends ConnectionEvent {
  /// Creates a foreground event.
  const AppForegrounded();
}

/// The app left the foreground.
///
/// The socket is intentionally kept for the lifecycle observer's background
/// timeout, so this event stops the heartbeat and never emits a terminal state.
final class AppBackgrounded extends ConnectionEvent {
  /// Creates a background event.
  const AppBackgrounded();
}

/// The device's internet reachability changed.
final class InternetStatusChanged extends ConnectionEvent {
  /// Creates a reachability event.
  const InternetStatusChanged(this.status);

  /// The newly observed reachability.
  ///
  /// `disconnected` is what makes a reconnect attempt illegal; the bloc
  /// waits for the matching `connected` instead of burning the backoff schedule.
  final InternetStatus status;

  @override
  List<Object?> get props => <Object?>[status];
}

/// A backoff timer armed for [attemptId] elapsed.
///
/// The id, not the attempt number, is the identity of the attempt: a timer that
/// was superseded by a newer one, by a manual reconnect or by a disconnect still
/// fires, and must be ignored rather than race a live attempt.
final class BackoffElapsed extends ConnectionEvent {
  /// Creates a backoff-elapsed event.
  const BackoffElapsed(this.attemptId);

  /// The id of the attempt this timer was armed for.
  final int attemptId;

  @override
  List<Object?> get props => <Object?>[attemptId];
}

/// A frame arrived on the socket.
///
/// Transport callbacks are delivered as events rather than emitted from a stream
/// listener: `emit` is only valid inside a handler, and routing through the event
/// loop also means a frame cannot interleave with another state transition.
final class SocketMessageReceived extends ConnectionEvent {
  /// Creates a received-frame event.
  const SocketMessageReceived(this.message);

  /// The decoded frame.
  final ServerMessage message;

  @override
  List<Object?> get props => <Object?>[message];
}

/// The transport reported a failure.
final class TransportFailureReported extends ConnectionEvent {
  /// Creates a failure event.
  const TransportFailureReported(this.failure);

  /// The typed failure.
  final AppFailure failure;

  @override
  List<Object?> get props => <Object?>[failure];
}

/// The transport reported a socket status change.
final class SocketStatusReported extends ConnectionEvent {
  /// Creates a status event.
  const SocketStatusReported(this.status);

  /// The new status.
  final ConnectionStatus status;

  @override
  List<Object?> get props => <Object?>[status];
}
