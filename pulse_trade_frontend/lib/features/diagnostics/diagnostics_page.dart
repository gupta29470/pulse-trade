import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:pulse_trade_frontend/app/build_flags.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/widgets/inline_notice.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/features/diagnostics/diagnostics_cubit.dart';
import 'package:pulse_trade_frontend/features/diagnostics/diagnostics_state.dart';
import 'package:pulse_trade_frontend/features/diagnostics/widgets/connectivity_section.dart';
import 'package:pulse_trade_frontend/features/diagnostics/widgets/diagnostics_sections.dart';
import 'package:pulse_trade_frontend/features/diagnostics/widgets/diagnostics_telemetry_sections.dart';

/// System diagnostics at `/diagnostics`.
///
/// Every value on this screen comes from [DiagnosticsState]; nothing is
/// interpolated, defaulted or invented. A datum no producer has reported renders
/// as `—`, which is the honest answer and the one this page requires (a
/// fabricated node id makes the whole page worthless to a reviewer).
///
/// The page itself is composition only: it arranges sections and owns the two
/// actions. Each section is a separate widget that reads exactly the state it
/// needs, so a change in the latency series cannot cause the persistence block
/// to be re-derived.
class DiagnosticsPage extends StatelessWidget {
  /// Creates the page.
  const DiagnosticsPage({super.key});

  /// The debug console route, registered only in debug/profile builds.
  static const String debugRoute = '/debug';

  @override
  Widget build(BuildContext context) {
    return _DiagnosticsScope(
      child: BlocBuilder<DiagnosticsCubit, DiagnosticsState>(
        // The state is value-equal, so an unchanged 5 s poll produces no rebuild
        // at all; any real change does, which is what a screen about change
        // should do.
        buildWhen: (DiagnosticsState previous, DiagnosticsState next) =>
            previous != next,
        builder: (BuildContext context, DiagnosticsState state) {
          return Scaffold(
            backgroundColor: AppColors.canvas,
            appBar: AppBar(
              title: const Text('System Diagnostics'),
              actions: <Widget>[
                IconButton(
                  onPressed: () => context.read<DiagnosticsCubit>().refresh(),
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                ),
                const SizedBox(width: AppSpacing.spaceXs),
              ],
            ),
            body: _DiagnosticsBody(state: state),
          );
        },
      ),
    );
  }
}

/// Starts and stops the poll around the page's lifetime.
///
/// The cubit is provided above this widget — the composition root owns its
/// lifetime — so this wrapper only manages *when* it works: opening the screen
/// starts the poll, popping it stops the timer and the socket taps. Without the
/// `stop`, one visit to diagnostics would leave a 5 s REST poll running for the
/// rest of the session.
class _DiagnosticsScope extends StatefulWidget {
  const _DiagnosticsScope({required this.child});

  final Widget child;

  @override
  State<_DiagnosticsScope> createState() => _DiagnosticsScopeState();
}

class _DiagnosticsScopeState extends State<_DiagnosticsScope> {
  @override
  void initState() {
    super.initState();
    // Deferred by one frame: `start` emits a state, and emitting synchronously
    // from `initState` would do so while the first build is still in progress.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      context.read<DiagnosticsCubit>().start();
    });
  }

  @override
  void dispose() {
    // `dispose` cannot await, and there is nothing to wait for: `stop` cancels a
    // timer and two subscriptions synchronously before resolving.
    context.read<DiagnosticsCubit>().stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The scrollable readout.
class _DiagnosticsBody extends StatelessWidget {
  const _DiagnosticsBody({required this.state});

  final DiagnosticsState state;

  @override
  Widget build(BuildContext context) {
    final AppFailure? failure = state.failure;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenMarginPhone,
        AppSpacing.spaceSm,
        AppSpacing.screenMarginPhone,
        AppSpacing.space2xl,
      ),
      children: <Widget>[
        if (failure != null)
          InlineNotice(
            // A failed refresh is a notice, not a replacement for the readout:
            // the successful sections are still on screen and still true.
            message: '${failure.message} · showing the last successful read',
            tone: InlineNoticeTone.warn,
          ),
        SessionSection(state: state),
        ConnectivitySection(state: state),
        AdaptiveDeliverySection(state: state),
        RoundTripSection(state: state),
        JitterSection(state: state),
        FeedHealthSection(state: state),
        CandleSection(state: state),
        RecoverySection(state: state),
        PersistenceSection(state: state),
        const SizedBox(height: AppSpacing.spaceMd),
        // Debug builds only: the console does not exist in release, so neither
        // does its entry point.
        if (debugConsoleEnabled)
          OutlinedButton(
            onPressed: () => context.go(DiagnosticsPage.debugRoute),
            child: const Text('Open Debug & Fault Injection Console'),
          ),
        if (debugConsoleEnabled) const SizedBox(height: AppSpacing.spaceXs),
        FilledButton(
          onPressed: () {
            // Not awaited: the clipboard write has no continuation, and a failure
            // there must not delay the confirmation below.
            context.read<DiagnosticsCubit>().copyToClipboard();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Diagnostics JSON copied')),
            );
          },
          child: const Text('Copy diagnostics JSON'),
        ),
      ],
    );
  }
}
