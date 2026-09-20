/// Connectivity as a widget-tree fact, never as a screen.
///
/// The reference module's `ConnectivityWrapper` rendered a spinner in place of
/// the routed page until the first probe answered and a full-screen
/// `NoInternetWidget` on every disconnection. That page-replacing behaviour is
/// deliberately dropped here:
///
/// * A blocking wall throws away content the app already holds on disk. The
/// product must keep rendering cached candles, book and trades and mark them
/// `CACHED`/`STALE` with an "as of" time instead.
/// * A spinner for the UNKNOWN window is worse than the truth: the page can
/// render cached data immediately, and an unknown reachability state is not
/// a reason to hide it.
/// * A connection banner that appears on every network blip interrupts the
/// trader with information the always-present status chip already carries,
/// so nothing here draws one.
/// * Only the page knows which of its sections can be served from cache and
/// how old that cache is, so the decision belongs to the page.
///
/// What is left is one job: publish the status down the tree so a page can
/// consult it — and [ConnectivityWrapper] returns its `child` unchanged, wrapped
/// only in that provider.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/network_connectivity/service/connectivity_service.dart';

/// Holds the current [InternetStatus] and rebuilds its listeners when it
/// changes.
///
/// A [ChangeNotifier] rather than a `ValueNotifier` so the status is not part of
/// an inherited widget's `updateShouldNotify` identity: dependents must rebuild
/// on the *status changing*, not on the notifier object being replaced.
final class ConnectivityStatusNotifier extends ChangeNotifier {
  /// Creates a notifier seeded with [initialStatus].
  ///
  /// Seeding matters: the wrapper starts from `service.internetStatus` so the
  /// very first build sees the current value instead of UNKNOWN.
  ConnectivityStatusNotifier({InternetStatus? initialStatus})
    : _status = initialStatus;

  InternetStatus? _status;

  /// The current status; `null` means UNKNOWN, not offline.
  InternetStatus? get status => _status;

  /// Replaces the status and notifies listeners.
  ///
  /// A no-op when the status is unchanged, so a duplicate stream event cannot
  /// cause a rebuild.
  void update(InternetStatus? status) {
    if (_status == status) return;
    _status = status;
    notifyListeners();
  }
}

/// Publishes connectivity status to the subtree below it.
///
/// An [InheritedNotifier] rather than a Bloc: a page needs one read-only value,
/// and an inherited widget keeps that read local, cheap and free of any new
/// lifecycle to manage. `notifier` is required — a provider without a notifier
/// would leave every accessor reporting UNKNOWN forever.
class ConnectivityProvider
    extends InheritedNotifier<ConnectivityStatusNotifier> {
  /// Creates the provider.
  const ConnectivityProvider({
    super.key,
    required super.notifier,
    required super.child,
  });

  /// The status without subscribing: the caller is not rebuilt on later
  /// changes.
  ///
  /// For callbacks and one-shot reads, not for `build`.
  static InternetStatus? statusOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<ConnectivityProvider>()
      ?.notifier
      ?.status;

  /// The status and a dependency: the calling widget rebuilds on every change.
  ///
  /// This is the accessor for `build`: the UI is stream-driven, and this is that
  /// stream surfaced to widgets.
  static InternetStatus? watch(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ConnectivityProvider>()
      ?.notifier
      ?.status;

  /// Whether the last published status is `disconnected`.
  ///
  /// A missing provider, and UNKNOWN, both count as online: the UI must not
  /// show an offline affordance just because a wrapper was forgotten, and it
  /// must not claim offline before the first probe has answered.
  static bool isOffline(BuildContext context) =>
      watch(context) == InternetStatus.disconnected;
}

/// Wraps [child] with connectivity status, leaving the page exactly as routed.
///
/// Its `build` never substitutes, blocks or decorates [child] — see the library
/// comment for why that behaviour was dropped. It subscribes to
/// [ConnectivityService.internetStatusStream] and republishes through a
/// [ConnectivityProvider], so descendants that ask for the status rebuild when
/// it changes and the routed page keeps rendering throughout.
class ConnectivityWrapper extends StatefulWidget {
  /// Creates the wrapper.
  ///
  /// [service] is injected rather than read from a locator: a widget test can
  /// then mount a page against a stub status, and this widget keeps no opinion
  /// about how the app is composed.
  const ConnectivityWrapper({
    super.key,
    required this.service,
    required this.child,
  });

  /// The service whose status stream drives the provider.
  final ConnectivityService service;

  /// The routed page. Rendered unchanged.
  final Widget child;

  @override
  State<ConnectivityWrapper> createState() => _ConnectivityWrapperState();
}

class _ConnectivityWrapperState extends State<ConnectivityWrapper> {
  late final ConnectivityStatusNotifier _statusNotifier =
      ConnectivityStatusNotifier(initialStatus: widget.service.internetStatus);

  StreamSubscription<InternetStatus?>? _statusSubscription;

  @override
  void initState() {
    super.initState();
    _statusSubscription = _subscribe();
  }

  @override
  void didUpdateWidget(ConnectivityWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.service, widget.service)) return;
    // A swapped service means the open subscription is reporting on a
    // different probe; move it and re-seed the notifier.
    unawaited(_statusSubscription?.cancel());
    _statusSubscription = _subscribe();
    _statusNotifier.update(widget.service.internetStatus);
  }

  /// Attaches to the service stream, tolerating a broken one.
  StreamSubscription<InternetStatus?> _subscribe() =>
      widget.service.internetStatusStream.listen(
        _statusNotifier.update,
        onError: (Object error, StackTrace stackTrace) {
          // A probe-stream failure is not a reason to take the page down: the
          // provider simply keeps the last known status.
          AppLogger.error(
            LogEvents.connectivityChanged,
            fields: <String, Object?>{
              LogFields.component: LogComponents.connectivity,
              LogFields.reason: 'status_stream_error',
            },
            error: error,
            stackTrace: stackTrace,
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    // No spinner while UNKNOWN and no wall while OFFLINE: the child is returned
    // unchanged and merely wrapped.
    return ConnectivityProvider(notifier: _statusNotifier, child: widget.child);
  }

  @override
  void dispose() {
    unawaited(_statusSubscription?.cancel());
    _statusSubscription = null;
    _statusNotifier.dispose();
    super.dispose();
  }
}
