import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// The single translation point from transport/parse exceptions to the typed
/// [AppFailure] hierarchy.
///
/// This is deliberately the only file in `lib/` that names `DioException`,
/// `SocketException`, `TimeoutException`, `FormatException` and
/// `WebSocketChannelException`. Every other layer — repositories, blocs,
/// widgets — speaks [AppFailure] and nothing else, so no raw transport type can
/// leak upwards and a switch over a failure stays exhaustive.
final class FailureMapper {
  /// Const so the composition root can hold one instance cheaply.
  const FailureMapper();

  /// Maps any error to a typed failure, dispatching on the concrete type.
  AppFailure map(Object error) {
    if (error is AppFailure) return error;
    if (error is DioException) return fromDio(error);
    if (error is SocketException) return fromSocket(error);
    if (error is TimeoutException) return fromTimeout(error);
    if (error is WebSocketChannelException) return fromWebSocket(error);
    if (error is FormatException) return fromFormat(error);
    if (error is HttpException) {
      return NetworkFailure(message: error.message, cause: error);
    }
    if (error is HandshakeException) {
      return NetworkFailure(message: 'Secure connection failed', cause: error);
    }
    return UnexpectedFailure(cause: error);
  }

  /// Maps a dio failure, honouring the uniform REST error body shape
  /// `{"error":{"code","message","correlationId"}}`.
  AppFailure fromDio(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return TimeoutFailure(cause: error);
      case DioExceptionType.badResponse:
        return _fromResponse(error);
      case DioExceptionType.connectionError:
        final cause = error.error;
        if (cause is SocketException) return fromSocket(cause);
        return NetworkFailure(cause: error);
      case DioExceptionType.transformTimeout:
      case DioExceptionType.cancel:
        return const UnexpectedFailure(
          message: 'Request cancelled',
          code: 'CANCELLED',
        );
      case DioExceptionType.badCertificate:
        return NetworkFailure(
          message: 'Invalid server certificate',
          cause: error,
        );
      case DioExceptionType.unknown:
        final cause = error.error;
        if (cause is SocketException) return fromSocket(cause);
        if (cause is TimeoutException) return fromTimeout(cause);
        if (cause is FormatException) return fromFormat(cause);
        return NetworkFailure(cause: error);
    }
  }

  /// Maps a DNS/refused/reset socket error.
  AppFailure fromSocket(SocketException error) =>
      NetworkFailure(message: "Couldn't reach the backend", cause: error);

  /// Maps a decode failure. [protocol] is true for wire parsing (malformed
  /// frame) and false for user input, where the value is merely invalid.
  AppFailure fromFormat(FormatException error, {bool protocol = true}) {
    if (protocol) {
      return ProtocolFailure(
        message: 'Malformed message from the backend',
        cause: error,
      );
    }
    return ValidationFailure(message: error.message, cause: error);
  }

  /// Maps a connect/receive timeout.
  AppFailure fromTimeout(TimeoutException error) =>
      TimeoutFailure(cause: error);

  /// Maps a socket-channel failure. A handshake that never completed is a
  /// network problem; a channel that failed mid-stream is a protocol problem.
  AppFailure fromWebSocket(WebSocketChannelException error) {
    final Object? inner = error.inner;
    if (inner is SocketException) return fromSocket(inner);
    if (inner is TimeoutException) return fromTimeout(inner);
    if (inner is FormatException) return fromFormat(inner);
    return NetworkFailure(message: 'WebSocket connection failed', cause: error);
  }

  /// Maps any cache-layer error. Never user-visible on its own.
  AppFailure fromCache(Object error) => CacheFailure(cause: error);

  AppFailure _fromResponse(DioException error) {
    final Response<Object?>? response = error.response;
    final int? status = response?.statusCode;
    final String? code = _errorField(response?.data, 'code');
    final String? message = _errorField(response?.data, 'message');
    final String? correlationId = _errorField(response?.data, 'correlationId');

    if (status == null) {
      return UnexpectedFailure(cause: error);
    }
    if (status >= 500) {
      return ServerFailure(
        message: message ?? 'Server error',
        code: code ?? 'INTERNAL',
        correlationId: correlationId,
        cause: error,
      );
    }
    if (status == 408 || status == 504) {
      return TimeoutFailure(
        message: message ?? 'The backend took too long to answer',
        code: code ?? 'TIMEOUT',
        cause: error,
      );
    }
    if (status == 429) {
      return ValidationFailure(
        message: message ?? 'Too many requests',
        code: code ?? 'RATE_LIMITED',
        cause: error,
      );
    }
    return ValidationFailure(
      message: message ?? 'The request was rejected',
      code: code ?? 'VALIDATION_FAILED',
      cause: error,
    );
  }

  /// Reads one field from the nested `error` object of a REST error body.
  ///
  /// Written with explicit type tests rather than dynamic indexing so the
  /// `avoid_dynamic_calls` and `strict-casts` lints stay satisfied.
  static String? _errorField(Object? body, String field) {
    if (body is! Map<String, Object?>) return null;
    final Object? nested = body['error'];
    if (nested is! Map<String, Object?>) return null;
    final Object? value = nested[field];
    return value is String ? value : null;
  }
}
