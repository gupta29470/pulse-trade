import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/app/widgets/connection_toasts.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';
import 'package:pulse_trade_frontend/features/connection/connection_state.dart';

/// The decision the toast makes: which states are worth interrupting someone
/// for, and what each transition says.
///
/// The rendering half (a SnackBar appears, and only on a transition) is verified
/// on a device: driving the real bloc and pumping the widget in `testWidgets`
/// fights the fake clock, and a test that needs six pumps to observe one toast
/// would be asserting the harness rather than the app.
void main() {
  const PtConnectionState connected = ConnectionConnected(
    rttMs: 12,
    sessionId: 'sess_1',
    shortId: 'ABC123',
    epoch: 0,
    tier: DeliveryTier.full,
  );

  group('category', () {
    test('a live socket is connected', () {
      expect(ConnectionToasts.categoryOf(connected), Reachability.connected);
    });

    test('no reachability is offline', () {
      expect(
        ConnectionToasts.categoryOf(const ConnectionOffline()),
        Reachability.offline,
      );
    });

    test('every other state is stale, because the data on screen is', () {
      // A socket down while backgrounded is the state the app was stranded in,
      // and it is exactly the case a user cannot tell from a quiet market.
      expect(
        ConnectionToasts.categoryOf(
          const ConnectionStale(reason: 'socket_down_while_backgrounded'),
        ),
        Reachability.stale,
      );
      expect(
        ConnectionToasts.categoryOf(const ConnectionDisconnected()),
        Reachability.stale,
      );
      expect(
        ConnectionToasts.categoryOf(const ConnectionConnecting()),
        Reachability.stale,
      );
    });
  });

  group('message', () {
    test('losing reachability names the cause and what is shown', () {
      expect(
        ConnectionToasts.messageFor(
          Reachability.connected,
          Reachability.offline,
        ),
        contains('No internet connection'),
      );
    });

    test('a dead socket says the data is saved', () {
      expect(
        ConnectionToasts.messageFor(Reachability.connected, Reachability.stale),
        contains('Connection lost'),
      );
    });

    test('recovering is announced', () {
      expect(
        ConnectionToasts.messageFor(
          Reachability.offline,
          Reachability.connected,
        ),
        'Back online',
      );
      expect(
        ConnectionToasts.messageFor(Reachability.stale, Reachability.connected),
        'Back online',
      );
    });

    test('staying connected says nothing', () {
      // A tier change or a health report rebuilds this widget; it must not
      // produce a toast.
      expect(
        ConnectionToasts.messageFor(
          Reachability.connected,
          Reachability.connected,
        ),
        isNull,
      );
    });

    test('one bad state does not restate itself', () {
      expect(
        ConnectionToasts.messageFor(Reachability.offline, Reachability.offline),
        contains('No internet connection'),
      );
    });
  });
}
