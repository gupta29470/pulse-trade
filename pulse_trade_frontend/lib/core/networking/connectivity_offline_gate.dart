import 'package:pulse_trade_frontend/core/network_connectivity/service/connectivity_service.dart';
import 'package:pulse_trade_frontend/core/networking/market_api.dart';

/// The production [OfflineGate]: internet reachability plus one honest probe.
///
/// The rule is:
/// * `disconnected` ⇒ refuse every call. No DNS, no dial, no timeout wait.
/// * `null` (the first probe has not answered yet) ⇒ allow **exactly one**
///   attempt, so a cold start is not blocked by a connectivity check that is
///   itself racing the first request.
/// * `connected` ⇒ allow.
///
/// A definitive reading re-arms the one-probe allowance, so a later moment of
/// uncertainty gets its own probe rather than inheriting a spent one.
final class ConnectivityOfflineGate implements OfflineGate {
  /// Creates the gate over [_connectivity].
  ConnectivityOfflineGate({required this._connectivity});

  final ConnectivityService _connectivity;

  bool _probeUsed = false;
  bool _lastWasUnknown = true;

  @override
  Future<bool> canCall() async {
    final InternetStatus? status = _connectivity.internetStatus;

    if (status == null) {
      if (_lastWasUnknown && _probeUsed) return false;
      _lastWasUnknown = true;
      _probeUsed = true;
      return true;
    }

    _lastWasUnknown = false;
    if (status == InternetStatus.connected) {
      _probeUsed = false;
      return true;
    }
    return false;
  }

  /// Re-arms the single-probe allowance. Called when the app returns to the
  /// foreground so the next moment of uncertainty probes again.
  void reset() {
    _probeUsed = false;
  }
}
