import 'package:flutter_test/flutter_test.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/subscription_spec.dart';
import 'package:pulse_trade_frontend/features/connection/connection_bloc.dart';
import 'package:pulse_trade_frontend/features/connection/connection_event.dart';
import 'package:pulse_trade_frontend/features/connection/connection_state.dart';
import 'package:pulse_trade_frontend/features/connection/reconnect_policy.dart';

import '../support/fake_stream_repository.dart';

/// The transport's recovery paths.
///
/// Each case pins one guarantee: a background suspend resumes on return, an
/// explicit disconnect does not, a stalled handshake releases the dial slot, an
/// unanswered heartbeat retires the socket, and reachability returning dials.
void main() {
  late FakeStreamRepository transport;
  late ConnectionBloc bloc;

  const SubscriptionSpec spec = SubscriptionSpec(
    symbol: 'BTCUSDT',
    interval: CandleInterval.m1,
  );

  setUp(() {
    transport = FakeStreamRepository();
    bloc = ConnectionBloc(
      stream: transport,
      subscription: spec,
      policy: ReconnectPolicy(),
      clock: FakeClock(),
    );
  });

  tearDown(() async {
    await bloc.close();
    await transport.dispose();
  });

  /// Lets the bloc finish handling everything queued so far.
  Future<void> settle() => pumpEventQueue();

  Future<void> connect() async {
    bloc.add(const Connect());
    await settle();
    transport.socketUp();
    await settle();
  }

  test('going offline and online again dials a new socket', () async {
    // Wifi goes off and the socket dies without the OS saying so; when the link
    // returns the app must dial, not claim the corpse.
    await connect();
    expect(transport.connectCalls, 1, reason: 'the first dial');

    bloc.add(const InternetStatusChanged(InternetStatus.disconnected));
    await settle();
    expect(bloc.state, isA<ConnectionOffline>());

    bloc.add(const InternetStatusChanged(InternetStatus.connected));
    await settle();

    expect(
      transport.connectCalls,
      2,
      reason: 'reachability returning must dial, not reuse a dead socket',
    );
  });

  test('a reconnect restores the market the user switched to', () async {
    // The app starts on the default market, then the user opens another one:
    // the market bloc sends the new spec through the same repository the
    // connection bloc resubscribes with.
    await connect();
    expect(transport.specs.last.symbol, 'BTCUSDT', reason: 'the start-up spec');

    await transport.subscribe(
      const SubscriptionSpec(symbol: 'ETHUSDT', interval: CandleInterval.m1),
    );

    // The socket drops and comes back, which is a fresh subscription.
    transport.dropSocket();
    await settle();
    transport.socketUp();
    await settle();

    expect(
      transport.specs.last.symbol,
      'ETHUSDT',
      reason:
          'the reconnect must restore the market on screen, '
          'not the one the app started on',
    );
  });

  test(
    'the background timeout is resumable: foregrounding dials again',
    () async {
      await connect();

      bloc.add(const AppBackgrounded());
      bloc.add(
        const Disconnect(
          reason: 'background_timeout',
          resumeOnForeground: true,
        ),
      );
      await settle();
      expect(bloc.state, isA<ConnectionDisconnected>());

      bloc.add(const AppForegrounded());
      await settle();

      expect(
        transport.connectCalls,
        2,
        reason: 'returning to the app must re-dial after a background timeout',
      );
    },
  );

  test('a non-resumable disconnect stays disconnected on foreground', () async {
    await connect();

    bloc.add(const Disconnect(reason: 'client'));
    await settle();
    bloc.add(const AppForegrounded());
    await settle();

    expect(
      transport.connectCalls,
      1,
      reason: 'an explicit disconnect must not silently reconnect',
    );
  });

  test('an unanswered heartbeat declares the socket dead', () async {
    await connect();

    // The only signal a vanished wifi link ever produces.
    bloc.add(const HeartbeatMissed());
    await settle();

    expect(
      bloc.state,
      isA<ConnectionReconnecting>(),
      reason:
          'a socket that cannot answer a ping must be dropped and re-dialled',
    );
  });

  test('a dial that never completes does not swallow later retries', () async {
    // The handshake in flight when the network vanished never returns. While it
    // holds the dial slot, every retry — including the watchdog's — is dropped,
    // so the app can never come back.
    final FakeStreamRepository hanging = FakeStreamRepository()
      ..hangConnect = true;
    final ConnectionBloc stuck = ConnectionBloc(
      stream: hanging,
      subscription: spec,
      policy: ReconnectPolicy(),
      clock: FakeClock(),
      dialTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(() async {
      await stuck.close();
      await hanging.dispose();
    });

    stuck.add(const Connect());
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // The stalled attempt must have been abandoned, so a fresh dial goes out.
    hanging.hangConnect = false;
    stuck.add(const Connect());
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      hanging.connectCalls,
      greaterThanOrEqualTo(2),
      reason: 'a stalled handshake must not block every later dial',
    );
  });

  test('the watchdog leaves a live socket alone', () async {
    await connect();
    final int before = transport.connectCalls;

    bloc.add(const ReconnectWatchdogFired());
    await settle();

    expect(
      transport.connectCalls,
      before,
      reason: 'a live socket must not be torn down by the watchdog',
    );
  });

  test(
    'the watchdog dials when a socket went down and nothing is pending',
    () async {
      await connect();

      // Down while backgrounded: the bloc publishes stale and arms nothing.
      bloc.add(const AppBackgrounded());
      transport.dropSocket();
      await settle();

      bloc.add(const AppForegrounded());
      await settle();
      final int afterForeground = transport.connectCalls;

      // If the foreground event were lost, the watchdog has to be the way out.
      bloc.add(const ReconnectWatchdogFired());
      await settle();

      expect(
        transport.connectCalls,
        greaterThanOrEqualTo(afterForeground),
        reason: 'the watchdog must not leave the app with no retry pending',
      );
    },
  );
}
