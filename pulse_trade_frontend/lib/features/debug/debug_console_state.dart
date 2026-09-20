import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_override.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';

/// Marks a `copyWith` argument as "not supplied", so `null` can clear a field.
const Object _unset = Object();

/// One live session as reported by `GET /api/v1/debug/sessions`.
///
/// The shape mirrors what the debug console shows per row and nothing more: a
/// session is a rendering of backend state, so it carries parsed domain enums
/// ([DeliveryTier], [DeliveryOverride]) rather than raw strings and cannot
/// disagree with the rest of the app about what `DEGRADED` means.
final class DebugSessionInfo extends Equatable {
  /// Creates one session row.
  const DebugSessionInfo({
    required this.id,
    required this.shortId,
    required this.tier,
    required this.overrideTier,
    required this.rttMs,
    required this.jitterMs,
    required this.uptimeMs,
    required this.connectedAt,
    required this.symbol,
  });

  /// The full session id (`sess_…`), used as the key of every session action.
  final String id;

  /// The six-character display id shown next to the full id.
  final String shortId;

  /// The backend's current delivery tier for this session.
  final DeliveryTier tier;

  /// The manual override in force, or [DeliveryOverride.automatic].
  final DeliveryOverride overrideTier;

  /// The backend's measured round trip for this session, in milliseconds.
  final double rttMs;

  /// The backend's measured jitter for this session, in milliseconds.
  final double jitterMs;

  /// How long the session has been connected, in milliseconds.
  final int uptimeMs;

  /// When the session connected, in UTC.
  final DateTime connectedAt;

  /// The symbol the session is subscribed to.
  final String symbol;

  @override
  List<Object?> get props => <Object?>[
    id,
    shortId,
    tier,
    overrideTier,
    rttMs,
    jitterMs,
    uptimeMs,
    connectedAt,
    symbol,
  ];

  @override
  String toString() =>
      'DebugSessionInfo($shortId, ${tier.wire}, '
      'rtt ${rttMs.toStringAsFixed(0)}ms, jitter ${jitterMs.toStringAsFixed(0)}ms)';
}

/// Everything the debug console screen renders.
///
/// One immutable value for one screen: the session list, the last action's
/// outcome, the pinned tier override and the log tail. Keeping [lastResult] and
/// [lastError] in state (rather than firing one-off events) is what makes "every
/// control shows its result inline" survive a rebuild or a rotation.
final class DebugConsoleState extends Equatable {
  /// Creates a console snapshot. All fields required so a new one cannot be
  /// added without deciding its default in [initial].
  const DebugConsoleState({
    required this.sessions,
    required this.isBusy,
    required this.lastResult,
    required this.lastError,
    required this.tierOverride,
    required this.logRecords,
  });

  /// The state before anything has been fetched.
  static const DebugConsoleState initial = DebugConsoleState(
    sessions: <DebugSessionInfo>[],
    isBusy: false,
    lastResult: null,
    lastError: null,
    tierOverride: DeliveryOverride.automatic,
    logRecords: <Map<String, Object?>>[],
  );

  /// Live sessions, newest-known first as the backend reported them.
  final List<DebugSessionInfo> sessions;

  /// Whether an action or refresh is in flight; disables the controls.
  final bool isBusy;

  /// The last action's success message, or `null` when the last action failed.
  final String? lastResult;

  /// The last action's failure message, or `null` when it succeeded.
  final String? lastError;

  /// The tier override most recently sent from this client.
  ///
  /// Local truth, not a claim about the backend: it is what the client last
  /// asked for, which is exactly what a debug console should show.
  final DeliveryOverride tierOverride;

  /// A snapshot of `AppLogger.records`, verbatim, for the log tail.
  final List<Map<String, Object?>> logRecords;

  /// Copy with individual fields replaced.
  ///
  /// [lastResult] and [lastError] use a sentinel so an explicit `null` clears
  /// them — the start of every action must clear the previous outcome, or a
  /// success would sit next to the next failure's message.
  DebugConsoleState copyWith({
    List<DebugSessionInfo>? sessions,
    bool? isBusy,
    Object? lastResult = _unset,
    Object? lastError = _unset,
    DeliveryOverride? tierOverride,
    List<Map<String, Object?>>? logRecords,
  }) {
    return DebugConsoleState(
      sessions: sessions ?? this.sessions,
      isBusy: isBusy ?? this.isBusy,
      lastResult: identical(lastResult, _unset)
          ? this.lastResult
          : lastResult as String?,
      lastError: identical(lastError, _unset)
          ? this.lastError
          : lastError as String?,
      tierOverride: tierOverride ?? this.tierOverride,
      logRecords: logRecords ?? this.logRecords,
    );
  }

  @override
  List<Object?> get props => <Object?>[
    sessions,
    isBusy,
    lastResult,
    lastError,
    tierOverride,
    logRecords,
  ];

  @override
  String toString() =>
      'DebugConsoleState(${sessions.length} sessions, '
      'busy: $isBusy, override: ${tierOverride.wire})';
}
