import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/app/theme/app_theme.dart';
import 'package:pulse_trade_frontend/app/widgets/cached_tag.dart';
import 'package:pulse_trade_frontend/app/widgets/connection_chip.dart';

Future<void> _pumpChip(WidgetTester tester, Widget chip) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: Center(child: chip)),
    ),
  );
  await tester.pump();
}

void main() {
  group('ConnectionChip', () {
    testWidgets('LIVE shows the round-trip time when it is known', (
      WidgetTester tester,
    ) async {
      await _pumpChip(
        tester,
        const ConnectionChip(state: ConnectionChipState.live, rttMs: 74),
      );

      expect(find.text('LIVE 74ms'), findsOneWidget);
      expect(find.byType(ConnectionChip), findsOneWidget);
    });

    testWidgets('LIVE without a measurement still names the state', (
      WidgetTester tester,
    ) async {
      await _pumpChip(
        tester,
        const ConnectionChip(state: ConnectionChipState.live),
      );
      expect(find.text('LIVE'), findsOneWidget);
    });

    testWidgets('DEGRADED is textual, never colour-only', (
      WidgetTester tester,
    ) async {
      await _pumpChip(
        tester,
        const ConnectionChip(state: ConnectionChipState.degraded),
      );
      expect(find.text('DEGRADED'), findsOneWidget);
    });

    testWidgets('MINIMAL is textual, never colour-only', (
      WidgetTester tester,
    ) async {
      await _pumpChip(
        tester,
        const ConnectionChip(state: ConnectionChipState.minimal),
      );
      expect(find.text('MINIMAL'), findsOneWidget);
    });

    testWidgets('STALE is textual, never colour-only', (
      WidgetTester tester,
    ) async {
      await _pumpChip(
        tester,
        const ConnectionChip(state: ConnectionChipState.stale),
      );
      expect(find.text('STALE'), findsOneWidget);
    });

    testWidgets('OFFLINE is textual, never colour-only', (
      WidgetTester tester,
    ) async {
      await _pumpChip(
        tester,
        const ConnectionChip(state: ConnectionChipState.offline),
      );
      expect(find.text('OFFLINE'), findsOneWidget);
    });

    testWidgets('PAUSED, CONNECTING and CACHED each render their own label', (
      WidgetTester tester,
    ) async {
      for (final (ConnectionChipState state, String label)
          in <(ConnectionChipState, String)>[
            (ConnectionChipState.paused, 'PAUSED'),
            (ConnectionChipState.connecting, 'CONNECTING'),
            (ConnectionChipState.cached, 'CACHED'),
          ]) {
        await _pumpChip(tester, ConnectionChip(state: state));
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('CACHED appends a coarse age when one is supplied', (
      WidgetTester tester,
    ) async {
      await _pumpChip(
        tester,
        const ConnectionChip(
          state: ConnectionChipState.cached,
          cachedAge: Duration(seconds: 42),
        ),
      );
      expect(find.text('CACHED 42s'), findsOneWidget);
    });

    testWidgets('the chip exposes one composed semantics label', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpChip(
        tester,
        const ConnectionChip(state: ConnectionChipState.live, rttMs: 74),
      );

      expect(
        find.bySemanticsLabel('Connection live, round trip 74 milliseconds'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('the layout survives a 1.3 text scale', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: Scaffold(
              body: Center(
                child: ConnectionChip(
                  state: ConnectionChipState.live,
                  rttMs: 74,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('CachedTag', () {
    testWidgets('renders CACHED with an as-of time', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Center(
              child: CachedTag(
                kind: 'CACHED',
                asOf: DateTime.utc(2026, 9, 17, 12, 41, 3),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('CACHED'), findsOneWidget);
      expect(find.textContaining('12:41:03'), findsOneWidget);
    });

    testWidgets('renders STALE with an as-of time', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Center(
              child: CachedTag(
                kind: 'STALE',
                asOf: DateTime.utc(2026, 9, 17, 12, 41, 3),
                stale: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('STALE'), findsOneWidget);
      expect(find.textContaining('12:41:03'), findsOneWidget);
    });
  });
}
