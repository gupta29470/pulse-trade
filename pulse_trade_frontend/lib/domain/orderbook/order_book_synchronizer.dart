import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/messages/market_messages.dart';

/// The order-book synchronisation states.
enum OrderBookState {
  /// Constructed, nothing requested yet.
  initialLoading,

  /// A snapshot is in flight; deltas are being buffered.
  syncing,

  /// A snapshot was applied and the buffer is being drained.
  applying,

  /// The buffer is empty and live ranges are applied directly.
  live,

  /// A range gap was seen; a fresh snapshot is in flight and new deltas buffer.
  recovering,

  /// The socket is down. The book is preserved and never mutated while stale.
  stale,

  /// Recovery attempts were exhausted; only a manual retry or resubscribe helps.
  error,
}

/// One input to the synchronizer.
///
/// Modelled as data rather than method calls so a test can drive a whole
/// scenario as a list and assert on the resulting [OrderBookEffect] list.
sealed class OrderBookInput extends Equatable {
  /// Base constructor.
  const OrderBookInput();
}

/// A full book image arrived (WS snapshot or REST fetch, indistinguishable here).
final class SnapshotArrived extends OrderBookInput {
  /// Creates a snapshot input.
  const SnapshotArrived(this.snapshot);

  /// The image.
  final OrderBookSnapshot snapshot;

  @override
  List<Object?> get props => <Object?>[snapshot];
}

/// A delta range arrived.
final class DeltaArrived extends OrderBookInput {
  /// Creates a delta input.
  const DeltaArrived(this.delta);

  /// The range.
  final OrderBookDeltaMessage delta;

  @override
  List<Object?> get props => <Object?>[delta];
}

/// The socket dropped. The book must be frozen, not cleared.
final class ConnectionLost extends OrderBookInput {
  /// Creates a connection-lost input.
  const ConnectionLost();

  @override
  List<Object?> get props => const <Object?>[];
}

/// The engine epoch changed; every buffered range is obsolete.
final class ResetEpoch extends OrderBookInput {
  /// Creates an epoch-reset input.
  const ResetEpoch({required this.epoch, this.reason = 'epoch_changed'});

  /// The new epoch.
  final int epoch;

  /// Why the reset happened, for logging.
  final String reason;

  @override
  List<Object?> get props => <Object?>[epoch, reason];
}

/// The user pressed Retry on the terminal error state.
final class RecoveryRetryRequested extends OrderBookInput {
  /// Creates a retry input.
  const RecoveryRetryRequested();

  @override
  List<Object?> get props => const <Object?>[];
}

/// One effect the synchronizer asks its owner to perform.
///
/// The synchronizer touches no socket, no repository and no widget: it only
/// describes what should happen, which is what makes it pure for unit tests.
sealed class OrderBookEffect extends Equatable {
  /// Base constructor.
  const OrderBookEffect({required this.at});

  /// When the effect was produced.
  final DateTime at;
}

/// Absolute levels to apply to the local book.
final class ApplyLevels extends OrderBookEffect {
  /// Creates an apply effect.
  const ApplyLevels({
    required super.at,
    required this.bids,
    required this.asks,
    required this.appliedUpdateId,
    required this.isSnapshot,
  });

  /// Bid levels, absolute; a zero quantity deletes.
  final List<OrderBookLevel> bids;

  /// Ask levels, absolute; a zero quantity deletes.
  final List<OrderBookLevel> asks;

  /// The update id that is fully applied once these levels land.
  final int appliedUpdateId;

  /// True when these levels are a complete image rather than a delta range.
  final bool isSnapshot;

  @override
  List<Object?> get props => <Object?>[
    at,
    bids,
    asks,
    appliedUpdateId,
    isSnapshot,
  ];
}

/// Ask the owner for a fresh snapshot.
final class RequestSnapshot extends OrderBookEffect {
  /// Creates a snapshot request.
  const RequestSnapshot({
    required super.at,
    required this.attempt,
    required this.reason,
  });

