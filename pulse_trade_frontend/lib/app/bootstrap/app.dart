import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/bootstrap/app_bootstrap.dart';
import 'package:pulse_trade_frontend/app/theme/app_theme.dart';
import 'package:pulse_trade_frontend/core/network_connectivity/widgets/connectivity_wrapper.dart';

/// The Material app shell.
///
/// The routed page is wrapped twice and never replaced: [AppScope] publishes the
/// composition root to the tree, and the router's builder puts
/// [ConnectivityWrapper] between the router and the page so every screen can read
/// reachability. [ConnectivityWrapper] only *exposes* status through an
/// `InheritedNotifier`.
///
/// There is no connection banner and no blocking no-internet screen: connection
/// state is the `ConnectionChip` and per-section `CachedTag`s.
class PulseTradeApp extends StatelessWidget {
  /// Creates the app from the composition root.
  const PulseTradeApp({super.key, required this.bootstrap});

  /// The composition root.
  final AppBootstrap bootstrap;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      bootstrap: bootstrap,
      child: MaterialApp.router(
        title: 'PulseTrade',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        routerConfig: bootstrap.router.router,
        builder: (BuildContext context, Widget? child) => ConnectivityWrapper(
          // The connectivity layer only *exposes* status through an
          // InheritedNotifier. It never replaces or hides the routed page: there
          // is no full-screen no-internet wall and no banner.
          service: bootstrap.connectivity,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}
