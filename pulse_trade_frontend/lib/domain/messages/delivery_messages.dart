import 'package:pulse_trade_frontend/domain/entities/delivery_health.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';

/// `health` — the backend's report of how it is delivering to this session.
///
/// This frame is the app's only source of tier, override, target rate,
/// effective rate.
final class HealthMessage extends ServerMessage {
  /// Creates a health message.
  const HealthMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.health,
  });

  /// The reported delivery state.
  final DeliveryHealth health;

  @override
  String get type => 'health';

  @override
  List<Object?> get props => <Object?>[...super.props, health];
}
