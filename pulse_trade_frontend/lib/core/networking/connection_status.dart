/// The transport's connection lifecycle, independent of internet reachability
/// and of market liveness — three layers, never one boolean.
enum ConnectionStatus {
  /// No socket and no attempt in flight.
  disconnected,

  /// A dial is in flight.
  connecting,

  /// `welcome` received and the socket is usable.
  connected,

  /// A drop was observed and a retry is scheduled.
  reconnecting,
}
