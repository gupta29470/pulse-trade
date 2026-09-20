/// A one-line strip for **engine conditions only**.
///
/// `InlineNotice` exists for messages the market generator produces about
/// itself: `Market generator paused`, `Market reset — resynchronising`, and
/// similar. It is **not** a connection indicator and must never be used for
/// connectivity.
///
/// Connectivity is the always-visible `ConnectionChip` plus per-section
/// `CachedTag`s. A strip that appeared whenever the network blipped would be
/// a persistent banner for connectivity, and it would train the user to dismiss
/// a component that also carries real engine news.
/// Passing a connectivity message to this widget is a review failure, not a
/// style preference.
///
/// It is non-modal and it never blocks: the notice occupies a single strip of
/// the layout, and the rest of the screen stays live underneath it.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// How loudly a notice speaks.
enum InlineNoticeTone {
  /// A degradation of the engine's own state: warn-tinted strip with a warn
  /// accent, and an exclamation glyph so the tone does not rest on colour.
  warn,

  /// Neutral information: a plain `surface2` strip with an information glyph.
  info,
}

/// A non-modal, auto-dismissing strip for engine conditions.
///
/// The widget owns the *timer*, not the *truth*: when [onDismiss] is provided it
/// fires after [AppMotion.noticeAutoDismiss], and the parent removes the
/// notice. Making the parent own removal keeps one source of truth for "is there
/// a notice", which is what stops a stale strip from surviving a state change.
class InlineNotice extends StatefulWidget {
  /// Creates a notice.
  ///
  /// Without [onDismiss] the notice is permanent and not dismissible — useful
  /// for a condition that is still true and has no dismissal to offer.
  const InlineNotice({
    super.key,
    required this.message,
    this.onDismiss,
    this.tone = InlineNoticeTone.warn,
  });

  /// The single line of text. Kept to one line by construction: a notice that
  /// wraps is a banner.
  final String message;

  /// Called when the notice auto-dismisses or when the user dismisses it.
  final VoidCallback? onDismiss;

  /// How loudly the notice speaks.
  final InlineNoticeTone tone;

  @override
  State<InlineNotice> createState() => _InlineNoticeState();
}

/// State of [InlineNotice]: owns the auto-dismiss timer.
class _InlineNoticeState extends State<InlineNotice> {
  /// Pending auto-dismiss, if any.
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scheduleDismiss();
  }

  @override
  void didUpdateWidget(InlineNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new message restarts the clock: the user has not had a chance to read
    // the new sentence yet. The callback's *identity* is deliberately not
    // compared — a parent that rebuilds on every tick would otherwise hand us a
    // fresh closure each frame and the notice would never expire.
    final bool gainedDismiss =
        oldWidget.onDismiss == null && widget.onDismiss != null;
    if (oldWidget.message != widget.message || gainedDismiss) {
      _scheduleDismiss();
    }
  }

  @override
  void dispose() {
    // Without this, a dismissed strip would still fire its callback into a
    // disposed parent.
    _timer?.cancel();
    super.dispose();
  }

  /// Arms (or re-arms) the auto-dismiss timer.
  void _scheduleDismiss() {
    _timer?.cancel();
    final VoidCallback? dismiss = widget.onDismiss;
    if (dismiss == null) return;
    _timer = Timer(AppMotion.noticeAutoDismiss, dismiss);
  }

  @override
  Widget build(BuildContext context) {
    final bool isWarn = widget.tone == InlineNoticeTone.warn;
    final Color accent = isWarn ? AppColors.warn : AppColors.outlineFocus;
    final VoidCallback? dismiss = widget.onDismiss;
    return Semantics(
      container: true,
      // Announced when it appears, because it carries news the user did not ask
      // for; the message text stays the semantics content so the dismiss button
      // below keeps its own semantics.
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isWarn ? AppColors.warnBannerBg : AppColors.surface2,
          border: Border(
            left: BorderSide(color: accent, width: 2),
            top: const BorderSide(color: AppColors.outline),
            right: const BorderSide(color: AppColors.outline),
            bottom: const BorderSide(color: AppColors.outline),
          ),
        ),
        child: ConstrainedBox(
          // 48dp so the dismiss control keeps the minimum touch target;
          // the text itself is still a single line.
          constraints: const BoxConstraints(
            minHeight: AppSpacing.minTouchTarget,
          ),
          child: Row(
            children: <Widget>[
              const SizedBox(width: AppSpacing.spaceSm),
              ExcludeSemantics(
                // Decorative: the message says what happened, and the shape of
                // the glyph distinguishes warn from info without relying on
                // colour.
                child: Icon(
                  isWarn
                      ? Icons.warning_amber_rounded
                      : Icons.info_outline_rounded,
                  size: 16,
                  color: accent,
                ),
              ),
              const SizedBox(width: AppSpacing.spaceXs),
              Expanded(
                child: Text(
                  widget.message,
                  // Primary on the warn tint for contrast; secondary is enough
                  // on the flat surface2 of an info notice.
                  style: AppTypography.bodyMd.copyWith(
                    color: isWarn
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (dismiss != null)
                IconButton(
                  onPressed: dismiss,
                  icon: const Icon(Icons.close_rounded),
                  iconSize: 16,
                  padding: EdgeInsets.zero,
                  color: AppColors.textSecondary,
                  tooltip: 'Dismiss notice',
                )
              else
                const SizedBox(width: AppSpacing.spaceSm),
            ],
          ),
        ),
      ),
    );
  }
}
