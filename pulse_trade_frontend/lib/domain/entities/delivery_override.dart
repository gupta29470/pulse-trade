/// The manual tier override currently in force, as reported by the backend.
///
/// `AUTOMATIC` is the normal case; the others exist because the debug console can
/// pin a tier to demonstrate degradation without touching the network.
enum DeliveryOverride {
  /// The backend's hysteresis machine owns the tier.
  automatic('AUTO'),

  /// Tier pinned to FULL.
  full('FULL'),

  /// Tier pinned to DEGRADED.
  degraded('DEGRADED'),

  /// Tier pinned to MINIMAL.
  minimal('MINIMAL');

  const DeliveryOverride(this.wire);

  /// The exact wire value.
  final String wire;

  /// Parses a wire override, returning `null` when unrecognised.
  static DeliveryOverride? tryParse(String value) {
    for (final DeliveryOverride candidate in DeliveryOverride.values) {
      if (candidate.wire == value) return candidate;
    }
    return null;
  }

  /// True when a human pinned the tier rather than the hysteresis machine.
  bool get isActive => this != DeliveryOverride.automatic;
}
