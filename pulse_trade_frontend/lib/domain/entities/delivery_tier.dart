/// The delivery tier the **backend** has chosen for this session.
///
/// The client never derives this value and never estimates a rate; it renders
/// what the `health` frame reports.
enum DeliveryTier {
  /// High fidelity: ~10 chart updates/s, every trade.
  full('FULL', 10.0),

  /// Medium fidelity: ~2 chart updates/s, 500 ms trade batches.
  degraded('DEGRADED', 2.0),

  /// Low bandwidth: ~0.5 chart updates/s, 1 s trade batches.
  minimal('MINIMAL', 0.5);

  const DeliveryTier(this.wire, this.nominalTargetRatePerSec);

  /// The exact wire value.
  final String wire;

  /// The configured target rate for this tier, used only as a fallback when a
  /// `health` frame has not arrived yet. The reported rate always wins.
  final double nominalTargetRatePerSec;

  /// Parses a wire tier, returning `null` when unrecognised.
  static DeliveryTier? tryParse(String value) {
    for (final DeliveryTier tier in DeliveryTier.values) {
      if (tier.wire == value) return tier;
    }
    return null;
  }
}