  /// Recovery attempt number, 1-based.
  final int attempt;

  /// Machine-readable reason (`gap`, `epoch_changed`, `buffer_overflow`, …).
  final String reason;

  @override
  List<Object?> get props => <Object?>[at, attempt, reason];
}

/// The synchronizer moved between states.
final class OrderBookStateChanged extends OrderBookEffect {
  /// Creates a state-change effect.
  const OrderBookStateChanged({
    required super.at,
    required this.from,
    required this.to,
  });

  /// Previous state.
  final OrderBookState from;

  /// New state.
  final OrderBookState to;

  @override
  List<Object?> get props => <Object?>[at, from, to];
}

/// The snapshot/delta sequencing state machine.
///
/// It implements the range rules exactly:
/// * `epoch` mismatch ⇒ resync.
/// * `lastUpdateId <= applied` ⇒ ignore (duplicate when equal, stale when older).
/// * `firstUpdateId > applied + 1` ⇒ **gap**: never apply, buffer, recover.
/// * `firstUpdateId <= applied + 1 <= lastUpdateId` ⇒ apply, then
/// `applied = lastUpdateId`.
///
/// Two bounds keep it honest: the buffer holds at most [bufferCap] ranges
/// (overflow forces a recovery), and recovery is attempted at most
/// [maxRecoveryAttempts] times before the state becomes [OrderBookState.error].
final class OrderBookSynchronizer {
  /// Creates a synchronizer.
  ///
  /// [_onSnapshotRequested] is invoked whenever a [RequestSnapshot] effect is
  /// produced, so a wiring layer can fire the fetch without inspecting effects;
  /// tests inspect the effect list instead.
  OrderBookSynchronizer({
    required this._clock,
    this._onSnapshotRequested,
    this.bufferCap = 1000,
    this.maxRecoveryAttempts = 3,
  });

  /// Maximum buffered ranges before a recovery is forced.
  final int bufferCap;

  /// Recovery attempts allowed before the terminal error state.
  final int maxRecoveryAttempts;

  final Clock _clock;
  final void Function(RequestSnapshot request)? _onSnapshotRequested;

  final List<_BufferedRange> _buffer = <_BufferedRange>[];

  OrderBookState _state = OrderBookState.initialLoading;
  int _epoch = 0;
  int _appliedUpdateId = 0;
  int _recoveryAttempts = 0;

  int _gapCount = 0;
  int _duplicateCount = 0;
  int _staleCount = 0;
  int _recoveryCount = 0;

  /// Current state.
  OrderBookState get state => _state;

  /// Engine epoch the synchronizer is bound to.
  int get epoch => _epoch;

  /// The last engine update id whose levels are fully applied.
  int get appliedUpdateId => _appliedUpdateId;

  /// Buffered range count, for diagnostics.
  int get bufferedRangeCount => _buffer.length;

  /// Recovery attempts used since the last successful sync.
  int get recoveryAttempts => _recoveryAttempts;

  /// Gaps detected since construction.
  int get gapCount => _gapCount;

  /// Duplicate ranges ignored since construction.
  int get duplicateCount => _duplicateCount;

  /// Stale (older) ranges ignored since construction.
  int get staleCount => _staleCount;

  /// Recoveries that completed successfully.
  int get recoveryCount => _recoveryCount;

  /// True when the book must not be mutated.
  bool get isFrozen =>
      _state == OrderBookState.stale || _state == OrderBookState.error;

  /// Begins a fresh synchronisation for [epoch] and asks for a snapshot.
  ///
  /// Called on subscribe and on resubscribe after a reconnect.
  List<OrderBookEffect> start({required int epoch}) {
    return _resetTo(epoch, from: _state, reason: 'subscribe');
  }

  /// Feeds one input and returns the resulting effects in order.
  List<OrderBookEffect> handle(OrderBookInput input) {
    switch (input) {
      case SnapshotArrived():
        return _handleSnapshot(input.snapshot);
      case DeltaArrived():
        return _handleDelta(input.delta);
      case ConnectionLost():
        return _handleConnectionLost();
      case ResetEpoch():
        return _resetTo(input.epoch, from: _state, reason: input.reason);
      case RecoveryRetryRequested():
        return _handleRetry();
    }
  }

