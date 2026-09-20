import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/bootstrap/app.dart';
import 'package:pulse_trade_frontend/app/bootstrap/app_bootstrap.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';

/// The process entry point.
///
/// Three safety nets all route into [AppLogger] before anything else happens, so
/// an unexpected error becomes a structured log record (and, where the UI is
/// alive to show it, an in-app notice) instead of a red screen:
///
/// * `runZonedGuarded` catches asynchronous errors that escape every `await`,
/// * `FlutterError.onError` catches framework and build errors,
/// * `PlatformDispatcher.instance.onError` catches engine errors raised outside
/// the Flutter zone.
///
/// Every sink records `component` and `error`, which is what makes
/// `Copy diagnostics JSON` useful in a bug report.
void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (FlutterErrorDetails details) {
        AppLogger.error(
          LogEvents.uncaughtError,
          error: details.exception,
          stackTrace: details.stack,
          fields: <String, Object?>{
            LogFields.component: 'framework',
            LogFields.event: 'flutter_error',
            LogFields.fatal: false,
          },
        );
        // Keep the debug console output too: it is the fastest path to a fix
        // during development, while the structured record above is what ships.
        FlutterError.presentError(details);
      };

      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        AppLogger.error(
          LogEvents.uncaughtError,
          error: error,
          stackTrace: stack,
          fields: <String, Object?>{
            LogFields.component: 'platform',
            LogFields.event: 'platform_error',
            LogFields.fatal: false,
          },
        );
        return true;
      };

      final AppBootstrap bootstrap = await AppBootstrap.initialize();
      runApp(PulseTradeApp(bootstrap: bootstrap));
    },
    (Object error, StackTrace stack) {
      AppLogger.error(
        LogEvents.uncaughtError,
        error: error,
        stackTrace: stack,
        fields: <String, Object?>{
          LogFields.component: 'zone',
          LogFields.event: 'uncaught_zone_error',
          LogFields.fatal: false,
        },
      );
    },
  );
}

/// Debug-only marker kept so an accidental duplicate entry point is obvious
/// during review. Nothing references it, so the tree shaker drops it from release.
const bool kPulseTradeEntryPointLoaded = kDebugMode;
