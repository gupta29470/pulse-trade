import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/core/networking/connection_status.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_health.dart';
import 'package:pulse_trade_frontend/domain/entities/market_status.dart';
import 'package:pulse_trade_frontend/features/diagnostics/diagnostics_state.dart';
import 'package:pulse_trade_frontend/features/diagnostics/widgets/diagnostics_section.dart';
import 'package:pulse_trade_frontend/features/diagnostics/widgets/diagnostics_sections.dart';
import 'package:pulse_trade_frontend/features/diagnostics/widgets/tier_segmented_cards.dart';

/// The Connectivity Matrix: four independent layers, never one boolean.
///
/// It is four rows rather than a status pill because "backend CONNECTED + engine
/// PAUSED" and "backend UNREACHABLE + internet ONLINE" are different situations,
/// and a single boolean would collapse them into the same lie.
class ConnectivitySection extends StatelessWidget {
  /// Creates the section.
  const ConnectivitySection({super.key, required this.state});

  /// The readout being rendered.
  final DiagnosticsState state;

  @override
  Widget build(BuildContext context) {
    final MarketEngineState engine =
        state.engineState ?? MarketEngineState.unknown;
    final String internet = state.internetStatus;
    final String backend = backendLabel(state.backendStatus);
    final String engineLabel = engine.wire;
    final String socket = socketLabel(state.backendStatus);

    int online = 0;
    if (DiagnosticsFormat.isOnline(internet)) online++;
    if (DiagnosticsFormat.isOnline(backend)) online++;
    if (DiagnosticsFormat.isOnline(engineLabel)) online++;
    if (DiagnosticsFormat.isOnline(socket)) online++;

    return DiagnosticsCard(
      child: DiagnosticsSection(
        title: 'Connectivity Matrix',
        trailing: '$online / 4 ONLINE',
        rows: <DiagnosticRow>[
          DiagnosticRow(
            'Internet',
            internet,
            valueColor: DiagnosticsFormat.forState(internet),
          ),
          DiagnosticRow(
            'Go Backend',
            backend,
            valueColor: DiagnosticsFormat.forState(backend),
          ),
          DiagnosticRow(
            'Market Engine',
            engineLabel,
            valueColor: DiagnosticsFormat.forState(engineLabel),
          ),
          DiagnosticRow(
            'WebSocket',
            socket,
            valueColor: DiagnosticsFormat.forState(socket),
          ),
        ],
      ),
    );
  }

  /// Maps the socket enum onto the backend-layer vocabulary.
  ///
  /// `disconnected` is reported as `UNREACHABLE` rather than `OFFLINE` on
  /// purpose: `OFFLINE` belongs to the internet layer, and reusing it here is
  /// exactly the collapse the Connectivity Matrix forbids.
  static String backendLabel(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.disconnected:
        return 'UNREACHABLE';
      case ConnectionStatus.connecting:
        return 'CONNECTING';
      case ConnectionStatus.connected:
        return 'CONNECTED';
      case ConnectionStatus.reconnecting:
        return 'RECONNECTING';
    }
  }

  /// The WebSocket row's own vocabulary: transport states, not layer states.
  static String socketLabel(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.disconnected:
        return 'CLOSED';
      case ConnectionStatus.connecting:
        return 'CONNECTING';
      case ConnectionStatus.connected:
        return 'CONNECTED';
      case ConnectionStatus.reconnecting:
        return 'RECONNECTING';
    }
  }
}

/// Adaptive delivery: the tier cards plus the backend's own rate numbers.
class AdaptiveDeliverySection extends StatelessWidget {
  /// Creates the section.
  const AdaptiveDeliverySection({super.key, required this.state});

  /// The readout being rendered.
  final DiagnosticsState state;

  @override
  Widget build(BuildContext context) {
    final DeliveryHealth delivery = state.delivery ?? DeliveryHealth.unknown;
    final bool hasReport = delivery.receivedAt != null;
    return DiagnosticsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          DiagnosticsSection(
            title: 'Adaptive Delivery State',
            // The header restates tier and rate because the reviewer's eye lands
            // there first; the rows below explain where those numbers came from.
            trailing: hasReport
                ? '${delivery.tier.wire} · '
                      '${delivery.effectiveRatePerSec.toStringAsFixed(0)}/s'
                : 'AWAITING FIRST REPORT',
            rows: <DiagnosticRow>[
              // Queue depth is a delivery-layer fact, not a connectivity one:
              // it belongs next to the rates it perturbs, not next to the chip.
              DiagnosticRow(
                'Outbound Queue',
                hasReport
                    ? '${delivery.queuedMessages}'
                    : DiagnosticsFormat.unknown,
              ),
              DiagnosticRow(
                'Dropped (tier)',
                hasReport
                    ? '${delivery.droppedMessages}'
                    : DiagnosticsFormat.unknown,
                valueColor: delivery.droppedMessages > 0
                    ? AppColors.warn
                    : null,
              ),
            ],
          ),
          TierSegmentedCards(
            active: delivery.tier,
            overrideTier: delivery.tierOverride,
            targetRatePerSec: delivery.targetRatePerSec,
            effectiveRatePerSec: delivery.effectiveRatePerSec,
            reason: delivery.reason,
            coalescedCount: delivery.coalescedCount,
          ),
        ],
      ),
    );
  }
}
