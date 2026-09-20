import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/widgets/app_card.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/domain/orderbook/order_book_synchronizer.dart';
import 'package:pulse_trade_frontend/features/diagnostics/diagnostics_state.dart';
import 'package:pulse_trade_frontend/features/diagnostics/widgets/diagnostics_section.dart';

/// Formatting helpers shared by the diagnostics sections.
///
/// Public rather than private because the sections live in three files; keeping
/// them here means the label column, the placeholder and the number formatting
/// cannot drift between sections.
abstract final class DiagnosticsFormat {
  const DiagnosticsFormat._();

  /// The placeholder for a value no producer has reported.
  ///
  /// An em dash rather than `0`, `N/A` or an empty cell: zero is a measurement,
  /// and printing a measurement that was never taken is exactly the fabrication
  /// this screen forbids.
  static const String unknown = '—';

  /// `HH:MM:SS` in the local zone, the app-wide clock formatting.
  static String clock(DateTime at) {
    final DateTime local = at.toLocal();
    final String hour = local.hour.toString().padLeft(2, '0');
    final String minute = local.minute.toString().padLeft(2, '0');
    final String second = local.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  /// A duration in seconds with one decimal, from milliseconds.
  static String seconds(int milliseconds) =>
      '${(milliseconds / 1000).toStringAsFixed(1)} s';

  /// A full duration as `HH:MM:SS` or `MM:SS`.
  static String duration(int milliseconds) {
    final Duration value = Duration(milliseconds: milliseconds);
    final String minutes = value.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final String seconds = value.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    if (value.inHours > 0) {
      return '${value.inHours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  /// Thousands separators: a six-digit update id is unreadable without them.
  static String thousands(int value) {
    final String digits = value.abs().toString();
    final StringBuffer out = StringBuffer(value < 0 ? '-' : '');
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  /// Reads one key out of the cache statistics map without a dynamic call.
  ///
  /// `avoid_dynamic_calls` is on, so the value is narrowed by type rather than
  /// `.toString()`-ed off an `Object?`.
  static String cacheValue(Map<String, Object?> stats, String key) {
    final Object? raw = stats[key];
    if (raw == null) return unknown;
    if (raw is int) return thousands(raw);
    if (raw is num) return raw.toString();
    return raw.toString();
  }

  /// Healthy green, recovering amber, fault red, unknown dim.
  ///
  /// Colour is never the only carrier: every row that uses this also prints the
  /// state's own name.
  static Color forState(String label) {
    switch (label.toUpperCase()) {
      case 'ONLINE':
      case 'CONNECTED':
      case 'LIVE':
        return AppColors.bull;
      case 'WARMING':
      case 'STARTING':
      case 'CONNECTING':
      case 'RECONNECTING':
      case 'PAUSED':
        return AppColors.warn;
      case 'UNREACHABLE':
      case 'CLOSED':
      case 'STOPPED':
      case 'DEGRADED':
        return AppColors.bear;
      default:
        return AppColors.textDisabled;
    }
  }

  /// The order book's lifecycle colour.
  static Color forBookState(OrderBookState state) {
    switch (state) {
      case OrderBookState.live:
        return AppColors.bull;
      case OrderBookState.applying:
      case OrderBookState.syncing:
      case OrderBookState.initialLoading:
      case OrderBookState.recovering:
      case OrderBookState.stale:
        return AppColors.warn;
      case OrderBookState.error:
        return AppColors.bear;
    }
  }

  /// True when a state name is healthy in any of the four connectivity layers.
  static bool isOnline(String label) {
    const Set<String> healthy = <String>{
      'ONLINE',
      'CONNECTED',
      'LIVE',
      'WARMING',
      'STARTING',
    };
    return healthy.contains(label.toUpperCase());
  }
}

/// The padded card every section lives in.
///
/// A section is a card, not a bare header: the diagnostics page is a column of
/// discrete instruments and the 1dp outline is what separates them.
class DiagnosticsCard extends StatelessWidget {
  /// Creates a card.
  const DiagnosticsCard({super.key, required this.child});

  /// The section content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.spaceSm),
      child: child,
    );
  }
}

/// The Session block: identity of *this* connection, nothing else.
class SessionSection extends StatelessWidget {
  /// Creates the section.
  const SessionSection({super.key, required this.state});

  /// The readout being rendered.
  final DiagnosticsState state;

  @override
  Widget build(BuildContext context) {
    final String? sessionId = state.sessionId;
    return DiagnosticsCard(
      child: DiagnosticsSection(
        title: 'Session',
        rows: <DiagnosticRow>[
          DiagnosticRow(
            'Session ID',
            sessionId == null
                ? DiagnosticsFormat.unknown
                : '$sessionId (${state.shortId ?? DiagnosticsFormat.unknown})',
          ),
          DiagnosticRow(
            'Engine Epoch',
            state.engineEpoch?.toString() ?? DiagnosticsFormat.unknown,
          ),
          DiagnosticRow(
            'Protocol Version',
            state.protocolVersion?.toString() ?? DiagnosticsFormat.unknown,
          ),
          // The build version, never a hostname: there is one process on this
          // machine and no infrastructure to name.
          const DiagnosticRow('Node', '$nodePrefix${AppLogger.version}'),
          DiagnosticRow(
            'Ping',
            state.delivery?.receivedAt == null
                ? DiagnosticsFormat.unknown
                : '${state.delivery!.rttMs.toStringAsFixed(0)} ms',
          ),
        ],
      ),
    );
  }

  /// The literal part of the node row. The version comes from [AppLogger], so
  /// the diagnostics screen and the log records can never disagree about which
  /// build produced them.
  static const String nodePrefix = 'local · v';
}
