import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_radii.dart';
import '../theme/app_spacing.dart';

/// A level-1 surface: the container every panel of the terminal sits in.
///
/// Elevation is tonal, never shadowed. [AppColors.surface1] over the
/// canvas plus a 1dp [AppColors.outline] border reads as "one level up" without
/// the soft blur a shadow would add to a deliberately hard-edged layout.
///
/// The theme's `cardTheme` carries the same colour, radius and border, so a
/// plain `Card` and an `AppCard` render identically; this widget exists because
/// it also provides the tap affordance and the standard 12dp internal padding.
class AppCard extends StatelessWidget {
  /// Creates a card.
  ///
  /// [padding] defaults to [AppSpacing.spaceSm] on every side. Pass
  /// `EdgeInsets.zero` when the child manages its own inset — for example a card
  /// whose first row is a `CardHeader` that owns the horizontal padding and must
  /// reach the card's edges with its divider.
  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.onTap,
  });

  /// Content of the card.
  final Widget child;

  /// Inset applied around [child]; defaults to 12dp on every side.
  final EdgeInsetsGeometry? padding;

  /// Space left outside the card, so a column of cards needs no wrapper.
  final EdgeInsetsGeometry? margin;

  /// When non-null the whole card becomes tappable with an ink response.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Widget content = Padding(
      padding: padding ?? const EdgeInsets.all(AppSpacing.spaceSm),
      child: child,
    );
    final VoidCallback? tap = onTap;
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: Material(
        color: AppColors.surface1,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadii.componentAll,
          side: BorderSide(color: AppColors.outline),
        ),
        clipBehavior: Clip.antiAlias,
        // The ink response has to live inside this card's own Material: a
        // splash painted on the scaffold's material would be hidden behind the
        // card's opaque fill and the tap would look like nothing happened.
        child: tap == null ? content : InkWell(onTap: tap, child: content),
      ),
    );
  }
}
