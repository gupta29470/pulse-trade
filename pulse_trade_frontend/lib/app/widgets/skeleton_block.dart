import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
import '../theme/app_radii.dart';

/// A pulsing placeholder for content that has not arrived yet.
///
/// Used for chart and history loading, where an empty rectangle is worse than an
/// honest placeholder: reserving the real height means the layout does not jump
/// when the data lands, and a slow pulse reads as "coming" rather than as a
/// broken or blank region.
///
/// The widget itself is immutable and `const`; the ticker lives in the `State`,
/// which is why the pulse cannot be expressed as a `const` decoration.
class SkeletonBlock extends StatefulWidget {
  /// Creates a skeleton block.
  ///
  /// [height] defaults to 16dp — one line of text — and [borderRadius] defaults
  /// to [AppRadii.microAll]. Leave [width] null to fill the available width.
  const SkeletonBlock({
    super.key,
    this.height = 16,
    this.width,
    this.borderRadius,
  });

  /// Height of the placeholder. Set it to the height of the content it stands
  /// in for, so nothing moves when the real content replaces it.
  final double height;

  /// Width of the placeholder, or null to fill the available width.
  final double? width;

  /// Corner radius, or null for [AppRadii.microAll].
  final BorderRadius? borderRadius;

  @override
  State<SkeletonBlock> createState() => _SkeletonBlockState();
}

/// State of [SkeletonBlock]: owns the repeat controller.
class _SkeletonBlockState extends State<SkeletonBlock>
    with SingleTickerProviderStateMixin {
  /// The pulse. Repeats in both directions so there is no visible jump at the
  /// end of a cycle.
  late final AnimationController _controller;

  /// Opacity of the block: never fully transparent, because a placeholder that
  /// disappears entirely looks like a layout bug, and never fully opaque,
  /// because it must not be mistaken for content.
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppMotion.skeletonPulse,
    )..repeat(reverse: true);
    _opacity = _controller.drive(Tween<double>(begin: 0.35, end: 1.0));
  }

  @override
  void dispose() {
    // A ticker that outlives its state keeps the whole app's frame pipeline
    // busy and trips the debug assertion in the engine.
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: AppColors.textDisabled,
          borderRadius: widget.borderRadius ?? AppRadii.microAll,
        ),
      ),
    );
  }
}
