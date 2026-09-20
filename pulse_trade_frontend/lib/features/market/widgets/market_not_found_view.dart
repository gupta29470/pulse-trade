import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/widgets/empty_state.dart';

/// The dedicated state for a symbol the roster does not contain.
///
/// A missing symbol is not an error and not an empty market: it can only be
/// decided **after** the roster has loaded, because before that "absent" and
/// "not loaded yet" are indistinguishable. This view therefore renders only
/// full-screen copy and one way out, never a blank scaffold.
class MarketNotFoundView extends StatelessWidget {
  /// Creates the view.
  ///
  /// [onBack] is wired to the "Back to watchlist" action; when it is `null` the
  /// action is omitted rather than rendered as a dead button.
  const MarketNotFoundView({super.key, required this.symbol, this.onBack});

  /// The canonical symbol id that could not be resolved.
  final String symbol;

  /// Navigates back to the watchlist.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: const Text('Market')),
      body: Center(
        child: EmptyState(
          title: 'Market $symbol not found',
          message:
              'This symbol is not in the market roster. The link may be '
              'out of date.',
          icon: Icons.search_off,
          // `EmptyState` exposes a single labelled action; reusing it keeps the
          // not-found screen visually identical to every other empty screen.
          onRetry: onBack,
          retryLabel: 'Back to watchlist',
        ),
      ),
      // The empty state is vertically centred but must not collide with the
      // system inset on a gesture-navigation device.
      bottomNavigationBar: const SizedBox(height: AppSpacing.spaceXs),
    );
  }
}
