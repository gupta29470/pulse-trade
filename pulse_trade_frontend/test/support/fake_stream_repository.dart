import 'dart:async';

import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/networking/client_message.dart';
import 'package:pulse_trade_frontend/core/networking/connection_status.dart';
import 'package:pulse_trade_frontend/domain/entities/subscription_spec.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_stream_repository.dart';

/// A stream-repository double that records dials and can report socket state.
///
/// Shared by the connection-bloc tests so they exercise the real bloc rather
/// than a stub: `ConnectionBloc` is `final`, so it cannot be implemented
/// outside its library — driving it through its own events is the only way to
/// test it, and that is what these helpers are for.
final class FakeStreamRepository implements MarketStreamRepository {
  final StreamController<ConnectionStatus> _status =
      StreamController<ConnectionStatus>.broadcast();

  int connectCalls = 0;
  int disconnectCalls = 0;

  /// When true, `connect` never completes — a handshake that stalls because the
  /// network disappeared mid-attempt.
  bool hangConnect = false;
  ConnectionStatus _current = ConnectionStatus.disconnected;

  /// Every spec passed to [subscribe], oldest first, so a test can assert what a
  /// reconnect replayed.
  final List<SubscriptionSpec> specs = <SubscriptionSpec>[];

  @override
  Stream<ServerMessage> get messages => const Stream<ServerMessage>.empty();

  @override
  Stream<AppFailure> get failures => const Stream<AppFailure>.empty();

  @override
  ConnectionStatus get status => _current;

  @override
  Stream<ConnectionStatus> get statusStream => _status.stream;

  @override
  WelcomeMessage? get welcome => null;

  @override
  SubscriptionSpec? get currentSubscription =>
      specs.isEmpty ? null : specs.last;

  @override
  Future<void> connect() async {
    connectCalls++;
    if (hangConnect) {
      // Never completes: the caller must impose its own bound.
      return Completer<void>().future;
    }
    _publish(ConnectionStatus.connecting);
  }

  @override
  Future<void> subscribe(SubscriptionSpec spec) async => specs.add(spec);

  @override
  Future<void> send(ClientMessage message) async {}

  @override
  Future<void> disconnect({String reason = 'client'}) async {
    disconnectCalls++;
    _publish(ConnectionStatus.disconnected);
  }

  @override
  Future<void> dispose() async => _status.close();

  /// Reports a live socket, which is what clears the bloc's offline flag.
  void socketUp() => _publish(ConnectionStatus.connected);

  /// Reports the socket gone.
  void dropSocket() => _publish(ConnectionStatus.disconnected);

  void _publish(ConnectionStatus next) {
    _current = next;
    _status.add(next);
  }
}

/// A clock the tests advance by hand; the bloc only reads monotonic time.
final class FakeClock implements Clock {
  int _ms = 0;

  @override
  DateTime now() => DateTime.utc(2026, 9, 19, 12);

  @override
  int monotonicMs() => _ms;

  /// Moves the monotonic reading forward.
  void advance(Duration by) => _ms += by.inMilliseconds;
}
