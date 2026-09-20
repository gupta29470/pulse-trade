import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/widgets/connection_toasts.dart';

/// The top-level destinations and the bar that switches between them.
///
/// The bar belongs to the *shell*, not to any one screen. A bar owned by a
/// single route unmounts with that route, and the app's primary navigation
/// disappears along with it. Mounting it once above the branches keeps it on
/// screen for every tab, which is what a bottom bar is for.
///
/// [StatefulNavigationShell] also gives each branch its own navigator and keeps
/// them alive in an `IndexedStack`, so switching tabs preserves scroll position
/// and in-flight state instead of rebuilding a tab from scratch.
class AppShell extends StatelessWidget {
  /// Wraps the active branch's navigator with the shared bar.
  const AppShell({super.key, required this.navigationShell});

  /// The branch container supplied by `StatefulShellRoute`.
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      // The branch's own navigator, so each tab keeps its stack and its state.
      // Wrapped in the toast listener so a dropped connection is announced on
      // whichever tab the user is looking at.
      body: ConnectionToasts(child: navigationShell),
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        backgroundColor: AppColors.surface1,
        indicatorColor: AppColors.outlineFocus,
        onDestinationSelected: (int index) => navigationShell.goBranch(
          index,
          // Re-tapping the active tab pops it back to its root: the bar is a way
          // out of a pushed page as well as a way into a tab, which is what makes
          // it safe to keep visible everywhere.
          initialLocation: index == navigationShell.currentIndex,
        ),
        destinations: const <Widget>[
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Market'),
          NavigationDestination(
            icon: Icon(Icons.star_border),
            label: 'Watchlist',
          ),
        ],
      ),
    );
  }
}
