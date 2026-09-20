import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_radii.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_override.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';

/// The three adaptive-delivery tiers, side by side, with **real** numbers.
///
/// The active card is marked in two ways that do not depend on colour: a bull
/// top border and the literal text `● active` (`○ active` for the others). The
/// app's accessibility rule is that colour is never the only carrier of
/// state, and a tier is a state.
///
/// The rates shown on the inactive cards are the *nominal* tier targets, which
/// is the one honest use of `DeliveryTier.nominalTargetRatePerSec`: they describe
/// what each tier would deliver. The active card reports the live effective rate
/// instead, because "target 10/s" and "delivering 9.8/s" are different claims
/// and diagnostics exists to make the second one visible.
class TierSegmentedCards extends StatelessWidget {
  /// Creates the row of cards.
  ///
  /// [overrideTier] is rendered as a single `Override` line beneath the cards
  /// rather than being folded into the active card: the readout requires `Tier`
  /// and `Override` to be distinguishable, and a pinned tier must not look like
  /// an automatic one.
  const TierSegmentedCards({
    super.key,
    required this.active,
    required this.overrideTier,
    required this.targetRatePerSec,
    required this.effectiveRatePerSec,
    required this.reason,
    required this.coalescedCount,
  });

  /// The tier the backend currently reports.
  final DeliveryTier active;

  /// The manual override in force, if any.
  final DeliveryOverride overrideTier;

  /// Messages per second the tier targets.
  final double targetRatePerSec;

  /// Messages per second actually delivered.
  final double effectiveRatePerSec;

  /// Machine-readable reason slug (`GOOD_HEALTH`, `HIGH_RTT`).
  final String reason;

  /// Messages coalesced in the last window.
  final int coalescedCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final DeliveryTier tier in DeliveryTier.values)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: tier == DeliveryTier.minimal
                        ? 0
                        : AppSpacing.spaceXs,
                  ),
                  child: _TierCard(
                    tier: tier,
                    isActive: tier == active,
                    // Only the active card shows a live number; the others show
                    // their configured target, which is what the tier *is*.
                    rate: tier == active
                        ? effectiveRatePerSec
                        : tier.nominalTargetRatePerSec,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.spaceSm),
        _MutedLine(label: 'Reason', value: reason),
        _MutedLine(
          label: 'Override',
          value: overrideTier.isActive
              ? '${overrideTier.wire} (forced)'
              : 'OFF',
          // A forced tier is the one case worth colouring, because it means the
          // automatic machine is no longer in charge.
          valueColor: overrideTier.isActive ? AppColors.warn : null,
        ),
        _MutedLine(
          label: 'Effective rate',
          value: '${effectiveRatePerSec.toStringAsFixed(1)}/s',
        ),
        _MutedLine(
          label: 'Target rate',
          value: '${targetRatePerSec.toStringAsFixed(1)}/s',
        ),
        _MutedLine(label: 'Coalesced (5s)', value: '$coalescedCount'),
      ],
    );
  }
}

/// One tier card.
class _TierCard extends StatelessWidget {
  const _TierCard({
    required this.tier,
    required this.isActive,
    required this.rate,
  });

  final DeliveryTier tier;
  final bool isActive;
  final double rate;

  @override
  Widget build(BuildContext context) {
    final Color accent = _accentFor(tier);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.spaceXs,
        vertical: AppSpacing.spaceSm,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.componentAll,
        border: Border(
          top: BorderSide(
            // The active card's 2dp bull border is the active marker;
            // inactive cards keep a 1dp outline so the row still reads as a set.
            color: isActive ? accent : AppColors.outline,
            width: isActive ? 2 : 1,
          ),
          left: const BorderSide(color: AppColors.outline),
          right: const BorderSide(color: AppColors.outline),
          bottom: const BorderSide(color: AppColors.outline),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            tier.wire,
            style: AppTypography.labelMd.copyWith(
              color: isActive ? accent : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.space2xs),
          Text(
            '${rate.toStringAsFixed(1)}/sec',
            style: AppTypography.labelLg.copyWith(
              color: isActive ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.space2xs),
          Text(
            _fidelityFor(tier),
            style: AppTypography.labelSm.copyWith(
              color: AppColors.textDisabled,
            ),
          ),
          const SizedBox(height: AppSpacing.spaceXs),
          Text(
            isActive ? '● active' : '○ active',
            style: AppTypography.labelSm.copyWith(
              color: isActive ? accent : AppColors.textDisabled,
            ),
          ),
        ],
      ),
    );
  }

  /// The tier's one-word characterisation.
  static String _fidelityFor(DeliveryTier tier) {
    switch (tier) {
      case DeliveryTier.full:
        return 'High fidelity';
      case DeliveryTier.degraded:
        return 'Medium fidelity';
      case DeliveryTier.minimal:
        return 'Low bandwidth';
    }
  }

  /// Each tier owns a colour so the card, the chip and the notice agree.
  static Color _accentFor(DeliveryTier tier) {
    switch (tier) {
      case DeliveryTier.full:
        return AppColors.bull;
      case DeliveryTier.degraded:
        return AppColors.warn;
      case DeliveryTier.minimal:
        return AppColors.bear;
    }
  }
}

/// A muted `label value` line under the cards.
class _MutedLine extends StatelessWidget {
  const _MutedLine({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.space2xs),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: AppTypography.labelSm.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.spaceSm),
          Expanded(
            child: Text(
              value,
              style: AppTypography.labelSm.copyWith(
                color: valueColor ?? AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
