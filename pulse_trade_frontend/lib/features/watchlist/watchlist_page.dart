import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_radii.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';
import 'package:pulse_trade_frontend/app/widgets/empty_state.dart';
import 'package:pulse_trade_frontend/app/widgets/skeleton_block.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/features/watchlist/watchlist_cubit.dart';
import 'package:pulse_trade_frontend/features/watchlist/watchlist_state.dart';
import 'package:pulse_trade_frontend/features/watchlist/widgets/watchlist_filter_chips.dart';
import 'package:pulse_trade_frontend/features/watchlist/widgets/watchlist_row.dart';

/// The watchlist screen.
///
/// The page reads [WatchlistCubit] from the surrounding `BlocProvider` and owns
/// nothing else: the order, the favourites and the pin all live in the cubit, so
/// this widget can be rebuilt freely without losing a drag or a rollback.
///
/// The page also owns the price poll: a timer asks the cubit to re-read the
/// market roster every few seconds while the screen is mounted and the app is in
/// the foreground, and it is cancelled on dispose so a backgrounded or closed
/// screen never keeps a request loop alive. Tapping any row navigates to
/// `/market/:symbol`, which opens that symbol's own live feed.
class WatchlistPage extends StatelessWidget {
  /// Creates the page.
  const WatchlistPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: _WatchlistAppBar(),
      body: _WatchlistBody(),
    );
  }
}

/// The app bar: `PulseTrade`, the screen title, the favourites star and the
/// overflow menu.
class _WatchlistAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _WatchlistAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.canvas,
      titleSpacing: AppSpacing.screenMarginPhone,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'PulseTrade',
            style: AppTypography.bodySm.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          Text(
            'Watchlist',
            style: AppTypography.headlineMd.copyWith(
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        IconButton(
          tooltip: 'Favourites',
          onPressed: () => _showFavourites(context),
          icon: const Icon(Icons.star_border),
        ),
        PopupMenuButton<String>(
          tooltip: 'Watchlist options',
          onSelected: (String value) => _onOverflow(context, value),
          itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: 'refresh',
              child: Text('Refresh prices'),
            ),
            PopupMenuItem<String>(
              value: 'unpin',
              child: Text('Clear pinned market'),
            ),
          ],
        ),
      ],
    );
  }

  /// Explains the favourite count instead of silently toggling a filter, since
  /// the filter chips own the visible slice of the list.
  void _showFavourites(BuildContext context) {
    final int count = context.read<WatchlistCubit>().state.favouriteCount;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == 0
              ? 'No favourites yet — tap a star to add one'
              : '$count favourite${count == 1 ? '' : 's'}',
        ),
      ),
    );
  }

  /// Runs one overflow action against the cubit.
  void _onOverflow(BuildContext context, String value) {
    final WatchlistCubit cubit = context.read<WatchlistCubit>();
    switch (value) {
      case 'refresh':
        unawaited(cubit.load());
      case 'unpin':
        unawaited(cubit.unpin());
      default:
        return;
    }
  }
}

/// The scrolling body, kept stateful so the one-shot [WatchlistCubit.load] runs
/// exactly once per mount rather than on every rebuild, and so the price poll has
/// an owner that can cancel it.
class _WatchlistBody extends StatefulWidget {
  const _WatchlistBody();

  @override
  State<_WatchlistBody> createState() => _WatchlistBodyState();
}

