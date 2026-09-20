import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/widgets/app_card.dart';
import 'package:pulse_trade_frontend/app/widgets/card_header.dart';
import 'package:pulse_trade_frontend/features/orderbook/order_book_state.dart';
import 'package:pulse_trade_frontend/features/orderbook/widgets/order_book_view.dart';

/// The order-book block of the market screen.
///
/// Deliberately thin: the card and its header are chrome, and everything that
/// can be wrong about a book — the sequencing state, the projection, the
/// provenance label — is already resolved in [OrderBookStateModel]. A section
/// that inspected the state itself would be a second place for the rules
/// to drift.
///
/// The card is created with `EdgeInsets.zero` so the [CardHeader]'s divider
/// reaches the card's edges, and the body re-applies the standard 12dp inset
/// itself. The `CACHED`/`STALE`/`SYNCING` tag is rendered by [OrderBookView]'s
/// status line rather than as `CardHeader.trailing`: it then sits next to the
/// spread it qualifies, a caller that composes the view without the card chrome
/// still gets a labelled book, and the tag is never repeated twice on one
/// section.
class OrderBookSection extends StatelessWidget {
  /// Creates the section.
  const OrderBookSection({super.key, required this.state, this.onRetry});

  /// The immutable projection to render.
  final OrderBookStateModel state;

  /// Retry action for the terminal error state, forwarded to the view.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // The section chrome stays thin: the touch badges and the provenance
          // tag are rendered by [OrderBookView], which keeps both readouts next
          // to the levels they describe and keeps a standalone view truthful.
          // A 36dp header cannot host the two-line badge pair without clipping
          // at a 1.3 text scale, so it deliberately carries no trailing widget.
          const CardHeader(title: 'Order Book'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.spaceSm),
            child: OrderBookView(state: state, onRetry: onRetry),
          ),
        ],
      ),
    );
  }
}
