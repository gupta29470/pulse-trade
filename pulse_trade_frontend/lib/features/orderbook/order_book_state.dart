import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/entities/top_of_book.dart';
import 'package:pulse_trade_frontend/domain/orderbook/order_book_synchronizer.dart';

/// Sentinel that lets [OrderBookStateModel.copyWith] tell "argument omitted"
/// apart from "argument explicitly set to null", so a nullable field such as
/// [OrderBookStateModel.failure] can be cleared. Without it a state that
/// recovered could never drop the failure that explained why it had stopped.
const Object _unset = Object();

/// Everything the order-book UI renders, as one immutable value.
///
/// The state carries the synchronizer's state ([syncState]), the precomputed
/// projection ([top]) and the honesty labels ([provenance], [asOf]) — never the
/// mutable `LocalOrderBook` itself. That split is what lets `BlocSelector`
/// rebuild only the rows that changed and keeps every sort and accumulation out
/// of `build`.
final class OrderBookStateModel extends Equatable {
  /// Creates a state.
  ///
  /// Only the sequencing fields are required: the counters default to zero and
  /// the nullable timestamps/labels are absent until data arrives, which keeps
  /// [initial] a `const`.
  const OrderBookStateModel({
    required this.syncState,
    required this.top,
    required this.epoch,
    required this.appliedUpdateId,
    required this.lastAppliedFirstUpdateId,
    required this.lastAppliedLastUpdateId,
    required this.provenance,
    this.asOf,
    this.gapCount = 0,
    this.duplicateCount = 0,
    this.staleCount = 0,
    this.recoveryCount = 0,
    this.recoveryAttempts = 0,
    this.depth = 10,
    this.failure,
    this.lastUpdatedAt,
  });

  /// The state before the first subscribe is issued.
  ///
  /// `provenance` is [DataProvenance.live] rather than `cached` because nothing
  /// has been read yet: there is no cache entry to be honest about.
  /// [tagLabel] reports `SYNCING` for as long as the first snapshot is in
  /// flight, so the label is never a claim about absent data.
  static const OrderBookStateModel initial = OrderBookStateModel(
    syncState: OrderBookState.initialLoading,
    top: TopOfBook.empty,
    epoch: 0,
    appliedUpdateId: 0,
    lastAppliedFirstUpdateId: 0,
    lastAppliedLastUpdateId: 0,
    provenance: DataProvenance.live,
  );

  /// The sequencing state, mirrored from the synchronizer.
  final OrderBookState syncState;

  /// The best-[depth] levels per side with precomputed cumulative quantities.
  final TopOfBook top;

  /// Engine epoch the applied levels belong to.
  final int epoch;

  /// Last engine update id whose levels are fully applied.
  final int appliedUpdateId;

  /// `firstUpdateId` of the last applied range. Kept next to
  /// [lastAppliedLastUpdateId] so a gap can be explained from one state object
  /// without re-reading the frame.
  final int lastAppliedFirstUpdateId;

  /// `lastUpdateId` of the last applied range.
  final int lastAppliedLastUpdateId;

  /// Where the displayed levels came from. Cache is never promoted to
  /// [DataProvenance.live] by the passage of time.
  final DataProvenance provenance;

  /// When the displayed data was produced. `null` until the first image lands.
  final DateTime? asOf;

  /// Range gaps detected since the bloc was created.
  final int gapCount;

  /// Ranges ignored because `lastUpdateId <= appliedUpdateId`.
  final int duplicateCount;

  /// Ranges ignored because they were older than the applied range.
  final int staleCount;

  /// Resynchronisations that completed.
  final int recoveryCount;

  /// Attempts used by the in-flight resynchronisation.
  final int recoveryAttempts;

  /// Levels rendered per side. The projection follows this, not the other way
  /// round, so changing it never touches the applied book.
  final int depth;

