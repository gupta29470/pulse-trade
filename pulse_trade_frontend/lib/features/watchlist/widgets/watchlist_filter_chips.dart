import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_radii.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/features/watchlist/watchlist_state.dart';

/// The watchlist filter chips: `All n`, `Favourites n`, `Add Asset`.
///
/// The counts come from the state rather than from the filtered list, so the
/// chip always shows how many rows exist behind it even while another filter is
/// active — a count that changed with the selection could not tell the user
/// where a row went.
///
/// The row scrolls horizontally instead of wrapping: a chip row that reflowed
/// onto two lines would move the list below it every time a count gained a
/// digit.
class WatchlistFilterChips extends StatelessWidget {
  /// Creates the chip row.
  ///
  /// [onAddAsset] is optional so the row can be shown without an "Add Asset"
  /// affordance; when it is null the chip is omitted rather than rendered dead.
  const WatchlistFilterChips({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.allCount,
    required this.favouriteCount,
    this.onAddAsset,
  });

  /// The filter currently applied.
  final WatchlistFilter selected;

  /// Called with the chip the user tapped.
  final ValueChanged<WatchlistFilter> onSelected;

  /// Rows in the whole watchlist.
  final int allCount;

  /// Rows the user starred, regardless of the active filter.
  final int favouriteCount;

  /// Opens the market picker. Omitted from the row when null.
  final VoidCallback? onAddAsset;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? addAsset = onAddAsset;
    return SizedBox(
      height: AppSpacing.minTouchTarget,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenMarginPhone,
        ),
        children: <Widget>[
          _FilterChip(
            label: 'All $allCount',
            isSelected: selected == WatchlistFilter.all,
            onSelected: () => onSelected(WatchlistFilter.all),
          ),
          const SizedBox(width: AppSpacing.spaceXs),
          _FilterChip(
            label: 'Favourites $favouriteCount',
            isSelected: selected == WatchlistFilter.favourites,
            onSelected: () => onSelected(WatchlistFilter.favourites),
          ),
          if (addAsset != null) ...<Widget>[
            const SizedBox(width: AppSpacing.spaceXs),
            _AddAssetChip(onPressed: addAsset),
          ],
        ],
      ),
    );
  }
}

/// One selectable filter chip.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.isSelected,
    required this.onSelected,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    // Selected state is carried by both the fill and the text colour, and the
    // chip is a real `ChoiceChip`, so a screen reader announces the selection
    // instead of relying on the paint.
    return Center(
      child: ChoiceChip(
        label: Text(
          label,
          style: AppTypography.labelMd.copyWith(
            color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
        selected: isSelected,
        onSelected: (bool _) => onSelected(),
        showCheckmark: false,
        backgroundColor: AppColors.surface1,
        selectedColor: AppColors.surface2,
        side: BorderSide(
          color: isSelected ? AppColors.outlineFocus : AppColors.outline,
        ),
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.microAll),
      ),
    );
  }
}

/// The `Add Asset` chip, which opens the market picker.
class _AddAssetChip extends StatelessWidget {
  const _AddAssetChip({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ActionChip(
        onPressed: onPressed,
        avatar: const Icon(Icons.add, size: 14, color: AppColors.bull),
        label: Text(
          'Add Asset',
          style: AppTypography.labelMd.copyWith(color: AppColors.bull),
        ),
        backgroundColor: AppColors.surface1,
        side: const BorderSide(color: AppColors.outline),
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.microAll),
      ),
    );
  }
}
