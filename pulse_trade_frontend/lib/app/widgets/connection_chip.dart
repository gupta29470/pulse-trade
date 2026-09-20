/// The connection-status surface of the app — and the only one.
///
/// A banner that interrupts the product every time the network blinks is worse
/// than a quiet, always-truthful chip, so connection state is reported in two
/// ways and nowhere else:
///
/// * this chip, always present in the market telemetry strip and never covering
/// content.
/// * per-section `CachedTag`s, which carry the "as of" time of the data a
/// section is actually showing.
///
/// There is therefore no full-screen "no internet" wrapper either: pages keep
/// rendering cached values. This widget deliberately owns only *presentation* of
/// that state. It takes a [ConnectionChipState] rather than a transport enum so
/// it stays free of `lib/data/**`: mapping socket state, the market engine's
/// state and cache freshness onto one chip state is the job of the layer that
/// actually knows those things.
///
/// Status is never conveyed by colour alone: every state renders a
/// text label, and the label is present even in [ConnectionChip.compact] mode.
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
import '../theme/app_radii.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// What the chip is currently saying.
///
/// The values are presentation states, not transport states: several of them can
/// be true of the same socket. They are ordered from healthiest to least usable,
/// which is also the order a status resolution should fall through.
enum ConnectionChipState {
  /// A live socket and fresh values. The only state that may be called `LIVE`.
  live,

  /// Connected, but the backend reports a lower delivery tier or otherwise
  /// reduced fidelity. Values are arriving, just less often.
  degraded,

  /// The lowest tier: updates are rare enough that the user must not read the
  /// screen as a tick-by-tick feed.
  minimal,

  /// Values on screen are cached and past their freshness window. Rendered
  /// dimmer than [live], never red: stale data is still useful data.
  stale,

  /// No transport and no reachability. Cached values remain on screen.
  offline,

  /// The market generator is paused. This is honest data — the values are
  /// frozen rather than missing — so it must not look like a failure.
  paused,

  /// A dial is in flight, or the app has not yet had a first frame.
  connecting,

  /// Cached values are being shown that are still within their freshness
  /// window, so nothing is wrong yet.
  cached,
}

/// A 20dp pill with a 6dp dot and a text label, e.g. `LIVE 74ms`.
///
/// The chip is a read-only surface, so it has no touch target of its own. If a
/// caller ever wraps it in a tap gesture, that caller owes the user a 48dp hit
/// area and a `Semantics(button: true)` label.
class ConnectionChip extends StatelessWidget {
  /// Creates a chip.
  ///
  /// [rttMs] is only meaningful for [ConnectionChipState.live] and [cachedAge]
  /// only for [ConnectionChipState.cached]; both are optional because the app
  /// often knows the state before it knows the number, and showing no number is
  /// better than showing a guess.
  const ConnectionChip({
    super.key,
    required this.state,
    this.rttMs,
    this.cachedAge,
    this.compact = false,
  });

  /// The state to render.
  final ConnectionChipState state;

  /// Round-trip time to the backend, in milliseconds, when it is known.
  final int? rttMs;

  /// Age of the cached values being displayed, when it is known.
  final Duration? cachedAge;

  /// Tightens the horizontal padding for dense strips.
  ///
  /// It never removes the label: a dot alone would encode status in colour, and
  /// status is never carried by colour alone.
  final bool compact;

  /// Pill height.
  static const double _pillMinHeight = 20;

  /// Dot diameter.
  static const double _dotSize = 6;