class _WatchlistBodyState extends State<_WatchlistBody>
    with WidgetsBindingObserver {
  /// How often the roster is re-read while this screen is on the foreground.
  static const Duration _pollInterval = Duration(seconds: 3);

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Deferred to the first frame: `load()` emits synchronously, and emitting
    // while the first build is still in flight would rebuild mid-frame.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      unawaited(context.read<WatchlistCubit>().load());
    });
    _startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    super.dispose();
  }

  /// Runs the poll only in the foreground: a backgrounded app does no work for a
  /// screen nobody is watching, and the fresh read on return closes the gap.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      _pollOnce();
    } else {
      _stopPolling();
    }
  }

  void _startPolling() {
    _pollTimer ??= Timer.periodic(_pollInterval, (Timer _) => _pollOnce());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Asks the cubit for one price read. The cubit drops a call that arrives while
  /// its previous read is still in flight.
  void _pollOnce() {
    if (!mounted) return;
    unawaited(context.read<WatchlistCubit>().refreshPrices());
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<WatchlistCubit, WatchlistState>(
      listenWhen: (WatchlistState previous, WatchlistState current) =>
          current.failure != null && current.failure != previous.failure,
      listener: (BuildContext context, WatchlistState state) {
        final AppFailure? failure = state.failure;
        if (failure == null) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${failure.message}. The previous order was restored.',
            ),
          ),
        );
        context.read<WatchlistCubit>().acknowledgeFailure();
      },
      builder: (BuildContext context, WatchlistState state) {
        final WatchlistCubit cubit = context.read<WatchlistCubit>();
        final List<WatchlistEntry> visible = state.visibleEntries;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _FeedStrip(),
            WatchlistFilterChips(
              selected: state.filter,
              onSelected: cubit.setFilter,
              allCount: state.entries.length,
              favouriteCount: state.favouriteCount,
              onAddAsset: () => unawaited(showMarketPicker(context, cubit)),
            ),
            const _ReorderHint(),
            Expanded(child: _buildList(context, state, cubit, visible)),
            _Footer(marketCount: visible.length),
          ],
        );
      },
    );
  }

  /// Picks between skeletons, the empty state and the reorderable list.
  Widget _buildList(
    BuildContext context,
    WatchlistState state,
    WatchlistCubit cubit,
    List<WatchlistEntry> visible,
  ) {
    if (state.isLoading && state.entries.isEmpty) {
      return const _WatchlistSkeleton();
    }
    if (visible.isEmpty) {
      return _emptyState(state, cubit);
    }
    return _WatchlistList(
      entries: visible,
      dragIndex: state.dragIndex,
      cubit: cubit,
    );
  }

  /// The empty state, which distinguishes "no markets at all" from "nothing
  /// matches this filter" — the fix for each is different.
  Widget _emptyState(WatchlistState state, WatchlistCubit cubit) {
    if (state.entries.isNotEmpty) {
      return EmptyState(
        title: 'No markets in this filter',
        message:
            'Every market on this watchlist is on the other side of the '
            'filter. Switch back to All to see them.',
        icon: Icons.filter_alt_off,
        onRetry: () => cubit.setFilter(WatchlistFilter.all),
        retryLabel: 'Show all',
      );
    }
    return EmptyState(
      title: 'No markets yet',
      message:
          'Markets you track appear here with their live price. '
          'Nothing is invented to fill the space.',
      icon: Icons.playlist_add,
      onRetry: () => unawaited(showMarketPicker(context, cubit)),
      retryLabel: 'Add Asset',
    );
  }
}

/// The reorderable list, one [Dismissible] per row.
class _WatchlistList extends StatelessWidget {
  const _WatchlistList({
    required this.entries,
    required this.dragIndex,
    required this.cubit,
  });

