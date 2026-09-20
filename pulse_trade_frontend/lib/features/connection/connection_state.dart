import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/networking/connection_status.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';

/// The `ConnectionBloc`'s state.
///
/// **On the name.** Flutter's `FutureBuilder` exposes an enum also called
/// `ConnectionState`, so any file that imports Flutter widgets *and* this library
/// has to say which one it means: [PtConnectionState] is the typedef for this
/// type. This file imports no Flutter library, so the two names never collide
/// here.
///
/// The state carries only what the connection layer owns: the socket's
/// lifecycle, the identity of the session, and the last client-measured RTT.
/// Market liveness, order-book sync and the delivery tier are separate layers
/// and are never folded into this one.
sealed class ConnectionState extends Equatable {
  /// Base constructor.
  const ConnectionState();

  @override
  List<Object?> get props => const <Object?>[];
}

/// No socket, no attempt in flight, nothing scheduled.
final class ConnectionDisconnected extends ConnectionState {
  /// Creates a disconnected state.
  const ConnectionDisconnected();
}

/// A dial is in flight and no `welcome` has been answered yet.
final class ConnectionConnecting extends ConnectionState {
  /// Creates a connecting state.
  const ConnectionConnecting();
}

/// The socket is up and the session is identified.
final class ConnectionConnected extends ConnectionState {
  /// Creates a connected state.
  const ConnectionConnected({
    required this.rttMs,
    required this.sessionId,
    required this.shortId,
    required this.epoch,
    required this.tier,
  });

  /// Latest client-measured round trip, in milliseconds.
  ///
  /// Zero until the first `pong` completes, and reset to zero on every
  /// reconnect: a new network regime must not inherit the old one's numbers.
  final int rttMs;

  /// Server-assigned session id, empty until `welcome` arrives.
  final String sessionId;

  /// Six-character display id from `welcome`, empty until it arrives.
  final String shortId;

  /// Engine epoch reported by `welcome`.
  ///
  /// A change here means the backend reset its book, so consumers that hold book
  /// state must discard it and resynchronise.
  final int epoch;

  /// The delivery tier the **backend** last reported.
  ///
  /// This bloc projects the value; it never derives or estimates one.
  /// Carrying it here lets the telemetry strip render one
  /// coherent line without subscribing to a second stream.
  final DeliveryTier tier;

  @override
  List<Object?> get props => <Object?>[rttMs, sessionId, shortId, epoch, tier];
}

/// The socket is down and an attempt is scheduled.
///
/// [previous] is the transport status observed immediately before the drop, so
/// the diagnostics screen can distinguish "lost a live socket" from "the first
/// dial never landed" without guessing from the attempt number.
final class ConnectionReconnecting extends ConnectionState {
  /// Creates a reconnecting state.
  const ConnectionReconnecting({
    required this.attempt,
    required this.nextAttemptIn,
    required this.previous,
  });

  /// Attempt number, starting at one for the first retry of an outage.
  final int attempt;

  /// How long the scheduled attempt still has to wait.
  ///
  /// This is the *jittered* delay the policy produced, not the nominal one, so
  /// the chip and the diagnostics screen show the schedule actually in force.
  final Duration nextAttemptIn;

  /// The transport status observed before this drop.
  final ConnectionStatus previous;

  @override
  List<Object?> get props => <Object?>[attempt, nextAttemptIn, previous];
}

/// Values on screen are frozen and no live socket is feeding them.
///
/// Reached when a socket drops while the app is backgrounded: reconnecting there
/// would burn the radio for a screen nobody is looking at, so the bloc reports
/// the freeze honestly and waits for `AppForegrounded`.
final class ConnectionStale extends ConnectionState {
  /// Creates a stale state.
  const ConnectionStale({required this.reason});

  /// Machine-readable slug explaining why the feed stopped being live.
  final String reason;

  @override
  List<Object?> get props => <Object?>[reason];
}

/// The device has no internet reachability, so no attempt is being made.
final class ConnectionOffline extends ConnectionState {
  /// Creates an offline state.
  const ConnectionOffline();
}

/// Lets widget files that import both Flutter and this library name this type.
///
/// Flutter exports an unrelated `ConnectionState` from
/// `package:flutter/widgets.dart`; use this alias wherever both are in scope.
typedef PtConnectionState = ConnectionState;
