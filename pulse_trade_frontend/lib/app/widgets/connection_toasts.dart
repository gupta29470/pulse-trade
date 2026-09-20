import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pulse_trade_frontend/features/connection/connection_bloc.dart';
import 'package:pulse_trade_frontend/features/connection/connection_state.dart';

/// How the connection looks from the user's point of view, collapsed from the
/// bloc's six states into the three worth interrupting someone for.
enum Reachability {
  /// The socket is live.
  connected,

  /// The device has no route — reachability says there is no internet.
  offline,

  /// There is a route but no live socket: what is on screen is cached.
  stale,
}

/// Surfaces connection transitions as a transient toast.
///
/// This is deliberately not a persistent connection *banner*: a SnackBar appears,
/// says one sentence and leaves. It never occupies layout and never pushes
/// content down. The distinction matters because static numbers look the same
/// whether the market is quiet or the socket is gone, and the user has no other
/// way to tell those apart.
///
/// Only transitions fire. Rebuilding on every tier change or health report must
/// not reshuffle the toast queue, so the listener is filtered on [categoryOf]
/// rather than on the state object.
class ConnectionToasts extends StatefulWidget {
  /// Wraps the app content.
  const ConnectionToasts({super.key, required this.child});

  /// The wrapped subtree.
  final Widget child;

  /// Collapses a bloc state to the category a toast is about.
  @visibleForTesting
  static Reachability categoryOf(PtConnectionState state) => switch (state) {
    ConnectionConnected() => Reachability.connected,
    ConnectionOffline() => Reachability.offline,
    _ => Reachability.stale,
  };

  /// The sentence for a transition, or `null` when it is not worth a toast.
  ///
  /// Becoming connected is only news when something had been wrong, so `from`
  /// decides whether it is announced at all.
  @visibleForTesting
  static String? messageFor(Reachability from, Reachability to) => switch (to) {
    Reachability.offline => 'No internet connection · showing saved data',
    Reachability.stale => 'Connection lost · showing saved data',
    Reachability.connected =>
      from == Reachability.connected ? null : 'Back online',
  };

  @override
  State<ConnectionToasts> createState() => _ConnectionToastsState();
}

class _ConnectionToastsState extends State<ConnectionToasts> {
  /// The category the last toast was built from.
  ///
  /// `BlocListener` hands the listener only the new state, and "back online" is
  /// worth saying only when it *is* a return, so the previous category is kept.
  /// It starts connected so a cold start cannot open with a toast.
  Reachability _shown = Reachability.connected;

  @override
  Widget build(BuildContext context) {
    return BlocListener<ConnectionBloc, PtConnectionState>(
      listenWhen: (PtConnectionState previous, PtConnectionState next) =>
          ConnectionToasts.categoryOf(previous) !=
          ConnectionToasts.categoryOf(next),
      listener: (BuildContext context, PtConnectionState state) {
        final Reachability to = ConnectionToasts.categoryOf(state);
        final String? message = ConnectionToasts.messageFor(_shown, to);
        _shown = to;
        if (message == null) return;
        ScaffoldMessenger.of(context)
          // Replacing rather than queueing: two toasts about one episode would
          // be a stale sentence arriving after the problem is over.
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(message),
              duration: const Duration(seconds: 4),
              behavior: SnackBarBehavior.floating,
            ),
          );
      },
      child: widget.child,
    );
  }
}
