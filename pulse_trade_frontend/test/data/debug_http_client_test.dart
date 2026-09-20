import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/failure_mapper.dart';
import 'package:pulse_trade_frontend/data/repositories/debug_http_client.dart';

/// Records what the client actually put on the wire.
///
/// This is the seam the session list died at: the client hard-coded `POST`, so the
/// console's `GET /api/v1/debug/sessions` went out as a POST, the backend answered
/// `405 METHOD_NOT_ALLOWED`, and because the console needs a session id for every
/// fault control, fault injection could never be enabled from the app. Nothing
/// covered this, so the verb is asserted here rather than assumed.
final class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    // The shape the session list parses, so the client's happy path is exercised too.
    return ResponseBody.fromString(
      '{"sessions":[{"id":"abc123","symbol":"BTCUSDT"}]}',
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _RecordingAdapter adapter;
  late DebugHttpClient client;

  setUp(() {
    adapter = _RecordingAdapter();
    final Dio dio = Dio()..httpClientAdapter = adapter;
    client = DebugHttpClient(
      dio: dio,
      failureMapper: const FailureMapper(),
      clock: SystemClock(),
      baseUrl: 'http://backend.test',
    );
  });

  test('a request goes out with the verb it was given', () async {
    await client('/api/v1/debug/sessions', method: 'GET');
    await client('/api/v1/debug/generator/pause', method: 'POST');

    expect(adapter.requests.map((RequestOptions o) => o.method), <String>[
      'GET',
      'POST',
    ]);
    expect(adapter.requests.first.uri.path, '/api/v1/debug/sessions');
  });

  test(
    'the default verb is a read, so a forgotten method cannot mutate',
    () async {
      await client('/api/v1/debug/sessions');

      expect(
        adapter.requests.single.method,
        'GET',
        reason: 'a control that forgets its verb must fail loudly, not trigger',
      );
    },
  );

  test('a JSON object body is decoded and returned', () async {
    final Map<String, Object?> response = await client(
      '/api/v1/debug/sessions',
      method: 'GET',
    );

    expect(response['sessions'], isA<List<Object?>>());
  });
}
