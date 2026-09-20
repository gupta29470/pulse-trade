import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// The title row of a screen section, with an optional trailing widget and a
/// 1dp rule beneath.
///
/// The trailing slot is what makes a `CachedTag` possible: a section that is
/// showing cached data marks *itself*, in its own header, instead of the app
/// interrupting the whole screen with a banner. The divider is inset by
/// [padding] so it aligns with the title above it.
class SectionHeader extends StatelessWidget {
  /// Creates a section header.
  ///
  /// [padding] defaults to 12dp horizontal, matching [AppSpacing.spaceSm] and
  /// the rest of the grid's horizontal rhythm.
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding,
  });

  /// Section title, in `headlineSm`.
  final String title;

  /// Optional right-aligned widget, typically a `CachedTag`.
  final Widget? trailing;

  /// Overrides the 12dp horizontal inset.
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    // An empty box rather than a conditional child: the slot is layout-neutral
    // when there is nothing to show, and the row keeps a single shape.
    final Widget trailingSlot = trailing ?? const SizedBox.shrink();
    return Padding(
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: AppSpacing.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: AppTypography.headlineSm.copyWith(
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              trailingSlot,
            ],
          ),
          // The theme collapses a divider to a 1dp hairline, so the gap above it
          // has to come from here; without it the rule would touch the title.
          const SizedBox(height: AppSpacing.space2xs),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
