import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pulse_trade_frontend/app/build_flags.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/app/widgets/app_card.dart';
import 'package:pulse_trade_frontend/app/widgets/card_header.dart';
import 'package:pulse_trade_frontend/app/widgets/empty_state.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_override.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';
import 'package:pulse_trade_frontend/features/debug/debug_console_cubit.dart';
import 'package:pulse_trade_frontend/features/debug/debug_console_state.dart';
import 'package:pulse_trade_frontend/features/debug/widgets/debug_action_button.dart';

/// The debug console: generator, session, tier and fault controls.
///
/// The router registers this route only when [debugConsoleEnabled] is set, and the
/// guard here is the second line of defence for the case where someone routes to it
/// by hand: a build without the flag renders an explanation instead of a set of
/// controls the backend would refuse. The two must read the same flag — a guard on
/// `kReleaseMode` alone made the console reachable-but-empty in a release build that
/// opted in, which is exactly the build that has to demonstrate a forced tier
/// change.
class DebugConsolePage extends StatelessWidget {
  /// Creates the console page.
  const DebugConsolePage({super.key});

  @override
  Widget build(BuildContext context) {
    if (!debugConsoleEnabled) {
      return Scaffold(
        backgroundColor: AppColors.canvas,
        appBar: AppBar(title: const Text('Debug console')),
        body: const EmptyState(
          title: 'Debug console unavailable',
          message:
              'Generator controls and fault injection are not enabled in this '
              'build. Rebuild with '
              '--dart-define=PULSETRADE_DEBUG_CONSOLE=true to use them.',
          icon: Icons.lock_outline_rounded,
        ),
      );
    }
    return const _DebugConsoleBody();
  }
}

/// The console's stateful core: owns only the selected session id.
class _DebugConsoleBody extends StatefulWidget {
  const _DebugConsoleBody();

  @override
  State<_DebugConsoleBody> createState() => _DebugConsoleBodyState();
}

class _DebugConsoleBodyState extends State<_DebugConsoleBody> {
  /// The session fault injection currently targets, or `null` for the first one.
  String? _selectedSessionId;

