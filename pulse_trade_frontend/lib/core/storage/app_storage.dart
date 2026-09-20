import 'dart:convert';

import 'package:pulse_trade_frontend/core/storage/storage_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The one door to `shared_preferences`.
///
/// Every key is stored under [StorageKeys.namespace] so a future schema version
/// can be migrated (or abandoned) as one unit. Namespacing happens in exactly
/// one private helper, so no call site can write an unversioned key by
/// accident — that mistake is invisible at runtime but makes migration
/// impossible to reason about.
///
/// Reads are synchronous because `SharedPreferences` keeps the whole map in
/// memory after [open]; writes are asynchronous because the platform channel
/// is. This class only ever stores strings, ints, bools and string lists:
/// deciding what those bytes mean, and what to do about a corrupt value, is the
/// caller's job ([AppStorage]'s own `readJson` is the single exception, and it
/// documents its null-on-failure contract).
final class AppStorage {
  /// Wraps an already-loaded preferences instance.
  AppStorage(this._prefs);

  /// The one physical-key prefix every entry is written under.
  static const String _prefix = '${StorageKeys.namespace}.';

  final SharedPreferences _prefs;

  /// Loads the platform preferences and returns a namespaced façade.
  ///
  /// Called once from the composition root before any repository is built, so
  /// no later read can observe a half-initialised store.
  static Future<AppStorage> open() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return AppStorage(prefs);
  }

  /// Builds the physical key, so the namespace cannot be forgotten.
  static String _qualified(String key) => '$_prefix$key';

  /// Every logical key currently stored under the namespace, with the prefix
  /// stripped.
  ///
  /// Exposed so a tier that owns a key space inside the namespace (the prefs
  /// cache, whose keys start with `cache.prefs.`) can enumerate and clear only
  /// its own entries instead of the whole namespace.
  List<String> keys() {
    final List<String> out = <String>[];
    for (final String key in _prefs.getKeys()) {
      if (key.startsWith(_prefix)) {
        out.add(key.substring(_prefix.length));
      }
    }
    return out;
  }

  /// The stored string for [key], or `null` when it was never written.
  String? readString(String key) => _prefs.getString(_qualified(key));

  /// The stored integer for [key], or `null` when absent or a different type.
  int? readInt(String key) => _prefs.getInt(_qualified(key));

  /// The stored boolean for [key], or `null` when absent or a different type.
  bool? readBool(String key) => _prefs.getBool(_qualified(key));

  /// The stored string list for [key], or `null` when absent.
  ///
  /// The returned list is a copy, so mutating it cannot corrupt the cache
  /// behind the platform channel.
  List<String>? readStringList(String key) {
    final List<String>? value = _prefs.getStringList(_qualified(key));
    return value == null ? null : List<String>.of(value);
  }

  /// Writes [value] under [key]. Resolves once the platform channel confirms.
  Future<void> writeString(String key, String value) async {
    await _prefs.setString(_qualified(key), value);
  }

  /// Writes [value] under [key]. Resolves once the platform channel confirms.
  Future<void> writeInt(String key, int value) async {
    await _prefs.setInt(_qualified(key), value);
  }

  /// Writes [value] under [key]. Resolves once the platform channel confirms.
  Future<void> writeBool(String key, bool value) async {
    await _prefs.setBool(_qualified(key), value);
  }

  /// Writes a defensive copy of [value] under [key].
  Future<void> writeStringList(String key, List<String> value) async {
    await _prefs.setStringList(_qualified(key), List<String>.of(value));
  }

  /// Removes [key] if present.
  Future<void> remove(String key) async {
    await _prefs.remove(_qualified(key));
  }

  /// Removes every key under [StorageKeys.namespace], and nothing else.
  ///
  /// Only namespaced keys are touched, so clearing the app's own state can never
  /// delete a value another package stored in the same preferences file.
  Future<void> clearNamespace() async {
    final List<String> owned = keys();
    for (final String key in owned) {
      await _prefs.remove(_qualified(key));
    }
  }

  /// Decodes the string stored under [key] as a JSON object.
  ///
  /// Returns `null` — never throws — when the key is absent, when the stored
  /// text is not valid JSON, when it decodes to something other than an object,
  /// or when the preferences platform reports that the stored value is not a
  /// string. Callers treat `null` as "no usable value" and fall back to their
  /// default, because a corrupt preference must degrade to a default rather than
  /// block startup.
  Map<String, Object?>? readJson(String key) {
    final String? raw = readString(key);
    if (raw == null) return null;
    final Object? decoded = _tryDecodeJson(raw);
    if (decoded is! Map<String, Object?>) return null;
    return decoded;
  }

  /// `jsonDecode` throws a [FormatException] for malformed text; this file's
  /// contract is a silent `null`, so the conversion is confined here.
  static Object? _tryDecodeJson(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
}
