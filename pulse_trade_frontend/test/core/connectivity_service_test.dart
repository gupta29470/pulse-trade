import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/network_connectivity/service/connectivity_service.dart';
import 'package:pulse_trade_frontend/core/network_connectivity/utils/network_quality.dart';

/// The connectivity service must report UNKNOWN before its first check,
/// debounce a disconnect, ignore disconnects while the app is paused, and release
/// its timer, subscription and controller on dispose.
///
/// `initializeConnectionChecker()` is deliberately never called: it builds a real
/// `InternetConnection` that performs HTTP probes, and the contract under test is
/// the state machine around it, not the probe itself.
void main() {
  group('ConnectivityService (M-20)', () {
    testWidgets('reports UNKNOWN before the first check completes', (
      WidgetTester tester,
    ) async {
      final ConnectivityService service = ConnectivityService(
        clock: FakeClock(),
      );
      addTearDown(service.dispose);

      expect(service.internetStatus, isNull);
      expect(service.isInternetConnectionAvailable, isFalse);
      expect(service.isChecking, isFalse);
      expect(service.isPaused, isFalse);
    });

    testWidgets('a disconnect is not emitted until the 3 s debounce elapses', (
      WidgetTester tester,
    ) async {
      final ConnectivityService service = ConnectivityService(
        clock: FakeClock(),
      );
      addTearDown(service.dispose);

      final List<InternetStatus?> seen = <InternetStatus?>[];
      final StreamSubscription<InternetStatus?> subscription = service
          .internetStatusStream
          .listen(seen.add);
      addTearDown(subscription.cancel);

      service.emitStatusForTest(InternetStatus.disconnected);

      await tester.pump(const Duration(seconds: 2));
      expect(seen, isEmpty, reason: 'a handover blip must not flap the chip');

      await tester.pump(const Duration(seconds: 2));
      expect(seen, <InternetStatus?>[InternetStatus.disconnected]);
      expect(service.internetStatus, InternetStatus.disconnected);
    });

    testWidgets('a reconnect inside the debounce window cancels the disconnect', (
      WidgetTester tester,
    ) async {
      final ConnectivityService service = ConnectivityService(
        clock: FakeClock(),
      );
      addTearDown(service.dispose);

      final List<InternetStatus?> seen = <InternetStatus?>[];
      final StreamSubscription<InternetStatus?> subscription = service
          .internetStatusStream
          .listen(seen.add);
      addTearDown(subscription.cancel);

      service.emitStatusForTest(InternetStatus.disconnected);
      await tester.pump(const Duration(seconds: 1));
      service.emitStatusForTest(InternetStatus.connected);
      // The controller delivers asynchronously, so the listener runs on the next
      // microtask rather than inside emitStatusForTest.
      await tester.pump();

      expect(seen, <InternetStatus?>[InternetStatus.connected]);

      await tester.pump(const Duration(seconds: 5));
      expect(seen, <InternetStatus?>[
        InternetStatus.connected,
      ], reason: 'the cancelled disconnect must never surface');
    });

    testWidgets('disconnect events are ignored while the app is paused', (
      WidgetTester tester,
    ) async {
      final ConnectivityService service = ConnectivityService(
        clock: FakeClock(),
        disconnectDebounce: const Duration(milliseconds: 100),
      );
      addTearDown(service.dispose);

      final List<InternetStatus?> seen = <InternetStatus?>[];
      final StreamSubscription<InternetStatus?> subscription = service
          .internetStatusStream
          .listen(seen.add);
      addTearDown(subscription.cancel);

      service.setConnectionCheckPaused();
      expect(service.isPaused, isTrue);

      service.emitStatusForTest(InternetStatus.disconnected);
      await tester.pump(const Duration(seconds: 2));

      expect(
        seen,
        isEmpty,
        reason:
            'Android throttles background probes and produces false negatives',
      );
      expect(service.internetStatus, isNull);
    });

    testWidgets('pausing after a disconnect suppresses the pending emission', (
      WidgetTester tester,
    ) async {
      final ConnectivityService service = ConnectivityService(
        clock: FakeClock(),
        disconnectDebounce: const Duration(milliseconds: 100),
      );
      addTearDown(service.dispose);

      final List<InternetStatus?> seen = <InternetStatus?>[];
      final StreamSubscription<InternetStatus?> subscription = service
          .internetStatusStream
          .listen(seen.add);
      addTearDown(subscription.cancel);

      service.emitStatusForTest(InternetStatus.disconnected);
      service.setConnectionCheckPaused();
      await tester.pump(const Duration(seconds: 1));

      expect(seen, isEmpty);
    });

    testWidgets('dispose cancels the pending debounce and is idempotent', (
      WidgetTester tester,
    ) async {
      final ConnectivityService service = ConnectivityService(
        clock: FakeClock(),
      );

      final List<InternetStatus?> seen = <InternetStatus?>[];
      final StreamSubscription<InternetStatus?> subscription = service
          .internetStatusStream
          .listen(seen.add);

      service.emitStatusForTest(InternetStatus.disconnected);
      service.dispose();
      await tester.pump(const Duration(seconds: 5));

      expect(
        seen,
        isEmpty,
        reason: 'the debounce timer must not outlive dispose',
      );
      expect(tester.takeException(), isNull);

      // A second dispose must not throw on the already-closed controller.
      service.dispose();
      // Not awaited: closing the controller and cancelling its last listener have
      // to be able to complete in either order, so the test must not depend on one
      // finishing before the other.
      unawaited(subscription.cancel());
    });

    testWidgets('the stream is closed after dispose', (
      WidgetTester tester,
    ) async {
      final ConnectivityService service = ConnectivityService(
        clock: FakeClock(),
      );

      final Completer<void> closed = Completer<void>();
      final StreamSubscription<InternetStatus?> subscription = service
          .internetStatusStream
          .listen((InternetStatus? _) {}, onDone: closed.complete);

      service.dispose();
      await tester.pump();

      expect(closed.isCompleted, isTrue);
      // The done event already ended this subscription, so cancelling it is not
      // awaited: `cancel()` and the controller's close are mutually waiting
      // futures after a dispose (see ConnectivityService.dispose).
      unawaited(subscription.cancel());
    });
  });

  group('ConnectivityService quality thresholds', () {
    testWidgets('quality is informational and never a tier decision', (
      WidgetTester tester,
    ) async {
      final ConnectivityService service = ConnectivityService(
        clock: FakeClock(),
      );
      addTearDown(service.dispose);

      expect(service.qualityFromLatencyMs(120), NetworkQuality.excellent);
      expect(service.qualityFromLatencyMs(600), NetworkQuality.good);
      expect(service.qualityFromLatencyMs(800), NetworkQuality.fair);
      expect(service.qualityFromLatencyMs(2000), NetworkQuality.poor);
    });
  });
}
