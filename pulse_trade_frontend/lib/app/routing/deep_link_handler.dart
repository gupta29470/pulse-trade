import 'package:flutter/services.dart';
import 'package:pulse_trade_frontend/app/routing/app_router.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';

/// Routes `pulsetrade://` links into the app.
///
/// The Android manifest registers the scheme, so the platform hands the intent
/// to the activity; this is the other half — reading the URI and turning it into
/// a location the router understands.
///
/// A link can arrive two ways, and both are handled: **cold**, in the intent
/// that started the process, which is collected once at attach time; and
/// **warm**, while the app is already running, which the platform pushes as it
/// arrives.
///
/// A link this build does not recognise is ignored rather than routed somewhere
/// arbitrary, so an old or mistyped link cannot land the user on a screen they
/// did not ask for.
final class DeepLinkHandler {
  /// Creates a handler that navigates [router].
  DeepLinkHandler({required this._router, MethodChannel? channel})
    : _channel = channel ?? channelName;

  /// The channel the Android shell pushes links on.
  static const MethodChannel channelName = MethodChannel('pulsetrade/deeplink');

  static const String _msgOpened = 'deeplink_opened';
  static const String _msgIgnored = 'deeplink_ignored';

  final AppRouter _router;
  final MethodChannel _channel;

  /// Starts listening, and drains a link that started the process.
  ///
  /// A missing plugin is not an error: the desktop test host and iOS have no
  /// activity to forward an intent, so the handler simply has nothing to do.
  Future<void> attach() async {
    _channel.setMethodCallHandler(_onCall);
    try {
      final String? initial = await _channel.invokeMethod<String>('initial');
      if (initial != null) open(initial);
    } on MissingPluginException {
      // No platform half on this host; links arrive by another mechanism or not
      // at all.
    } catch (error) {
      AppLogger.debug(
        _msgIgnored,
        fields: <String, Object?>{
          LogFields.component: LogComponents.session,
          LogFields.error: '$error',
        },
      );
    }
  }

  Future<void> _onCall(MethodCall call) async {
    final Object? arguments = call.arguments;
    if (call.method == 'open' && arguments is String) open(arguments);
  }

  /// Navigates to the location [raw] names, returning whether it was used.
  bool open(String raw) {
    final String? location = AppRouter.locationForRawDeepLink(raw);
    if (location == null) {
      AppLogger.debug(
        _msgIgnored,
        fields: <String, Object?>{
          LogFields.component: LogComponents.session,
          LogFields.reason: 'unrecognised_link',
        },
      );
      return false;
    }
    AppLogger.info(
      _msgOpened,
      fields: <String, Object?>{
        LogFields.component: LogComponents.session,
        LogFields.reason: location,
      },
    );
    _router.router.go(location);
    return true;
  }

  /// Stops listening. Safe to call more than once.
  void dispose() => _channel.setMethodCallHandler(null);
}