  @override
  void initState() {
    super.initState();
    // Fetch after the first frame so the cubit is read from a complete tree and
    // a slow debug route cannot delay first paint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(context.read<DebugConsoleCubit>().loadSessions());
    });
  }

  @override
  Widget build(BuildContext context) {
    final DebugConsoleCubit cubit = context.watch<DebugConsoleCubit>();
    final DebugConsoleState state = cubit.state;
    final List<DebugSessionInfo> sessions = state.sessions;
    final DebugSessionInfo? selected = _selectedOf(sessions);
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('Debug & Fault Injection'),
        actions: <Widget>[
          IconButton(
            onPressed: state.isBusy ? null : cubit.loadSessions,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh sessions',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenMarginPhone,
          vertical: AppSpacing.spaceMd,
        ),
        children: <Widget>[
          _feedbackCard(state),
          _generatorCard(cubit, state),
          _sessionsCard(cubit, state, sessions, selected),
          _tierCard(cubit, state),
          _faultCard(cubit, state, selected),
          _metricsStoreCard(cubit, state),
          _disconnectCard(cubit, state),
          _logTailCard(cubit, state),
        ],
      ),
    );
  }

  /// The explicitly selected session, defaulting to the first live one.
  ///
  /// Defaulting matters: an unselected console would silently disable every
  /// fault button, and the most useful target during a walkthrough is the one
  /// and only live session.
  DebugSessionInfo? _selectedOf(List<DebugSessionInfo> sessions) {
    final String? wanted = _selectedSessionId;
    if (wanted != null) {
      for (final DebugSessionInfo session in sessions) {
        if (session.id == wanted) return session;
      }
    }
    return sessions.isEmpty ? null : sessions.first;
  }

  /// The last action's outcome, so every control's effect is visible.
  Widget _feedbackCard(DebugConsoleState state) {
    final String? result = state.lastResult;
    final String? error = state.lastError;
    return _card(
      title: 'Last action',
      trailing: state.isBusy
          ? const SizedBox(
              height: 14,
              width: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      children: <Widget>[
        if (error != null)
          _line('FAILED · $error', AppColors.bear)
        else if (result != null)
          _line('OK · $result', AppColors.bull)
        else
          _line(
            'No action run yet — every control reports its result here.',
            AppColors.textSecondary,
          ),
      ],
    );
  }

  /// Generator controls.
  Widget _generatorCard(DebugConsoleCubit cubit, DebugConsoleState state) =>
      _card(
        title: 'Generator',
        subtitle: 'The single engine every screen renders from.',
        children: <Widget>[
          Wrap(
            spacing: AppSpacing.spaceXs,
            runSpacing: AppSpacing.spaceXs,
            children: <Widget>[
              DebugActionButton(
                label: 'Pause',
                onPressed: state.isBusy ? null : cubit.pauseGenerator,
                description: 'Stop generating trades',
              ),
              DebugActionButton(
                label: 'Resume',
                onPressed: state.isBusy ? null : cubit.resumeGenerator,
                description: 'Resume generation',
              ),
              DebugActionButton(
                label: 'Reset market',
                destructive: true,
                onPressed: state.isBusy ? null : cubit.resetGenerator,
                description:
                    'Reset the epoch and re-warm; the client must '
                    'resynchronise',
              ),
              DebugActionButton(
                label: 'Burst 5 s',
                onPressed: state.isBusy ? null : () => cubit.burstGenerator(),
                description: 'Force a volatility burst',
              ),
              DebugActionButton(
                label: 'Empty history',
                destructive: true,
                onPressed: state.isBusy ? null : cubit.emptyHistory,
                description: 'Serve empty candle arrays to the next requests',
              ),
            ],
          ),
        ],
      );

  /// Session list with per-row controls.
  Widget _sessionsCard(
    DebugConsoleCubit cubit,
    DebugConsoleState state,
    List<DebugSessionInfo> sessions,
    DebugSessionInfo? selected,
  ) => _card(
    title: 'Sessions',
    subtitle: 'Tap a row to target it with fault injection.',
    children: <Widget>[
      if (sessions.isEmpty)
        _line('No live sessions reported.', AppColors.textSecondary)
      else
        for (int index = 0; index < sessions.length; index++) ...<Widget>[
          if (index > 0) const Divider(height: 1),
          _SessionRow(
            session: sessions[index],
            selected: selected?.id == sessions[index].id,
            busy: state.isBusy,
            onSelect: () =>
                setState(() => _selectedSessionId = sessions[index].id),
            onDrop: () => cubit.dropSession(sessions[index].id),
            onLag: () => cubit.lagSession(sessions[index].id, 150),
            onJitter: () => cubit.jitterSession(sessions[index].id, 200),
          ),
        ],
    ],
  );

  /// Tier override controls.
  Widget _tierCard(DebugConsoleCubit cubit, DebugConsoleState state) => _card(
    title: 'Tier override',
    subtitle:
        'Sent as tier_override; the backend still owns the tier '
        'decision.',
    children: <Widget>[
      Wrap(
        spacing: AppSpacing.spaceXs,
        runSpacing: AppSpacing.spaceXs,
        children: <Widget>[
          for (final DeliveryOverride override in DeliveryOverride.values)
            DebugActionButton(
              label: override == state.tierOverride
                  ? '${override.wire} · active'
                  : override.wire,
              selected: override == state.tierOverride,
              busy: state.isBusy,
              onPressed: () => cubit.forceTier(override),
              description: override.isActive
                  ? 'Pin this session to ${override.wire}'
                  : 'Return the tier to the hysteresis machine',
            ),
        ],
      ),
    ],
  );

  /// Protocol fault injection against the selected session.
  Widget _faultCard(
    DebugConsoleCubit cubit,
    DebugConsoleState state,
    DebugSessionInfo? selected,
  ) {
    final String target = selected == null
        ? 'no session selected'
        : 'session ${selected.shortId}';
    return _card(
      title: 'Fault injection',
      subtitle: 'Protocol faults target $target.',
      children: <Widget>[
        Wrap(
          spacing: AppSpacing.spaceXs,
          runSpacing: AppSpacing.spaceXs,
          children: <Widget>[
            for (final DebugFault fault in DebugFault.values)
              DebugActionButton(
                label: fault.label,
                busy: state.isBusy,
                destructive: true,
                onPressed: selected == null
                    ? null
                    : () => cubit.injectFault(selected.id, fault),
                description: _faultHint(fault),
              ),
          ],
        ),
      ],
    );
  }

  /// The metrics-store fault, confirmed through the public health route.
  Widget _metricsStoreCard(DebugConsoleCubit cubit, DebugConsoleState state) =>
      _card(
        title: 'Metrics store',
        subtitle: 'Delivery must continue while /health degrades.',
        children: <Widget>[
          Wrap(
            spacing: AppSpacing.spaceXs,
            runSpacing: AppSpacing.spaceXs,
            children: <Widget>[
              DebugActionButton(
                label: 'Fail metrics store',
                destructive: true,
                busy: state.isBusy,
                onPressed: () => cubit.setMetricsStoreFailure(true),
                description: 'Make metrics writes fail, then read /health',
              ),
              DebugActionButton(
                label: 'Restore metrics store',
                busy: state.isBusy,
                onPressed: () => cubit.setMetricsStoreFailure(false),
                description: 'Restore writes, then read /health',
              ),
            ],
          ),
        ],
      );

  /// Force-disconnect control.
  Widget _disconnectCard(DebugConsoleCubit cubit, DebugConsoleState state) =>
      _card(
        title: 'Force disconnect',
        subtitle:
            'Closes the session socket; the client must show STALE '
            'and reconnect.',
        children: <Widget>[
          DebugActionButton(
            label: 'Drop this connection',
            destructive: true,
            busy: state.isBusy,
            onPressed: cubit.dropConnection,
            description: 'stream.disconnect(reason: debug)',
          ),
        ],
      );

  /// The log tail plus the on-device counters it explains.
  Widget _logTailCard(DebugConsoleCubit cubit, DebugConsoleState state) {
    final List<Map<String, Object?>> tail = cubit.logTail;
    final String counterLine = cubit.counters.entries
        .where((MapEntry<String, int> entry) => entry.value != 0)
        .map((MapEntry<String, int> entry) => '${entry.key}=${entry.value}')
        .join('   ');
    return _card(
      title: 'Log tail',
      subtitle:
          'Newest first · single-line JSON from the on-device ring '
          'buffer.',
      trailing: Text(
        '${tail.length} records',
        style: AppTypography.labelSm.copyWith(color: AppColors.textSecondary),
      ),
      children: <Widget>[
        _line(
          counterLine.isEmpty
              ? 'No on-device counter has moved yet.'
              : counterLine,
          AppColors.textSecondary,
          small: true,
        ),
        const SizedBox(height: AppSpacing.spaceXs),
        if (tail.isEmpty)
          _line('No log records captured.', AppColors.textSecondary)
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final Map<String, Object?> record in tail.reversed)
                  Text(
                    jsonEncode(record),
                    softWrap: false,
                    style: AppTypography.labelSm.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// A titled card in the console's own visual language.
  ///
  /// Deliberately its own card rather than a shared one: the debug console is a
  /// build-flagged screen that shares nothing else with the rest of the app, so it
  /// keeps its own thin wrapper over the two app-level widgets
  /// instead of creating a cross-feature dependency on a screen half this one's
  /// tests never mount.
  Widget _card({
    required String title,
    required List<Widget> children,
    String? subtitle,
    Widget? trailing,
  }) {
    final String? subtitleText = subtitle;
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.spaceMd),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            title: title,
            trailing: trailing,
            showDivider: subtitleText == null,
          ),
          if (subtitleText != null) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.spaceSm,
                AppSpacing.spaceXs,
                AppSpacing.spaceSm,
                AppSpacing.spaceXs,
              ),
              child: Text(
                subtitleText,
                style: AppTypography.bodySm.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            const Divider(height: 1),
          ],
          Padding(
            padding: const EdgeInsets.all(AppSpacing.spaceSm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  /// One line of feedback copy.
  Widget _line(String text, Color color, {bool small = false}) => Text(
    text,
    style: (small ? AppTypography.labelSm : AppTypography.bodyMd).copyWith(
      color: color,
    ),
  );
}

/// One session row: identity, delivery state and its three controls.
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.selected,
    required this.busy,
    required this.onSelect,
    required this.onDrop,
    required this.onLag,
    required this.onJitter,
  });

  final DebugSessionInfo session;
  final bool selected;
  final bool busy;
  final VoidCallback onSelect;
  final VoidCallback onDrop;
  final VoidCallback onLag;
  final VoidCallback onJitter;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onSelect,
      child: DecoratedBox(
        // A 2dp left rail, always present, so selecting a row moves nothing.
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: selected ? AppColors.bull : AppColors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.spaceXs,
            vertical: AppSpacing.spaceXs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${session.shortId} · ${session.symbol}',
                      style: AppTypography.labelMd.copyWith(
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    session.tier.wire,
                    style: AppTypography.labelSm.copyWith(
                      color: _tierColor(session.tier),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.space2xs),
              Text(
                'override ${session.overrideTier.wire} · '
                'rtt ${_formatMs(session.rttMs)} · '
                'jitter ${_formatMs(session.jitterMs)} · '
                'up ${_formatUptime(session.uptimeMs)}',
                style: AppTypography.labelSm.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.spaceXs),
              Wrap(
                spacing: AppSpacing.spaceXs,
                runSpacing: AppSpacing.space2xs,
                children: <Widget>[
                  DebugActionButton(
                    label: 'Drop',
                    destructive: true,
                    busy: busy,
                    onPressed: onDrop,
                  ),
                  DebugActionButton(
                    label: 'Lag 150',
                    busy: busy,
                    onPressed: onLag,
                  ),
                  DebugActionButton(
                    label: 'Jitter 200',
                    busy: busy,
                    onPressed: onJitter,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The delivered colour for a tier: full is healthy, minimal is a real loss.
Color _tierColor(DeliveryTier tier) {
  switch (tier) {
    case DeliveryTier.full:
      return AppColors.bull;
    case DeliveryTier.degraded:
      return AppColors.warn;
    case DeliveryTier.minimal:
      return AppColors.bear;
  }
}

/// The expected client reaction, so a tester knows what a fault proves.
String _faultHint(DebugFault fault) {
  switch (fault) {
    case DebugFault.bookGap:
      return 'Skip book mutations: the client must detect the range gap and '
          'recover';
    case DebugFault.duplicateDelta:
      return 'Repeat a delta range: the client must ignore it idempotently';
    case DebugFault.outOfOrderDelta:
      return 'Reverse two delta ranges: the older range must be ignored';
    case DebugFault.malformed:
      return 'Break the frame: the client must count it and stay connected';
    case DebugFault.staleSnapshot:
      return 'Reply with an older update id: the client must reject the image';
    case DebugFault.intervalMismatch:
      return 'Send an unsubscribed interval: the client must ignore it';
  }
}

/// `74 ms`, or `—` when no sample has arrived.
String _formatMs(num? value) => value == null ? '—' : '${value.round()} ms';

/// `HH:MM:SS` uptime, matching the diagnostics readout.
String _formatUptime(int milliseconds) {
  final Duration uptime = Duration(milliseconds: milliseconds);
  final String hours = uptime.inHours.toString().padLeft(2, '0');
  final String minutes = (uptime.inMinutes % 60).toString().padLeft(2, '0');
  final String seconds = (uptime.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}
