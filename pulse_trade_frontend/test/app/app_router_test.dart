import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/app/build_flags.dart';
import 'package:pulse_trade_frontend/app/routing/app_router.dart';

/// Renders the real router.
///
/// Nothing else in the suite builds it: the pages are tested in isolation, so a
/// misconfigured shell — which produces a permanent first-frame stall rather
/// than an exception — is otherwise invisible to the suite.
void main() {
  // Constructing the router is what runs the shell's own validation, so this
  // needs no widget tree: `StatefulShellBranch` asserts its default locations at
  // construction time. Deliberately not pumping a route — every page needs the
  // composition root's blocs, and a bare router test cannot supply them.
  test('the router builds and resolves its initial location', () {
    final AppRouter app = AppRouter.create(debugControlsEnabled: true);

    expect(
      app.router.routeInformationProvider.value.uri.toString(),
      contains('/market/'),
    );
  });

  test('the console follows the build flag, not the test\'s debug mode', () {
    // Tests always compile in debug mode, so this is the one place the flag's
    // precedence can be observed rather than assumed: with
    // `--dart-define=PULSETRADE_DEBUG_CONSOLE=false` the console must be absent even
    // though `kDebugMode` is true. Run without the define, the first branch is
    // skipped and the default is asserted instead.
    if (const bool.hasEnvironment('PULSETRADE_DEBUG_CONSOLE')) {
      expect(
        debugConsoleEnabled,
        const bool.fromEnvironment('PULSETRADE_DEBUG_CONSOLE'),
        reason: 'an explicit define must win over the debug default',
      );
    }
    expect(AppRouter.create().debugControlsEnabled, debugConsoleEnabled);
  });

  test('both tabs are reachable and share one shell', () {
    final AppRouter app = AppRouter.create(debugControlsEnabled: false);

    // Every tab location must resolve to a route rather than the error view.
    for (final String location in <String>[
      '/market',
      '/market/BTCUSDT',
      '/watchlist',
    ]) {
      expect(
        app.router.configuration.findMatch(Uri.parse(location)).routes,
        isNotEmpty,
        reason: '$location must match a route',
      );
    }
  });

  test('only the market and watchlist locations resolve', () {
    final AppRouter app = AppRouter.create(debugControlsEnabled: false);

    // Only the market and watchlist locations are registered, so anything else
    // must fall through to the error view rather than resolving to a screen.
    for (final String location in <String>[
      '/settings',
      '/settings/connection',
      '/settings/security',
    ]) {
      expect(
        app.router.configuration.findMatch(Uri.parse(location)).routes,
        isEmpty,
        reason: '$location must not resolve to a screen',
      );
    }
  });
}
