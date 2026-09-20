import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme/app_colors.dart';
import '../theme/app_radii.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// The "as of" marker attached to a section that is showing cached data.
///
/// **This tag replaces the connection banner.** Instead of interrupting the
/// whole screen when the feed goes quiet, each affected section — chart, book,
/// trades, price — carries the age of the data it is actually showing, in its
/// own header. The rest of the screen keeps working, and a reader can tell
/// exactly which numbers are old rather than being told that "something" is
/// wrong. That is why there is no banner widget anywhere in `lib/app/widgets/`.
///
/// [stale] marks the age as past its freshness window. It changes the tag from
/// the quiet outline token to `warn`, and the `kind` text always says which of
/// the two it is, so the distinction survives greyscale.
class CachedTag extends StatelessWidget {
  /// Creates a tag.
  ///
  /// [kind] is a short uppercase string — `CACHED` while the values are within
  /// their freshness window, `STALE` once they are not.
  const CachedTag({
    super.key,
    required this.kind,
    required this.asOf,
    this.stale = false,
  });

  /// Short uppercase kind label, `CACHED` or `STALE`.
  final String kind;

  /// When the cached values were captured. Rendered in UTC.
  final DateTime asOf;

  /// Whether [asOf] is past the freshness window, which switches the tag to the
  /// warn tone.
  final bool stale;

  /// A fixed `HH:mm:ss` formatter.
  ///
  /// A timestamp on a data-bearing row must not change shape with the device
  /// locale: a fixed pattern puts it on a tabular-figure token so it cannot
  /// shift the row, and a locale-dependent pattern would reintroduce exactly
  /// that shift.
  /// Static because constructing a `DateFormat` per build is needless work on a
  /// row that rebuilds on every tick.
  static final DateFormat _timeFormat = DateFormat('HH:mm:ss');

  @override
  Widget build(BuildContext context) {
    // UTC, always: the backend stamps in UTC and the client must not imply that
    // a cached value was captured in the user's local time zone.
    final String timestamp = _timeFormat.format(asOf.toUtc());
    final bool isStale = stale;
    return Semantics(
      container: true,
      excludeSemantics: true,
      // Spelled out for a screen reader, including the time zone that the
      // visible label cannot show in its three-letter budget.
      label: '$kind, as of $timestamp UTC',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.space2xs,
          vertical: AppSpacing.space2xs / 2,
        ),
        decoration: BoxDecoration(
          borderRadius: AppRadii.microAll,
          border: Border.all(
            color: isStale ? AppColors.warn : AppColors.outline,
          ),
        ),
        child: Text(
          '$kind · as of $timestamp',
          style: AppTypography.labelSm.copyWith(
            color: isStale ? AppColors.warn : AppColors.textSecondary,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
