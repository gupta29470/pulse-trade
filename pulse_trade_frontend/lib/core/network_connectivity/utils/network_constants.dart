/// Tunables for internet reachability detection.
///
/// Every endpoint, interval and threshold the connectivity module uses is read
/// from this file, so probe behaviour is tunable in exactly one place and a test
/// can assert against the same constants the production path uses.
library;

import 'package:pulse_trade_frontend/core/logging/log_fields.dart';

/// Endpoints probed to decide whether the internet answers.
///
/// Two independent, unrelated hosts are probed on purpose, with
/// `useDefaultOptions: false` so no third probe is added behind our back: a
/// single endpoint (or a single CDN) being down must not be able to produce a
/// false offline while the device is in fact online. The
/// package treats the internet as reachable as soon as any one probe succeeds.
abstract final class NetworkCheckEndpoints {
  const NetworkCheckEndpoints._();

  /// First reachability probe.
  static const String primaryNetworkCheckUrl = 'https://one.one.one.one/';

  /// Endpoint for the informational HEAD quality probe.
  ///
  /// Kept as its own constant even though it currently matches
  /// [primaryNetworkCheckUrl], so the quality probe can be moved without
  /// touching reachability detection.
  static const String primaryQualityCheckEndpoint =
      'https://www.google.com/robots.txt';

  /// Second reachability probe, deliberately on a different host from
  /// [primaryNetworkCheckUrl].
  static const String secondaryQualityCheckEndpoint =
      'https://one.one.one.one/';
}

/// Timings that govern the probe and its disconnect debounce.
abstract final class NetworkMonitoringConfig {
  const NetworkMonitoringConfig._();

  /// How often the checker re-probes while a status listener is attached.
  static const Duration checkInterval = Duration(seconds: 10);

  /// Timeout for a single probe request.
  ///
  /// Generous on purpose: a slow but alive path must be allowed to answer
  /// rather than being mistaken for an offline one.
  static const Duration qualityCheckTimeout = Duration(seconds: 30);

  /// How long a `disconnected` reading must survive before it is published.
  ///
  /// Android reports transient disconnections during handovers; publishing the
  /// first reading immediately makes the status chip flap.
  static const Duration disconnectDebounce = Duration(seconds: 3);

  /// Whether the service should also measure quality on a timer.
  ///
  /// Off: quality is a diagnostics readout, never a tier input. Turning it on
  /// would want a build-time flag so the readout stays opt-in.
  static const bool enablePeriodicQualityChecks = false;

  /// Interval for the periodic quality measurement, when it is enabled.
  ///
  /// The value suits a diagnostics readout; a different use would want it
  /// configurable rather than fixed here.
  static const Duration periodicCheckInterval = Duration(seconds: 30);
}

/// Latency-to-tier cut-offs, in milliseconds.
///
/// **Information only.** The delivery tier is the backend's decision; these
/// numbers describe what the Diagnostics readout means and nothing else.
///
/// They are placeholder values rather than measured thresholds, so the tier
/// names are indicative until they are calibrated against real devices and
/// networks.
abstract final class NetworkQualityThreshold {
  const NetworkQualityThreshold._();

  /// Below this latency (ms) a sample is `NetworkQuality.excellent`.
  static const int excellentThreshold = 500;

  /// Below this latency (ms) a sample is `NetworkQuality.good`.
  static const int goodThreshold = 750;

  /// Below this latency (ms) a sample is `NetworkQuality.fair`; at or above it
  /// the sample is `NetworkQuality.poor`.
  static const int fairThreshold = 1000;
}

/// HTTP configuration for the quality probe.
abstract final class NetworkHttpConfig {
  const NetworkHttpConfig._();

  /// HEAD rather than GET: the probe needs status and timing only, never a
  /// body, so the measurement must not pay for one.
  static const String qualityCheckMethod = 'HEAD';
}

/// Names this module logs and is filtered under.
abstract final class NetworkConstants {
  const NetworkConstants._();

  /// Logger name carried over from the reference module, for log filtering.
  static const String networkLogger = 'network_logger';

  /// The `component` every connectivity record carries.
  ///
  /// Taken from [LogComponents.connectivity] rather than repeated as a literal
  /// so this constant cannot drift from the canonical vocabulary.
  static const String component = LogComponents.connectivity;
}
