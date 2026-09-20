import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:pulse_trade_frontend/app/build_flags.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/app/widgets/app_shell.dart';
import 'package:pulse_trade_frontend/features/debug/debug_console_page.dart';
import 'package:pulse_trade_frontend/features/diagnostics/diagnostics_page.dart';
import 'package:pulse_trade_frontend/features/market/market_page.dart';
import 'package:pulse_trade_frontend/features/watchlist/watchlist_page.dart';

/// The canonical route paths, plus the builders that keep stringly-typed
/// navigation in one file.
abstract final class AppPaths {
  const AppPaths._();

  /// The market tab's root, with no symbol.
  ///
  /// A `StatefulShellBranch` needs a default location that contains no path
  /// parameters — `goBranch` has to be able to return the tab to *some* concrete
  /// location — so the parameterised route hangs off this one instead of being
  /// the branch's only route. It renders the default symbol.
  static const String marketRoot = '/market';

  /// The market screen for one symbol. Deep-linkable, a child of [marketRoot].
  static const String marketPattern = '/market/:symbol';

  /// The watchlist.
  static const String watchlist = '/watchlist';

  /// Live telemetry and diagnostics.
  static const String diagnostics = '/diagnostics';

  /// The debug console. Registered only in debug/profile builds.
  static const String debug = '/debug';

  /// The market route for [symbol].
  static String market(String symbol) => '/market/$symbol';

  /// The symbol the market tab opens on.
  ///
  /// The branch root renders this symbol rather than an empty one: the market
  /// screen answers an unknown symbol with a not-found state, so the tab root
  /// has to name a real market.
  static const String defaultSymbol = 'BTCUSDT';

  /// The redirect target for `/`, so a cold start always lands on live data.
  static const String defaultMarket = '/market/BTCUSDT';

  /// The path parameter name of [marketPattern].
  static const String symbolParameter = 'symbol';
}

/// The application router.
///
/// Deep links arrive as `pulsetrade://market/BTCUSDT` and
/// `pulsetrade://watchlist`; [locationForDeepLink] maps them onto a route
/// location. An unknown symbol is **not** rejected here — the market screen owns
/// the not-found state, because only it can tell "unknown symbol" from "the
/// market roster has not loaded yet".
final class AppRouter {
  AppRouter._({required this.debugControlsEnabled})
    : router = _build(debugControlsEnabled: debugControlsEnabled);

  /// Builds the router. [debugControlsEnabled] defaults to the build flag, so a
  /// caller that does not care gets the documented behaviour: the console exists in
  /// debug builds, and in a release build that opted in with
  /// `--dart-define=PULSETRADE_DEBUG_CONSOLE=true`.
  factory AppRouter.create({bool? debugControlsEnabled}) => AppRouter._(
    debugControlsEnabled: debugControlsEnabled ?? debugConsoleEnabled,
  );

  /// The custom deep-link scheme the Android manifest is expected to register.
  static const String deepLinkScheme = 'pulsetrade';

  /// The host the deployed backend answers on.
  ///
  /// It is also the host Android verifies for app links, so an `https` link to a
  /// market path on it opens the screen. One host serves the data and owns the
  /// links, which is why this is not a separate marketing domain.
  static const String appLinkHost = 'pulse-trade-backend.onrender.com';

  /// The live `GoRouter` handed to `MaterialApp.router`.
  final GoRouter router;

  /// Whether the debug console route exists.
  final bool debugControlsEnabled;

  /// Converts a deep link into a route location.
  ///
  /// Two shapes arrive, and both mean the same thing:
  ///
  /// * the custom scheme, where the destination is the host —
  ///   `pulsetrade://market/BTCUSDT`, which is what `adb` and a browser dispatch;
  /// * the https app link, where the destination is the path —
  ///   `https://<host>/market/BTCUSDT`, which is what a chat client will hand over.
  ///
  /// Returns `null` for anything this build does not handle, so the caller can
  /// ignore the link instead of navigating somewhere arbitrary.
  static String? locationForDeepLink(Uri uri) {
    final String section;
    final String symbol;
    if (uri.scheme == deepLinkScheme) {
      section = uri.host;
      symbol = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
    } else if (uri.scheme == 'https' && uri.host == appLinkHost) {
      if (uri.pathSegments.isEmpty) return null;
      section = uri.pathSegments.first;
      symbol = uri.pathSegments.length > 1 ? uri.pathSegments[1] : '';
    } else {
      return null;
    }

    switch (section) {
      case 'watchlist':
        return AppPaths.watchlist;
      case 'diagnostics':
        return AppPaths.diagnostics;
      case 'market':
        if (symbol.isEmpty) return AppPaths.defaultMarket;
        return AppPaths.market(symbol.toUpperCase());
      default:
        return null;
    }
  }

  /// Parses a raw deep-link string, returning `null` when it is unusable.
  static String? locationForRawDeepLink(String raw) {
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null) return null;
    return locationForDeepLink(uri);
  }

  static GoRouter _build({required bool debugControlsEnabled}) {
    return GoRouter(
      initialLocation: AppPaths.defaultMarket,
      debugLogDiagnostics: kDebugMode,
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          redirect: (BuildContext context, GoRouterState state) =>
              AppPaths.defaultMarket,
        ),
        // The two tabs share one bottom bar and one bar instance. Routes
        // outside this shell (diagnostics, debug) are
        // deliberately full-screen: they are destinations you come back from,
        // not tabs you switch between.
        StatefulShellRoute.indexedStack(
          builder:
              (
                BuildContext context,
                GoRouterState state,
                StatefulNavigationShell navigationShell,
              ) => AppShell(navigationShell: navigationShell),
          branches: <StatefulShellBranch>[
            StatefulShellBranch(
              routes: <RouteBase>[
                GoRoute(
                  // The branch default: no path parameters, so the bar can
                  // always return this tab to a concrete location.
                  path: AppPaths.marketRoot,
                  builder: (BuildContext context, GoRouterState state) =>
                      const MarketPage(symbol: AppPaths.defaultSymbol),
                  routes: <RouteBase>[
                    GoRoute(
                      path: ':${AppPaths.symbolParameter}',
                      builder: (BuildContext context, GoRouterState state) =>
                          MarketPage(
                            symbol:
                                state.pathParameters[AppPaths
                                    .symbolParameter] ??
                                '',
                          ),
                    ),
                  ],
                ),
              ],
            ),
            StatefulShellBranch(
              routes: <RouteBase>[
                GoRoute(
                  path: AppPaths.watchlist,
                  builder: (BuildContext context, GoRouterState state) =>
                      const WatchlistPage(),
                ),
              ],
            ),
          ],
        ),
        GoRoute(
          path: AppPaths.diagnostics,
          builder: (BuildContext context, GoRouterState state) =>
              const DiagnosticsPage(),
        ),
        if (debugControlsEnabled)
          GoRoute(
            path: AppPaths.debug,
            builder: (BuildContext context, GoRouterState state) =>
                const DebugConsolePage(),
          ),
      ],
      errorBuilder: (BuildContext context, GoRouterState state) =>
          const _RouteNotFoundView(),
    );
  }
}

/// Rendered when a route does not exist at all — distinct from a *symbol* that
/// does not exist, which the market screen handles with its own copy.
class _RouteNotFoundView extends StatelessWidget {
  const _RouteNotFoundView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: const Text('Not found')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'That screen does not exist',
              style: AppTypography.headlineSm,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'The link may be out of date.',
              style: AppTypography.bodyMd.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
