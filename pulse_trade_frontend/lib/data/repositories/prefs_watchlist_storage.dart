import 'dart:convert';

import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/storage/app_storage.dart';
import 'package:pulse_trade_frontend/core/storage/storage_keys.dart';
import 'package:pulse_trade_frontend/domain/repositories/watchlist_storage.dart';

/// The default watchlist order: every roster symbol, in the backend's order.
const List<String> kDefaultWatchlistOrder = <String>[
  'BTCUSDT',
  'ETHUSDT',
  'SOLUSDT',
  'BNBUSDT',
  'AVAXUSDT',
  'ADAUSDT',
];

/// `WatchlistStorage` over versioned `shared_preferences`.
///
/// Persisted as `{"version":1,"symbols":[...]}`. A corrupt payload or an
/// unknown version falls back to [kDefaultWatchlistOrder] and logs one WARN —
/// never fatal, because a broken preference must not stop the app from starting.
final class PrefsWatchlistStorage implements WatchlistStorage {
  /// Creates the storage.
  const PrefsWatchlistStorage({required this._storage});

  /// The schema version of the persisted payload.
  static const int schemaVersion = 1;

  final AppStorage _storage;

  @override
  Future<List<String>> loadOrder() async {
    final List<String>? symbols = _readSymbolList(StorageKeys.watchlistOrder);
    if (symbols == null) return List<String>.of(kDefaultWatchlistOrder);
    return symbols;
  }

  @override
  Future<void> saveOrder(List<String> symbols) async {
    await _storage.writeString(
      StorageKeys.watchlistOrder,
      jsonEncode(<String, Object?>{
        'version': schemaVersion,
        'symbols': symbols,
      }),
    );
  }

  @override
  Future<Set<String>> loadFavourites() async {
    final List<String>? symbols = _readSymbolList(
      StorageKeys.watchlistFavourites,
    );
    if (symbols == null) return <String>{'BTCUSDT'};
    return symbols.toSet();
  }

  @override
  Future<void> saveFavourites(Set<String> symbols) async {
    await _storage.writeString(
      StorageKeys.watchlistFavourites,
      jsonEncode(<String, Object?>{
        'version': schemaVersion,
        'symbols': symbols.toList(),
      }),
    );
  }

  @override
  Future<String?> loadPinned() async {
    final String raw = _storage.readString(StorageKeys.watchlistPinned) ?? '';
    return raw.isEmpty ? null : raw;
  }

  @override
  Future<void> savePinned(String? symbol) async {
    if (symbol == null) {
      await _storage.remove(StorageKeys.watchlistPinned);
      return;
    }
    await _storage.writeString(StorageKeys.watchlistPinned, symbol);
  }

  /// Reads a `{"version":n,"symbols":[...]}` payload, returning `null` for a
  /// missing key, a decode failure or a version this build does not understand.
  List<String>? _readSymbolList(String key) {
    final String? raw = _storage.readString(key);
    if (raw == null || raw.isEmpty) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      AppLogger.warn(
        'watchlist_payload_corrupt',
        fields: <String, Object?>{
          LogFields.component: LogComponents.cache,
          LogFields.cacheKey: key,
          LogFields.error: error.message,
        },
      );
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    if (decoded['version'] != schemaVersion) {
      AppLogger.warn(
        'watchlist_payload_version_unknown',
        fields: <String, Object?>{
          LogFields.component: LogComponents.cache,
          LogFields.cacheKey: key,
          LogFields.count: decoded['version'] is int ? decoded['version'] : -1,
        },
      );
      return null;
    }
    final Object? symbols = decoded['symbols'];
    if (symbols is! List<Object?>) return null;
    return <String>[
      for (final Object? entry in symbols)
        if (entry is String) entry,
    ];
  }
}
