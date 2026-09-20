import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_radii.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/app/widgets/app_card.dart';
import 'package:pulse_trade_frontend/app/widgets/metric_tile.dart';
import 'package:pulse_trade_frontend/app/widgets/section_header.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';

/// Explains the three delivery tiers, where this session sits, and why.
///
/// The numbers are the **backend's**, not the app's: the bands come from the
/// `welcome` frame's [TierThresholds] and the rates from the tier itself, so a
/// configuration change on the server is explained correctly without shipping a
/// new client. Nothing here recomputes a tier.
///
/// It is a sheet rather than a screen because it answers a question about the
/// screen the user is already on; dismissing it must leave that screen untouched.
final class TierExplanationSheet extends StatelessWidget {
  /// Creates the sheet body.
  const TierExplanationSheet({
    super.key,
    required this.current,
    required this.rttMs,
    required this.jitterMs,
    required this.reason,
    required this.isOverridden,
    this.thresholds,
  });

  /// The tier the backend last reported.
  final DeliveryTier current;

  /// RTT the backend last received from this client.
  final double rttMs;

  /// Jitter the backend last received from this client.
  final double jitterMs;

  /// Machine-readable reason slug for the current tier.
  final String reason;

  /// Whether a human pinned the tier.
  final bool isOverridden;

  /// The backend's band table. Falls back to [TierThresholds.unknown] before
  /// `welcome` arrives, so the sheet can always be opened.
  final TierThresholds? thresholds;

  /// Opens the sheet, returning when the user dismisses it.
  static Future<void> show(
    BuildContext context, {
    required DeliveryTier current,
    required double rttMs,
    required double jitterMs,
    required String reason,
    required bool isOverridden,
    TierThresholds? thresholds,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface2,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: AppRadii.containerAll),
      builder: (BuildContext context) => TierExplanationSheet(
        current: current,
        rttMs: rttMs,
        jitterMs: jitterMs,
        reason: reason,
        isOverridden: isOverridden,
        thresholds: thresholds,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TierThresholds band = thresholds ?? TierThresholds.unknown;
    return SafeArea(
      child: ConstrainedBox(
        // A sheet that covered the whole screen would be a page; a sheet that
        // could not scroll would clip the third tier on a small phone.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SectionHeader(title: 'Adaptive delivery'),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.spaceSm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      'The backend measures how this connection is behaving and '
                      'chooses how often to send updates. The app measures only '
                      'the round trip and reports it; it never picks a tier.',
                      style: AppTypography.bodyMd.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.spaceMd),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: MetricTile(
                            label: 'ROUND TRIP',
                            value: '${_formatNumber(rttMs)} ms',
                          ),
                        ),
                        const SizedBox(width: AppSpacing.spaceSm),
                        Expanded(
                          child: MetricTile(
                            label: 'JITTER',
                            value: '${_formatNumber(jitterMs)} ms',
                          ),
                        ),
                        const SizedBox(width: AppSpacing.spaceSm),
                        Expanded(
                          child: MetricTile(
                            label: 'MODE',
                            value: isOverridden ? 'PINNED' : 'AUTOMATIC',
                            valueColor: isOverridden
                                ? AppColors.warn
                                : AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.spaceMd),
                    Text(
                      'Reason reported by the backend: $reason',
                      style: AppTypography.labelSm.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.spaceMd),
                    _tierCard(
                      tier: DeliveryTier.full,
                      criteria:
                          'RTT under ${_formatNumber(band.fullMaxRttMs)} ms '
                          'and jitter under ${_formatNumber(band.fullMaxJitterMs)} ms.',
                    ),
                    _tierCard(
                      tier: DeliveryTier.degraded,
                      criteria:
                          'RTT of ${_formatNumber(band.fullMaxRttMs)} ms or more, '
                          'or jitter of ${_formatNumber(band.fullMaxJitterMs)} ms '
                          'or more.',
                    ),
                    _tierCard(
                      tier: DeliveryTier.minimal,
                      criteria:
                          'RTT of ${_formatNumber(band.minimalMinRttMs)} ms or more, '
                          'or jitter of ${_formatNumber(band.minimalMinJitterMs)} ms '
                          'or more.',
                    ),
                    const SizedBox(height: AppSpacing.spaceXs),
                    Text(
                      'The tier steps down after ${band.degradeStreak} poor '
                      'reports and back up after ${band.recoverStreak} good ones. '
                      'MINIMAL never returns straight to FULL. If reports stop, '
                      'the backend degrades after '
                      '${_formatSeconds(band.reportHoldMs)} and reaches MINIMAL '
                      'after ${_formatSeconds(band.reportDegradeMs)}.',
                      style: AppTypography.bodySm.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One tier row: its name, its target rate and its entry band.
  ///
  /// The current tier is marked with the word `current`, not with a colour, so
  /// the sheet survives greyscale.
  Widget _tierCard({required DeliveryTier tier, required String criteria}) {
    final bool isCurrent = tier == current;
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.spaceXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  isCurrent ? '${tier.wire} · current' : tier.wire,
                  style: AppTypography.headlineSm.copyWith(
                    color: isCurrent
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '~${_formatNumber(tier.nominalTargetRatePerSec)}/s',
                style: AppTypography.labelMd.copyWith(
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.space2xs),
          Text(
            criteria,
            style: AppTypography.bodySm.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// `150`, `0.5` — a band or a rate without trailing noise.
  static String _formatNumber(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }

  /// A millisecond duration as whole seconds.
  static String _formatSeconds(int milliseconds) =>
      '${(milliseconds / 1000).round()} s';
}
