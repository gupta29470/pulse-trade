import 'dart:async';

import 'package:dio/dio.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/error/failure_mapper.dart';

/// Performs one debug REST call and returns the decoded JSON object.
///
/// The debug console must not import `dio`, and `MarketApi` deliberately exposes
/// only production routes (debug routes are absent on a release backend), so the
/// seam is this callback typedef. The console cubit accepts one and never learns
/// what implements it.
typedef DebugRequest =
    Future<Map<String, Object?>> Function(
      String path, {
      Map<String, String>? query,
      Object? body,
    });

/// The `data/`-side implementation of [DebugRequest].
///
/// It is only constructed in debug/profile builds. Every failure is mapped to an
/// [AppFailure] and rethrown as one, so the debug cubit can render a message
/// without knowing a transport type.
final class DebugHttpClient {
  /// Creates the client over an existing [_dio] instance.
  DebugHttpClient({
    required this._dio,
    required this._failureMapper,
    required this._clock,
    required String baseUrl,
  }) : _baseUrl = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl;

  final Dio _dio;
  final FailureMapper _failureMapper;
  final Clock _clock;
  final String _baseUrl;

  /// Issues one request. [path] is absolute, e.g. `/api/v1/debug/sessions`.
  Future<Map<String, Object?>> call(
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    try {
      final Response<Object?> response = await _dio.request<Object?>(
        '$_baseUrl$path',
        data: body,
        queryParameters: query,
        options: Options(
          method: 'POST',
          contentType: Headers.jsonContentType,
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      final Object? data = response.data;
      if (data is Map<String, Object?>) return data;
      if (data is Map<Object?, Object?>) {
        return <String, Object?>{
          for (final MapEntry<Object?, Object?> entry in data.entries)
            if (entry.key is String) entry.key! as String: entry.value,
        };
      }
      // Several debug endpoints answer 204; an empty body is a success.
      return <String, Object?>{};
    } on Object catch (error) {
      throw _failureMapper.map(error);
    }
  }

  /// Wall clock at the last call, kept for log correlation.
  DateTime get lastCallAt => _clock.now();
}
