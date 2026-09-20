import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// The strip that names a section inside a card.
///
/// The height is fixed rather than intrinsic so that a column of cards has
/// headers that all agree on where the divider sits — that agreement is what
/// makes a dense screen scannable. The height is independent of [trailing], so
/// adding a `CachedTag` never moves the divider.
class CardHeader extends StatelessWidget {
  /// Creates a header.
  ///
  /// [padding] defaults to 12dp horizontal; it is overridable for
  /// the rare card that is inset differently from the grid.
  const CardHeader({
    super.key,
    required this.title,
    this.trailing,
    this.showDivider = true,
    this.padding,
  });

  /// Section title, in `headlineSm`.
  final String title;

  /// Optional right-aligned widget, typically a `CachedTag`.
  final Widget? trailing;

  /// Whether to draw the 1dp bottom divider. Set false when the header is the
  /// last thing in its card, or when the next row draws its own top border.
  final bool showDivider;

  /// Overrides the 12dp horizontal inset.
  final EdgeInsetsGeometry? padding;

  /// The header height.
  static const double _height = 36;

  @override
  Widget build(BuildContext context) {
    // An empty box rather than a conditional child: the slot is layout-neutral
    // when there is nothing to show, and the row keeps a single shape.
    final Widget trailingSlot = trailing ?? const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: _height,
          child: Padding(
            padding:
                padding ??
                const EdgeInsets.symmetric(horizontal: AppSpacing.spaceSm),
            child: Row(
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
          ),
        ),
        // Explicit height 1 rather than the theme's divider space: the divider
        // belongs to the header's 36dp, not to the content below it.
        if (showDivider) const Divider(height: 1),
      ],
    );
  }
}
