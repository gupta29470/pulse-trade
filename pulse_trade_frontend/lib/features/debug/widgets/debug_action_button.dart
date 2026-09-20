import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_radii.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';

/// One control of the debug console.
///
/// Every control on the screen is this button so they cannot drift apart: same
/// height, same monospace label, same disabled treatment while an action is in
/// flight. [destructive] marks the actions that break something on purpose
/// (drop a session, fail the metrics store, force a disconnect) so a tester
/// cannot trigger one by muscle memory — the colour is paired with the label's
/// own wording, never colour alone.
class DebugActionButton extends StatelessWidget {
  /// Creates a debug action button.
  ///
  /// [description] becomes a tooltip explaining the fault's expected client
  /// reaction, which is the part a tester actually needs.
  const DebugActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.destructive = false,
    this.selected = false,
    this.description,
  });

  /// Button copy.
  final String label;

  /// The action, or `null` to disable the button (no session selected, busy).
  final VoidCallback? onPressed;

  /// Whether this button's action is currently running.
  final bool busy;

  /// Whether the action intentionally breaks something.
  final bool destructive;

  /// Whether this control is the active choice among its siblings — the tier the
  /// session is pinned to.
  ///
  /// Shown as a filled accent surface *and* the label's own `· active` suffix: the
  /// widget's rule is that colour never carries meaning alone, and this is the one
  /// place on the screen where "which one is in force" is the question being asked.
  final bool selected;

  /// Optional tooltip explaining what the action should cause.
  final String? description;

  @override
  Widget build(BuildContext context) {
    final Color foreground = destructive
        ? AppColors.bear
        : (selected ? AppColors.bull : AppColors.textPrimary);
    final Widget button = OutlinedButton(
      onPressed: busy ? null : onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: foreground,
        side: BorderSide(
          color: selected
              ? AppColors.bull
              : (destructive ? AppColors.bear : AppColors.outlineFocus),
          width: selected ? 1.5 : 1,
        ),
        backgroundColor: selected
            ? AppColors.bull.withValues(alpha: 0.14)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.spaceSm,
          vertical: AppSpacing.spaceXs,
        ),
        // The design system's minimum touch target applies to debug controls
        // too: they are tapped on a phone during a demo.
        minimumSize: const Size(0, AppSpacing.minTouchTarget),
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadii.componentAll,
        ),
        textStyle: AppTypography.labelMd,
      ),
      child: busy
          ? const SizedBox(
              height: 14,
              width: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );

    final String? descriptionText = description;
    if (descriptionText == null) return button;
    return Tooltip(message: descriptionText, child: button);
  }
}
