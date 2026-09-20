/// A coarse description of how responsive the internet path looked when it was
/// last measured.
///
/// **Informational only.** The delivery tier is the backend's decision: the
/// frontend never promotes or demotes a tier from a locally measured latency,
/// and no widget branches on this value to change market behaviour. It exists so
/// Diagnostics can show a readout, and so
/// `ConnectivityService.getNetworkQuality()` has a typed return.
enum NetworkQuality {
  /// The measured round trip was faster than the "excellent" cut-off.
  excellent,

  /// The measured round trip landed between the "excellent" and "good"
  /// cut-offs.
  good,

  /// The measured round trip landed between the "good" and "fair" cut-offs.
  fair,

  /// The measured round trip was at or above the "fair" cut-off: the path
  /// answers, but slowly.
  poor,

  /// Nothing was measured, or nothing answered. This is not the same as
  /// offline — it is the absence of a usable sample.
  unknown,
}
