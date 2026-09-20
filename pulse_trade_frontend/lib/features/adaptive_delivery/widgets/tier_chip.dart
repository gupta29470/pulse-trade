import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_motion.dart';
import 'package:pulse_trade_frontend/app/theme/app_radii.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';

/// `Tier: FULL · ~10/s` — what the backend is delivering, and how often.
///
/// **It reports, it never decides.** The tier and the rate come from the
/// backend's `health` frame; the chip renders them and offers an explanation of
/// the bands, which is the whole reason the thresholds travel in `welcome`
/// instead of being hardcoded here.
///
/// **The pulse.** A tier change is acknowledged with one `AppMotion.chipPulse`
/// tint flash. It is a one-shot animation driven by a timer rather than a
/// repeating one, because a chip that pulses forever reads as "still changing"
/// and the value only ever changes once per backend transition.
/// Nothing moves position, so a tier change cannot reflow the telemetry strip.
///
/// **Status is never colour alone**: the label always spells out the
/// tier, the rate and whether a human pinned it, and the info affordance carries
/// a semantic label of its own.
final class TierChip extends StatefulWidget {
  /// Creates the chip.
  ///
  /// [targetRatePerSec] is the backend's configured ceiling for [tier]. Pass
  /// `0` before the first `health` frame: the chip then omits the rate rather
  /// than guessing a nominal one.
  const TierChip({
    super.key,
    required this.tier,
    required this.targetRatePerSec,
    required this.isOverridden,
    this.onInfoTap,
  });

  /// The tier the backend reported.
  final DeliveryTier tier;

  /// Messages per second the tier targets, as reported by the backend.
  final double targetRatePerSec;

  /// Whether a human pinned the tier, which is shown as `(forced)` so an
  /// override is never mistaken for the hysteresis machine's verdict.
  final bool isOverridden;

  /// Opens the tier explanation sheet. When null the info glyph is not rendered
  /// at all, so the chip has no dead affordance.
  final VoidCallback? onInfoTap;

  @override
  State<TierChip> createState() => _TierChipState();
}

final class _TierChipState extends State<TierChip> {
  /// The flash duration. Read from the motion token so it cannot drift.
  static const Duration _pulseDuration = AppMotion.chipPulse;

  Timer? _pulseTimer;
  bool _highlighted = false;

  @override
  void didUpdateWidget(TierChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only a tier change pulses. A rate that moved inside the same tier is a
    // number changing, not a fidelity change, and pulsing for it would cry wolf.
    if (oldWidget.tier != widget.tier) {
      _pulseOnce();
    }
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    _pulseTimer = null;
    super.dispose();
  }

  void _pulseOnce() {
    _pulseTimer?.cancel();
    setState(() => _highlighted = true);
    _pulseTimer = Timer(_pulseDuration, () {
      if (!mounted) return;
      setState(() => _highlighted = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = _accentFor(widget.tier);
    final VoidCallback? onInfoTap = widget.onInfoTap;
    return Semantics(
      container: true,
      label: _semanticsLabel(),
      child: AnimatedContainer(
        duration: _pulseDuration,
        curve: Curves.easeOut,
        constraints: const BoxConstraints(minHeight: AppSpacing.spaceXl),
        padding: const EdgeInsets.only(
          left: AppSpacing.spaceXs,
          right: AppSpacing.space2xs,
        ),
        decoration: BoxDecoration(
          color: _highlighted ? _tintFor(widget.tier) : AppColors.transparent,
          borderRadius: AppRadii.microAll,
          border: Border.all(
            color: widget.isOverridden
                ? AppColors.outlineFocus
                : AppColors.outline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                _label(),
                style: AppTypography.labelSm.copyWith(color: accent),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onInfoTap != null)
              IconButton(
                onPressed: onInfoTap,
                tooltip: 'What do the delivery tiers mean?',
                icon: const Icon(Icons.info_outline),
                iconSize: 14,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                color: AppColors.textSecondary,
                constraints: const BoxConstraints(
                  minWidth: AppSpacing.spaceXl,
                  minHeight: AppSpacing.spaceXl,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// `Tier: FULL · ~10/s (forced)`.
  String _label() {
    final String rate = _rateSuffix(widget.targetRatePerSec);
    final String forced = widget.isOverridden ? ' (forced)' : '';
    return 'Tier: ${widget.tier.wire}$rate$forced';
  }

  /// The spoken form, expanded so the abbreviations are not read literally.
  String _semanticsLabel() {
    final String mode = widget.isOverridden
        ? 'pinned by the user'
        : 'chosen automatically';
    final double rate = widget.targetRatePerSec;
    final String cadence = rate > 0
        ? ', about ${_formatRate(rate)} updates per second'
        : '';
    return 'Delivery tier ${widget.tier.wire}$cadence, $mode';
  }

  /// Formats the reported rate without inventing precision: `10`, `2`, `0.5`.
  static String _formatRate(double rate) {
    if (rate == rate.roundToDouble()) return rate.toStringAsFixed(0);
    return rate.toStringAsFixed(1);
  }

  static String _rateSuffix(double rate) =>
      rate > 0 ? ' · ~${_formatRate(rate)}/s' : '';

  /// The tier's accent: `bull` for FULL, `warn` for DEGRADED, `bear` for the
  /// genuine fidelity loss that MINIMAL is.
  static Color _accentFor(DeliveryTier tier) => switch (tier) {
    DeliveryTier.full => AppColors.bull,
    DeliveryTier.degraded => AppColors.warn,
    DeliveryTier.minimal => AppColors.bear,
  };

  /// The pulse tint, using the existing alpha-blend tokens rather than a new
  /// opacity so the pulse cannot drift from the depth bars' palette.
  static Color _tintFor(DeliveryTier tier) => switch (tier) {
    DeliveryTier.full => AppColors.bullTint,
    DeliveryTier.degraded => AppColors.warnBannerBg,
    DeliveryTier.minimal => AppColors.bearTint,
  };
}
