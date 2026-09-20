import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// The "there is nothing here" state: icon, title, explanation, retry.
///
/// Sized by [AppSpacing.space2xl] margins and centred, because an empty screen
/// has nothing else to lay out and the whitespace *is* the layout. The retry
/// button is optional: an empty watchlist has nothing to retry, while a failed
/// history request does, and offering a button that cannot help is worse than
/// offering none.
class EmptyState extends StatelessWidget {
  /// Creates an empty state.
  ///
  /// [retryLabel] is overridable so a caller can say what retrying does, e.g.
  /// `Reload history`; the default is deliberately plain.
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon,
    this.onRetry,
    this.retryLabel = 'Retry',
  });

  /// One-line statement of what is missing, in `headlineSm`.
  final String title;

  /// Optional supporting sentence, in `bodyMd`. This is where a cached-but-empty
  /// situation should explain that the data is old rather than absent.
  final String? message;

  /// Optional leading glyph, drawn at 32dp in the disabled tone so it reads as
  /// absence rather than as a state.
  final IconData? icon;

  /// When non-null, renders a retry button that calls this.
  final VoidCallback? onRetry;

  /// Label for the retry button.
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final IconData? iconData = icon;
    final String? messageText = message;
    final VoidCallback? retry = onRetry;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.space2xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (iconData != null)
              Icon(iconData, size: 32, color: AppColors.textDisabled),
            if (iconData != null) const SizedBox(height: AppSpacing.spaceSm),
            Text(
              title,
              style: AppTypography.headlineSm.copyWith(
                color: AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            if (messageText != null) ...<Widget>[
              const SizedBox(height: AppSpacing.spaceXs),
              Text(
                messageText,
                style: AppTypography.bodyMd.copyWith(
                  color: AppColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (retry != null) ...<Widget>[
              const SizedBox(height: AppSpacing.spaceMd),
              // Unstyled on purpose: the theme's primary colour is `bull`, and
              // the button inherits the 48dp minimum tap target with it.
              TextButton(onPressed: retry, child: Text(retryLabel)),
            ],
          ],
        ),
      ),
    );
  }
}