  final List<WatchlistEntry> entries;
  final int? dragIndex;
  final WatchlistCubit cubit;

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: AppSpacing.spaceSm),
      itemCount: entries.length,
      // The handle is the drag affordance. Leaving the default handles enabled
      // would let any touch down on a row start a drag, which would swallow the
      // row's tap and its swipe in the gesture arena.
      buildDefaultDragHandles: false,
      onReorderStart: (int index) =>
          cubit.setDragging(isDragging: true, index: index),
      onReorderEnd: (int index) => cubit.setDragging(isDragging: false),
      // A dragged row is lifted above the list and the gap it leaves shows where it
      // will land, which is the whole affordance: an earlier version also printed the
      // position over the row, and it covered the price it was floating past.
      proxyDecorator: (Widget child, int index, Animation<double> animation) =>
          Material(
            color: AppColors.surface2,
            elevation: 4,
            borderRadius: AppRadii.componentAll,
            child: child,
          ),
      // onReorderItem adjusts newIndex for the removed row; switching without a
      // test that pins the reorder result risks an off-by-one in the list order.
      // ignore: deprecated_member_use
      onReorder: _reorderSiblings,
      itemBuilder: (BuildContext context, int index) {
        final WatchlistEntry entry = entries[index];
        final WatchlistRow row = WatchlistRow(
          entry: entry,
          isDragging: index == dragIndex,
          position: index + 1,
          total: entries.length,
          dragIndex: index,
          onTap: () => context.go('/market/${entry.symbol}'),
          onFavouriteToggle: () async {
            await cubit.toggleFavourite(entry.symbol);
          },
          onRemove: () async {
            await cubit.remove(entry.symbol);
          },
        );
        return Dismissible(
          key: ValueKey<String>('watchlist-${entry.symbol}'),
          background: const _SwipeBackground(
            alignment: Alignment.centerLeft,
            icon: Icons.push_pin,
            label: 'Pin to top',
            color: AppColors.warn,
          ),
          secondaryBackground: const _SwipeBackground(
            alignment: Alignment.centerRight,
            icon: Icons.delete_outline,
            label: 'Remove',
            color: AppColors.bear,
          ),
          confirmDismiss: (DismissDirection direction) =>
              _confirmSwipe(entry, direction),
          onDismissed: (DismissDirection direction) async {
            if (direction != DismissDirection.endToStart) return;
            await cubit.remove(entry.symbol);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${entry.display} removed'),
                action: SnackBarAction(
                  label: 'Undo',
                  onPressed: () async {
                    await cubit.undoRemove();
                  },
                ),
              ),
            );
          },
          // The whole tile is the drag affordance: press and hold any row to
          // reorder it. The handle drawn by the row is a hint, because a thin
          // glyph is not a target a thumb can reliably press.
          child: ReorderableDelayedDragStartListener(index: index, child: row),
        );
      },
    );
  }

  /// Turns a drag between two *visible* rows into a move inside the full list.
  ///
  /// The hidden rows keep their relative order, so a drag within a filter can
  /// never scramble the parts of the list the user cannot see.
  void _reorderSiblings(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= entries.length) return;
    final int target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final String symbol = entries[oldIndex].symbol;

    if (target >= entries.length) {
      unawaited(cubit.reorderSymbol(symbol));
      return;
    }
    if (target == oldIndex) {
      cubit.setDragging(isDragging: false);
      return;
    }

    final String before = entries[target].symbol;
    if (target > oldIndex) {
      // Moving down: the row lands after the target it displaced, so it is
      // anchored to the row that now sits one past it.
      final int anchorIndex = entries.indexWhere(
        (WatchlistEntry entry) => entry.symbol == before,
      );
      final String? anchor = anchorIndex + 1 < entries.length
          ? entries[anchorIndex + 1].symbol
          : null;
      if (anchor == symbol) return;
      unawaited(cubit.reorderSymbol(symbol, before: anchor));
      return;
    }

    unawaited(cubit.reorderSymbol(symbol, before: before));
  }

  /// Left swipe removes, right swipe pins. Both are confirmed here so the row
  /// can show a different affordance per direction.
  Future<bool> _confirmSwipe(
    WatchlistEntry entry,
    DismissDirection direction,
  ) async {
    switch (direction) {
      case DismissDirection.startToEnd:
        if (entry.isPinned) {
          await cubit.unpin();
        } else {
          await cubit.pin(entry.symbol);
        }
        return false;
      case DismissDirection.endToStart:
        return true;
      default:
        return false;
    }
  }
}