  List<OrderBookEffect> _resetTo(
    int epoch, {
    required OrderBookState from,
    required String reason,
  }) {
    _buffer.clear();
    _epoch = epoch;
    _appliedUpdateId = 0;
    _recoveryAttempts = 0;
    final List<OrderBookEffect> effects = <OrderBookEffect>[];
    _setState(OrderBookState.syncing, effects, from: from);
    // The first snapshot request is a synchronisation, not a recovery, so it
    // does not consume the recovery budget: the 4th *failure* is terminal, and a
    // failure is a gap during recovery.
    effects.add(_requestSnapshot(reason, attempt: 1));
    return effects;
  }

  List<OrderBookEffect> _handleRetry() {
    _buffer.clear();
    _appliedUpdateId = 0;
    _recoveryAttempts = 0;
    final List<OrderBookEffect> effects = <OrderBookEffect>[];
    _setState(OrderBookState.syncing, effects);
    effects.add(_requestSnapshot('manual_retry', attempt: 1));
    return effects;
  }

  List<OrderBookEffect> _handleConnectionLost() {
    final List<OrderBookEffect> effects = <OrderBookEffect>[];
    // The book is preserved and never mutated while stale. The
    // buffer is kept too: those ranges may still be valid if the epoch survived
    // the drop, and a fresh snapshot will discard them if they are not.
    _setState(OrderBookState.stale, effects);
    return effects;
  }

  List<OrderBookEffect> _handleSnapshot(OrderBookSnapshot snapshot) {
    final List<OrderBookEffect> effects = <OrderBookEffect>[];

    // A snapshot for a different epoch is authoritative: it resets the epoch
    // rather than fighting it, because the server's engine is the source of truth.
    _epoch = snapshot.epoch;
    _appliedUpdateId = snapshot.updateId;

    effects.add(
      ApplyLevels(
        at: _clock.now(),
        bids: snapshot.bids,
        asks: snapshot.asks,
        appliedUpdateId: snapshot.updateId,
        isSnapshot: true,
      ),
    );
    _setState(OrderBookState.applying, effects);
    _drain(effects);
    return effects;
  }

  List<OrderBookEffect> _handleDelta(OrderBookDeltaMessage delta) {
    final List<OrderBookEffect> effects = <OrderBookEffect>[];

    if (delta.epoch != _epoch) {
      // Epoch mismatch ⇒ reset the book and resync.
      return _resetTo(delta.epoch, from: _state, reason: 'epoch_mismatch');
    }

    final int reference = _buffer.isEmpty
        ? _appliedUpdateId
        : _buffer.last.lastUpdateId;
    if (delta.lastUpdateId == reference) {
      _duplicateCount++;
      return effects;
    }
    if (delta.lastUpdateId < reference) {
      _staleCount++;
      return effects;
    }

    final bool bufferDrained =
        _state == OrderBookState.live ||
        (_state == OrderBookState.applying && _buffer.isEmpty);

    if (bufferDrained) {
      if (delta.firstUpdateId <= _appliedUpdateId + 1) {
        effects.add(_applyDelta(delta));
        _appliedUpdateId = delta.lastUpdateId;
        return effects;
      }
      return _beginRecovery(
        from: _state,
        offending: delta,
        reason: 'gap',
        effects: effects,
      );
    }

    if (_state == OrderBookState.error) {
      // Terminal: keep counting but never mutate and never silently recover.
      _gapCount++;
      return effects;
    }

    if (_buffer.isNotEmpty &&
        delta.firstUpdateId > _buffer.last.lastUpdateId + 1) {
      // A hole appeared inside the buffer itself, so draining it could never
      // produce a continuous book. That is a second gap: the obsolete buffer is
      // discarded and a fresh snapshot is requested.
      return _beginRecovery(
        from: _state,
        offending: delta,
        reason: 'gap_in_buffer',
        effects: effects,
      );
    }

    _buffer.add(_BufferedRange.of(delta));
    if (_buffer.length > bufferCap) {
      // Bounded memory beats an unbounded buffer: drop the oldest range,
      // force a recovery rather than growing without limit.
      _buffer.removeAt(0);
      return _beginRecovery(
        from: _state,
        offending: null,
        reason: 'buffer_overflow',
        effects: effects,
      );
    }
    return effects;
  }

