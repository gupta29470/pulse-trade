import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/networking/client_message.dart';
import 'package:pulse_trade_frontend/core/networking/connection_status.dart';
import 'package:pulse_trade_frontend/domain/entities/subscription_spec.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';

/// The typed, parsed view of the socket.
///
/// Blocs consume this instead of `MarketWebSocketClient` so they can be tested
/// with a plain stream of messages and no transport at all. Parsing and
/// malformed-frame isolation happen behind this interface.
abstract interface class MarketStreamRepository {
  /// Decoded server frames, in arrival order. Never emits an error: a malformed
  /// frame is counted and dropped so the socket stays usable.
  Stream<ServerMessage> get messages;

  /// Connection failures, so the connection bloc can explain a drop instead,
  /// showing an unexplained `STALE`.
  Stream<AppFailure> get failures;

  /// Current transport status.
  ConnectionStatus get status;

  /// Transport status transitions.
  Stream<ConnectionStatus> get statusStream;

  /// The most recent `welcome` frame, which carries the session id, the engine
  /// epoch and the backend's tier thresholds.
  WelcomeMessage? get welcome;

  /// Opens the socket. Resolves when the attempt has been started, not when the
  /// connection is established; progress arrives on [statusStream].
  Future<void> connect();

  /// Replaces the session subscription.
  Future<void> subscribe(SubscriptionSpec spec);

  /// The subscription in force: the last spec passed to [subscribe], or `null`
  /// before the first one.
  ///
  /// The transport remembers this because a reconnect has to restore the
  /// session the user is actually looking at. The connection bloc replays this
  /// value rather than its own copy, which would still name the market the app
  /// started on after the user has switched markets.
  SubscriptionSpec? get currentSubscription;

  /// Sends one typed client frame.
  Future<void> send(ClientMessage message);

  /// Closes the socket and stops reconnecting.
  Future<void> disconnect({String reason = 'client'});

  /// Releases the stream controllers. The composition root owns this.
  Future<void> dispose();
}
