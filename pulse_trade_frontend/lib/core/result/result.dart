import 'package:pulse_trade_frontend/core/error/app_failure.dart';

/// The outcome of an operation that can fail with a typed [AppFailure].
///
/// The app never lets a raw exception cross a layer boundary: repositories and
/// use cases return `Result` so a caller has to acknowledge the failure case,
/// and blocs therefore never have to wrap calls in `try`/`catch` themselves.
sealed class Result<T> {
  /// Const constructor so `const Ok(...)` is possible where the payload is const.
  const Result();

  /// True when this is an [Ok].
  bool get isOk => this is Ok<T>;

  /// True when this is an [Err].
  bool get isErr => this is Err<T>;

  /// The success payload, or `null` when this is an [Err].
  T? get valueOrNull {
    final self = this;
    return self is Ok<T> ? self.value : null;
  }

  /// The failure, or `null` when this is an [Ok].
  AppFailure? get failureOrNull {
    final self = this;
    return self is Err<T> ? self.failure : null;
  }

  /// Transforms the success payload, preserving a failure unchanged.
  Result<R> map<R>(R Function(T value) transform) {
    final self = this;
    if (self is Ok<T>) {
      return Ok<R>(transform(self.value));
    }
    return Err<R>((self as Err<T>).failure);
  }

  /// Folds both cases into a single value.
  R when<R>({
    required R Function(T value) ok,
    required R Function(AppFailure failure) err,
  }) {
    final self = this;
    if (self is Ok<T>) {
      return ok(self.value);
    }
    return err((self as Err<T>).failure);
  }
}

/// A successful [Result].
final class Ok<T> extends Result<T> {
  /// Wraps [value] as a success.
  const Ok(this.value);

  /// The successful payload.
  final T value;

  @override
  String toString() => 'Ok($value)';

  @override
  bool operator ==(Object other) => other is Ok<T> && other.value == value;

  @override
  int get hashCode => Object.hash(Ok<T>, value);
}

/// A failed [Result] carrying a typed [AppFailure].
final class Err<T> extends Result<T> {
  /// Wraps [failure] as an error.
  const Err(this.failure);

  /// The typed failure.
  final AppFailure failure;

  @override
  String toString() => 'Err($failure)';

  @override
  bool operator ==(Object other) => other is Err<T> && other.failure == failure;

  @override
  int get hashCode => Object.hash(Err<T>, failure);
}