  void _drain(List<OrderBookEffect> effects) {
    while (_buffer.isNotEmpty) {
      final _BufferedRange range = _buffer.first;
      if (range.lastUpdateId <= _appliedUpdateId) {
        // The snapshot already supersedes this range.
        _buffer.removeAt(0);
        _duplicateCount++;
        continue;
      }
      if (range.firstUpdateId > _appliedUpdateId + 1) {
        _beginRecovery(
          from: _state,
          offending: null,
          reason: 'gap_after_snapshot',
          effects: effects,
        );
        return;
      }
      effects.add(
        ApplyLevels(
          at: _clock.now(),
          bids: range.bids,
          asks: range.asks,
          appliedUpdateId: range.lastUpdateId,
          isSnapshot: false,
        ),
      );
      _appliedUpdateId = range.lastUpdateId;
      _buffer.removeAt(0);
    }

    if (_recoveryAttempts > 0) _recoveryCount++;
    _recoveryAttempts = 0;
    _setState(OrderBookState.live, effects);
  }

  List<OrderBookEffect> _beginRecovery({
    required OrderBookState from,
    required OrderBookDeltaMessage? offending,
    required String reason,
    required List<OrderBookEffect> effects,
  }) {
    _gapCount++;
    _recoveryAttempts++;
    // Discard the obsolete buffer: anything buffered before this gap may be
    // discontinuous with whatever comes next.
    _buffer.clear();
    if (offending != null) {
      _buffer.add(_BufferedRange.of(offending));
    }

    if (_recoveryAttempts > maxRecoveryAttempts) {
      _setState(OrderBookState.error, effects, from: from);
      return effects;
    }

    _setState(OrderBookState.recovering, effects, from: from);
    effects.add(_requestSnapshot(reason));
    return effects;
  }

  ApplyLevels _applyDelta(OrderBookDeltaMessage delta) => ApplyLevels(
    at: _clock.now(),
    bids: delta.bids,
    asks: delta.asks,
    appliedUpdateId: delta.lastUpdateId,
    isSnapshot: false,
  );

  RequestSnapshot _requestSnapshot(String reason, {int? attempt}) {
    final RequestSnapshot request = RequestSnapshot(
      at: _clock.now(),
      attempt: attempt ?? _recoveryAttempts,
      reason: reason,
    );
    _onSnapshotRequested?.call(request);
    return request;
  }

  void _setState(
    OrderBookState next,
    List<OrderBookEffect> effects, {
    OrderBookState? from,
  }) {
    final OrderBookState previous = from ?? _state;
    if (previous == next) return;
    _state = next;
    effects.add(
      OrderBookStateChanged(at: _clock.now(), from: previous, to: next),
    );
  }
}

/// One buffered delta range. Levels are kept as separate absolute ranges because
/// applying them in arrival order is provably identical to applying each engine
/// update in order.
final class _BufferedRange {
  const _BufferedRange({
    required this.firstUpdateId,
    required this.lastUpdateId,
    required this.bids,
    required this.asks,
  });

  factory _BufferedRange.of(OrderBookDeltaMessage delta) => _BufferedRange(
    firstUpdateId: delta.firstUpdateId,
    lastUpdateId: delta.lastUpdateId,
    bids: delta.bids,
    asks: delta.asks,
  );

  final int firstUpdateId;
  final int lastUpdateId;
  final List<OrderBookLevel> bids;
  final List<OrderBookLevel> asks;
}
