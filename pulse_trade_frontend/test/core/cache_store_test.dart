import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/cache/cache_store.dart';
import 'package:pulse_trade_frontend/core/cache/prefs_cache_store.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/storage/app_storage.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A payload type that is small enough to reason about and still exercises the
/// encode/decode seam.
Map<String, dynamic> _encodeCounter(int value) => <String, dynamic>{
  'value': value,
};

int _decodeCounter(Map<String, dynamic> json) => (json['value'] as num).toInt();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PrefsCacheStore (M-17)', () {
    late AppStorage storage;
    late OnDeviceMetrics metrics;
    late FakeClock clock;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      storage = await AppStorage.open();
      metrics = OnDeviceMetrics();
      clock = FakeClock();
    });

    test('round-trip returns an equal entry with its TTL intact', () async {
      final PrefsCacheStore store = PrefsCacheStore(
        storage: storage,
        metrics: metrics,
        clock: clock,
      );

      await store.write<int>(
        'counter',
        42,
        ttl: const Duration(seconds: 30),
        encode: _encodeCounter,
      );

      final CacheEntry<int>? entry = await store.read<int>(
        'counter',
        _decodeCounter,
      );

      expect(entry, isNotNull);
      expect(entry!.key, 'counter');
      expect(entry.schemaVersion, kCacheSchemaVersion);
      expect(entry.payload, 42);
      expect(entry.ttl, const Duration(seconds: 30));
      expect(entry.writtenAt, clock.now());
      expect(entry.isStaleAt(clock.now()), isFalse);
      expect(metrics.value(MetricNames.cacheWritesTotal), 1);
    });

    test('a missing key is a miss, not an error', () async {
      final PrefsCacheStore store = PrefsCacheStore(
        storage: storage,
        metrics: metrics,
        clock: clock,
      );

      expect(await store.read<int>('absent', _decodeCounter), isNull);
      expect(metrics.value(MetricNames.cacheMissesTotal), 1);
      expect(metrics.value(MetricNames.cacheHitsTotal), 0);
    });

    test(
      'a bumped schema version yields a miss and deletes the entry',
      () async {
        final PrefsCacheStore writer = PrefsCacheStore(
          storage: storage,
          metrics: metrics,
          clock: clock,
        );
        await writer.write<int>(
          'counter',
          7,
          ttl: const Duration(minutes: 5),
          encode: _encodeCounter,
        );

        final PrefsCacheStore newer = PrefsCacheStore(
          storage: storage,
          metrics: metrics,
          clock: clock,
          schemaVersion: kCacheSchemaVersion + 1,
        );

        expect(await newer.read<int>('counter', _decodeCounter), isNull);
        expect(
          storage.readString('${PrefsCacheStore.keyPrefix}counter'),
          isNull,
          reason: 'a version mismatch deletes rather than migrates',
        );
      },
    );

    test('a corrupt payload yields a miss and never throws', () async {
      await storage.writeString(
        '${PrefsCacheStore.keyPrefix}counter',
        '{"v":1,"at":', // truncated JSON
      );

      final PrefsCacheStore store = PrefsCacheStore(
        storage: storage,
        metrics: metrics,
        clock: clock,
      );

      expect(await store.read<int>('counter', _decodeCounter), isNull);
      expect(
        storage.readString('${PrefsCacheStore.keyPrefix}counter'),
        isNull,
        reason: 'the unusable entry is dropped, not retried forever',
      );
    });

    test('a decode failure yields a miss and never throws', () async {
      await storage.writeString(
        '${PrefsCacheStore.keyPrefix}counter',
        '{"v":$kCacheSchemaVersion,"at":"2026-09-17T12:41:03.000Z",'
            '"ttlMs":1000,"payload":{"value":"not a number"}}',
      );

      final PrefsCacheStore store = PrefsCacheStore(
        storage: storage,
        metrics: metrics,
        clock: clock,
      );

      // The decoder throws; the store must convert that into a miss.
      expect(
        await store.read<int>(
          'counter',
          (Map<String, dynamic> json) => json['value']! as int,
        ),
        isNull,
      );
    });

    test('TTL expiry marks the entry stale rather than dropping it', () async {
      final PrefsCacheStore store = PrefsCacheStore(
        storage: storage,
        metrics: metrics,
        clock: clock,
      );

      await store.write<int>(
        'counter',
        1,
        ttl: const Duration(seconds: 30),
        encode: _encodeCounter,
      );

      clock.advance(const Duration(seconds: 31));

      final CacheEntry<int>? entry = await store.read<int>(
        'counter',
        _decodeCounter,
      );
      expect(entry, isNotNull, reason: 'stale data still renders');
      expect(entry!.isStaleAt(clock.now()), isTrue);
      expect(entry.ageAt(clock.now()), const Duration(seconds: 31));
    });

    test('invalidate and clear remove only this store\'s namespace', () async {
      final PrefsCacheStore store = PrefsCacheStore(
        storage: storage,
        metrics: metrics,
        clock: clock,
      );
      await storage.writeString('unrelated', 'kept');
      await store.write<int>(
        'a',
        1,
        ttl: Duration.zero,
        encode: _encodeCounter,
      );
      await store.write<int>(
        'b',
        2,
        ttl: Duration.zero,
        encode: _encodeCounter,
      );

      final CacheStats before = await store.stats();
      expect(before.entries, 2);

      await store.invalidate('a');
      expect(await store.read<int>('a', _decodeCounter), isNull);
      expect(await store.read<int>('b', _decodeCounter), isNotNull);

      await store.clear();
      expect((await store.stats()).entries, 0);
      expect(storage.readString('unrelated'), 'kept');
    });

    test('stats reports hits and misses from the shared registry', () async {
      final PrefsCacheStore store = PrefsCacheStore(
        storage: storage,
        metrics: metrics,
        clock: clock,
      );
      await store.write<int>(
        'a',
        1,
        ttl: Duration.zero,
        encode: _encodeCounter,
      );
      await store.read<int>('a', _decodeCounter);
      await store.read<int>('missing', _decodeCounter);

      final CacheStats stats = await store.stats();
      expect(stats.hits, 1);
      expect(stats.misses, 1);
      expect(stats.writes, 1);
      expect(stats.bytes, greaterThan(0));
    });
  });
}
