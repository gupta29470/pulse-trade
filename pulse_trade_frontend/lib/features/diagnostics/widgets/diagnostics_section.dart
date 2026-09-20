import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';

/// One `label → value` line of the diagnostics readout.
///
/// A value object rather than a pair of widget arguments so the page can build
/// its rows as data, in one expression per section, and so a widget test can
/// assert the exact strings the screen renders without walking a tree.
final class DiagnosticRow extends Equatable {
  /// Creates a row.
  ///
  /// [valueColor] is the only styling a row carries: the diagnostics screen uses
  /// colour for state (`bull` for healthy, `warn` for degraded, `bear` for a
  /// fault) and never for decoration, so nothing else needs theming per row.
  const DiagnosticRow(this.label, this.value, {this.valueColor});

  /// Left column, the metric name.
  final String label;

  /// Right column, the formatted value.
  final String value;

  /// Optional semantic colour for the value.
  final Color? valueColor;

  @override
  List<Object?> get props => <Object?>[label, value, valueColor];

  @override
  String toString() => 'DiagnosticRow($label: $value)';
}

/// A titled block of [DiagnosticRow]s.
///
/// The two columns are a fixed-width label and an expanded value so that every
/// section — Session, Connectivity, Feed & L2, Persistence — aligns down the
/// page. That alignment is the whole point of a diagnostics readout: a reviewer
/// scans the *values* column and must never have to re-find it.
class DiagnosticsSection extends StatelessWidget {
  /// Creates a section.
  ///
  /// [trailing] is the section's headline status (`3 / 4 ONLINE`, `SYNCED`), not
  /// a row: it sits on the title line because it summarises the block rather
  /// than being another datum inside it.
  const DiagnosticsSection({
    super.key,
    required this.title,
    required this.rows,
    this.trailing,
  });

  /// Section name, rendered in the monospace scale.
  final String title;

  /// The rows, in display order.
  final List<DiagnosticRow> rows;

  /// Optional right-aligned headline status.
  final String? trailing;

  /// The label column width. Wide enough for the longest label
  /// (`Out-of-order Trades`) without wrapping.
  static const double labelWidth = 148;

  @override
  Widget build(BuildContext context) {
    final String? trailingText = trailing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(
            top: AppSpacing.spaceSm,
            bottom: AppSpacing.spaceXs,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: AppTypography.labelMd.copyWith(
                    color: AppColors.textSecondary,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              if (trailingText != null)
                Text(
                  trailingText,
                  style: AppTypography.labelMd.copyWith(color: AppColors.bull),
                ),
            ],
          ),
        ),
        for (final DiagnosticRow row in rows) _DiagnosticRowView(row: row),
      ],
    );
  }
}

/// The rendered form of one [DiagnosticRow].
class _DiagnosticRowView extends StatelessWidget {
  const _DiagnosticRowView({required this.row});

  final DiagnosticRow row;

  @override
  Widget build(BuildContext context) {
    final Color valueColor = row.valueColor ?? AppColors.textPrimary;
    return Semantics(
      // One merged node per row so a screen reader announces "Session ID,
      // sess_01J8…, a3f9c2" instead of reading two unrelated strings.
      container: true,
      label: '${row.label} ${row.value}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.space2xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: DiagnosticsSection.labelWidth,
              child: Text(
                row.label,
                style: AppTypography.labelSm.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.spaceSm),
            Expanded(
              child: Text(
                row.value,
                style: AppTypography.labelSm.copyWith(color: valueColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