  /// The failure to explain, if any. Non-null does not by itself mean the screen
  /// is in the error state: a transport failure while stale still renders rows.
  final AppFailure? failure;

  /// When the last range or image was applied, for the section's last-update
  /// line.
  final DateTime? lastUpdatedAt;

  /// True while the book has no complete image to show: the first snapshot is
  /// in flight, or a resync is replacing a book that could not be trusted.
  bool get isSyncing =>
      syncState == OrderBookState.initialLoading ||
      syncState == OrderBookState.syncing ||
      syncState == OrderBookState.recovering;

  /// True when the displayed rows must not be presented as current: either the
  /// socket is down, or the rows themselves came from an expired cache entry.
  bool get isStale =>
      syncState == OrderBookState.stale || provenance == DataProvenance.stale;

  /// The short textual tag for the section, in precedence order.
  ///
  /// `SYNCING` wins because a resync is the most important thing to say about
  /// the rows currently on screen; then `STALE`; then `CACHED`; and only a book
  /// that is fully live and fully fresh is labelled `LIVE`. Tags are always
  /// textual, never colour-only.
  String get tagLabel {
    if (isSyncing) return 'SYNCING';
    if (isStale) return 'STALE';
    if (provenance != DataProvenance.live) return 'CACHED';
    return 'LIVE';
  }

  /// A copy with the named fields replaced.
  ///
  /// [asOf], [failure] and [lastUpdatedAt] use the [_unset] sentinel so they can
  /// be cleared as well as set.
  OrderBookStateModel copyWith({
    OrderBookState? syncState,
    TopOfBook? top,
    int? epoch,
    int? appliedUpdateId,
    int? lastAppliedFirstUpdateId,
    int? lastAppliedLastUpdateId,
    DataProvenance? provenance,
    Object? asOf = _unset,
    int? gapCount,
    int? duplicateCount,
    int? staleCount,
    int? recoveryCount,
    int? recoveryAttempts,
    int? depth,
    Object? failure = _unset,
    Object? lastUpdatedAt = _unset,
  }) {
    return OrderBookStateModel(
      syncState: syncState ?? this.syncState,
      top: top ?? this.top,
      epoch: epoch ?? this.epoch,
      appliedUpdateId: appliedUpdateId ?? this.appliedUpdateId,
      lastAppliedFirstUpdateId:
          lastAppliedFirstUpdateId ?? this.lastAppliedFirstUpdateId,
      lastAppliedLastUpdateId:
          lastAppliedLastUpdateId ?? this.lastAppliedLastUpdateId,
      provenance: provenance ?? this.provenance,
      asOf: identical(asOf, _unset) ? this.asOf : asOf as DateTime?,
      gapCount: gapCount ?? this.gapCount,
      duplicateCount: duplicateCount ?? this.duplicateCount,
      staleCount: staleCount ?? this.staleCount,
      recoveryCount: recoveryCount ?? this.recoveryCount,
      recoveryAttempts: recoveryAttempts ?? this.recoveryAttempts,
      depth: depth ?? this.depth,
      failure: identical(failure, _unset)
          ? this.failure
          : failure as AppFailure?,
      lastUpdatedAt: identical(lastUpdatedAt, _unset)
          ? this.lastUpdatedAt
          : lastUpdatedAt as DateTime?,
    );
  }

  @override
  List<Object?> get props => <Object?>[
    syncState,
    top,
    epoch,
    appliedUpdateId,
    lastAppliedFirstUpdateId,
    lastAppliedLastUpdateId,
    provenance,
    asOf,
    gapCount,
    duplicateCount,
    staleCount,
    recoveryCount,
    recoveryAttempts,
    depth,
    failure,
    lastUpdatedAt,
  ];

  @override
  String toString() =>
      'OrderBookStateModel(${syncState.name}, ${tagLabel.toLowerCase()}, '
      'epoch=$epoch, applied=$appliedUpdateId, '
      'bids=${top.bids.length}, asks=${top.asks.length})';
}