  @override
  Widget build(BuildContext context) {
    final _ChipPalette palette = _paletteFor(state);
    return Semantics(
      container: true,
      // The visible label is an abbreviation and the dot is decorative, so the
      // subtree's own semantics are replaced by one composed sentence.
      excludeSemantics: true,
      label: _semanticsLabel(),
      child: AnimatedContainer(
        duration: AppMotion.chipPulse,
        curve: Curves.easeOut,
        // A minimum height rather than a fixed one: a fixed 20dp would clip the
        // label at a 1.3 text scale, which the layout must survive.
        constraints: const BoxConstraints(minHeight: _pillMinHeight),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? AppSpacing.space2xs : AppSpacing.spaceXs,
        ),
        decoration: BoxDecoration(
          // Transparent on purpose: the chip shares a strip with the numbers,
          // and a filled pill would read as something laid over them.
          color: AppColors.transparent,
          borderRadius: AppRadii.microAll,
          border: Border.all(color: palette.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: _dotSize,
              height: _dotSize,
              decoration: BoxDecoration(
                color: palette.dot,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.space2xs),
            Text(
              _label(),
              style: AppTypography.labelSm.copyWith(color: palette.label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// The three tokens one state resolves to.
  static _ChipPalette _paletteFor(ConnectionChipState state) => switch (state) {
    // Direction/accent colours on the healthy states, and the outline token on
    // everything that is merely quiet, so a degraded feed is visible before it
    // is alarming.
    ConnectionChipState.live => const _ChipPalette(
      border: AppColors.bull,
      dot: AppColors.bull,
      label: AppColors.bull,
    ),
    ConnectionChipState.degraded => const _ChipPalette(
      border: AppColors.warn,
      dot: AppColors.warn,
      label: AppColors.warn,
    ),
    ConnectionChipState.paused => const _ChipPalette(
      border: AppColors.warn,
      dot: AppColors.warn,
      label: AppColors.warn,
    ),
    ConnectionChipState.minimal => const _ChipPalette(
      border: AppColors.bear,
      dot: AppColors.bear,
      label: AppColors.bear,
    ),
    ConnectionChipState.stale => const _ChipPalette(
      border: AppColors.outline,
      dot: AppColors.textSecondary,
      label: AppColors.textSecondary,
    ),
    ConnectionChipState.connecting => const _ChipPalette(
      border: AppColors.outline,
      dot: AppColors.textSecondary,
      label: AppColors.textSecondary,
    ),
    ConnectionChipState.cached => const _ChipPalette(
      border: AppColors.outline,
      dot: AppColors.textSecondary,
      label: AppColors.textSecondary,
    ),
    ConnectionChipState.offline => const _ChipPalette(
      border: AppColors.outline,
      dot: AppColors.textDisabled,
      label: AppColors.textDisabled,
    ),
  };

  /// The visible, uppercase label. Always non-empty: this string is the reason
  /// the chip is legible in greyscale.
  String _label() {
    final int? rtt = rttMs;
    final Duration? age = cachedAge;
    return switch (state) {
      ConnectionChipState.live => rtt == null ? 'LIVE' : 'LIVE ${rtt}ms',
      ConnectionChipState.degraded => 'DEGRADED',
      ConnectionChipState.minimal => 'MINIMAL',
      ConnectionChipState.stale => 'STALE',
      ConnectionChipState.offline => 'OFFLINE',
      ConnectionChipState.paused => 'PAUSED',
      ConnectionChipState.connecting => 'CONNECTING',
      // The age is appended rather than replacing the label: `CACHED` states
      // what the data is, the age says how much to trust it.
      ConnectionChipState.cached =>
        age == null ? 'CACHED' : 'CACHED ${_formatAge(age)}',
    };
  }

  /// The spoken form of the chip, expanded so a screen reader does not have to
  /// interpret an abbreviation.
  String _semanticsLabel() {
    final int? rtt = rttMs;
    final Duration? age = cachedAge;
    return switch (state) {
      ConnectionChipState.live =>
        rtt == null
            ? 'Connection live'
            : 'Connection live, round trip $rtt milliseconds',
      ConnectionChipState.degraded =>
        'Connection degraded, updates are arriving less often',
      ConnectionChipState.minimal => 'Connection minimal, low fidelity updates',
      ConnectionChipState.stale => 'Connection stale, cached values shown',
      ConnectionChipState.offline => 'Connection offline, cached values shown',
      ConnectionChipState.paused => 'Market generator paused, values frozen',
      ConnectionChipState.connecting => 'Connecting',
      ConnectionChipState.cached =>
        age == null
            ? 'Cached values shown'
            : 'Cached values shown, ${_formatAge(age)} old',
    };
  }

  /// A coarse age for a 10dp label: seconds under a minute, then minutes, then
  /// hours. Coarse on purpose — `CachedTag` carries the exact timestamp.
  static String _formatAge(Duration age) {
    if (age.inSeconds < 60) return '${age.inSeconds}s';
    if (age.inMinutes < 60) return '${age.inMinutes}m';
    return '${age.inHours}h';
  }
}

/// The three colours one chip state resolves to.
final class _ChipPalette {
  /// Creates a palette.
  const _ChipPalette({
    required this.border,
    required this.dot,
    required this.label,
  });

  /// 1dp pill border.
  final Color border;

  /// The 6dp status dot.
  final Color dot;

  /// The uppercase label, which must stay legible at `labelSm` size.
  final Color label;
}