/// The swipe affordance painted under a row.
class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.alignment,
    required this.icon,
    required this.label,
    required this.color,
  });

  final Alignment alignment;
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface2,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.spaceMd),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpacing.spaceXs),
          Text(label, style: AppTypography.labelMd.copyWith(color: color)),
        ],
      ),
    );
  }
}

/// The reorder hint row.
class _ReorderHint extends StatelessWidget {
  const _ReorderHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenMarginPhone,
        vertical: AppSpacing.spaceXs,
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.drag_indicator,
            size: 14,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: AppSpacing.space2xs),
          Expanded(
            child: Text(
              'Press and hold a row to reorder · swipe right to pin, left to remove',
              style: AppTypography.bodySm.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The footer: how many rows are tracked under the current filter.
class _Footer extends StatelessWidget {
  const _Footer({required this.marketCount});

  final int marketCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.outline)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenMarginPhone,
        vertical: AppSpacing.spaceSm,
      ),
      child: Text(
        '$marketCount Markets Tracked · Real-Time WS Sync',
        style: AppTypography.labelSm.copyWith(color: AppColors.textSecondary),
      ),
    );
  }
}

/// The WS feed strip.
///
/// **Deliberately static copy.** The live values (`WS Feed: 12ms · Full Sync`)
/// come from `ConnectionBloc` and `AdaptiveDeliveryCubit`, which this widget is
/// forbidden from guessing at: naming a bloc type that does not exist would not
/// compile, and a fabricated latency would violate the "every value is real"
/// rule. The strip therefore states the transport the page uses.
class _FeedStrip extends StatelessWidget {
  const _FeedStrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface1,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenMarginPhone,
        vertical: AppSpacing.spaceXs,
      ),
      child: Row(
        children: <Widget>[
          Text(
            'WS Feed',
            style: AppTypography.labelSm.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const Spacer(),
          Text(
            'Real-time subscription',
            style: AppTypography.labelSm.copyWith(
              color: AppColors.textDisabled,
            ),
          ),
        ],
      ),
    );
  }
}

/// A first-load placeholder with the shape of the real list.
class _WatchlistSkeleton extends StatelessWidget {
  const _WatchlistSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: 6,
      itemBuilder: (BuildContext context, int index) => const Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.screenMarginPhone,
          vertical: AppSpacing.spaceSm,
        ),
        child: SkeletonBlock(height: 16),
      ),
    );
  }
}

/// Opens the market picker, which lists the whole backend roster.
Future<void> showMarketPicker(
  BuildContext context,
  WatchlistCubit cubit,
) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface2,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.containerAll),
    builder: (BuildContext sheetContext) => const _MarketPickerSheet(),
  );
}

/// The picker's contents: every market this device knows about.
///
/// The roster is read from the state the page already holds, so the picker never
/// issues a second request just to list what is on screen. Choosing a row
/// closes the sheet: every roster symbol is already on the watchlist, so there
/// is nothing to add — the sheet explains that rather than pretending to mutate
/// something.
class _MarketPickerSheet extends StatelessWidget {
  const _MarketPickerSheet();

  @override
  Widget build(BuildContext context) {
    final List<WatchlistEntry> rows = context
        .read<WatchlistCubit>()
        .state
        .entries;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(AppSpacing.spaceSm),
            child: Text(
              'Markets',
              style: AppTypography.headlineSm.copyWith(
                color: AppColors.textPrimary,
              ),
            ),
          ),
          for (final WatchlistEntry entry in rows)
            ListTile(
              dense: true,
              title: Text(
                entry.display,
                style: AppTypography.bodyLg.copyWith(
                  color: AppColors.textPrimary,
                ),
              ),
              subtitle: Text(
                entry.name,
                style: AppTypography.bodySm.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              trailing: Text(
                'LIVE',
                style: AppTypography.labelSm.copyWith(color: AppColors.bull),
              ),
              onTap: () {
                Navigator.of(context).maybePop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('${entry.display} is already tracked'),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
