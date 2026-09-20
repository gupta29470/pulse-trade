import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/app/routing/app_router.dart';
import 'package:pulse_trade_frontend/app/routing/deep_link_handler.dart';

/// Deep links, from the raw `pulsetrade://` URI to the route the app lands on.
///
/// The Android shell forwards the intent over a channel; what this pins is the
/// half that decides where it goes. A real router is used so the assertion is on
/// the resolved location rather than on a call being made.
void main() {
  late AppRouter app;
  late DeepLinkHandler links;

  setUp(() {
    app = AppRouter.create(debugControlsEnabled: true);
    links = DeepLinkHandler(
      router: app,
      channel: const MethodChannel('pulsetrade/deeplink.test'),
    );
  });

  String location() => app.router.routeInformationProvider.value.uri.toString();

  test('a market link opens that symbol', () {
    expect(links.open('pulsetrade://market/ETHUSDT'), isTrue);
    expect(location(), '/market/ETHUSDT');
  });

  test('a watchlist link opens the watchlist', () {
    expect(links.open('pulsetrade://watchlist'), isTrue);
    expect(location(), '/watchlist');
  });

  test('a market link with no symbol opens the default market', () {
    expect(links.open('pulsetrade://market'), isTrue);
    expect(location(), AppPaths.defaultMarket);
  });

  test('a symbol is normalised to upper case', () {
    expect(links.open('pulsetrade://market/btcusdt'), isTrue);
    expect(location(), '/market/BTCUSDT');
  });

  test('an https app link opens that symbol', () {
    // The shape a chat client will hand over, where the destination is the path.
    expect(
      links.open('https://${AppRouter.appLinkHost}/market/ETHUSDT'),
      isTrue,
    );
    expect(location(), '/market/ETHUSDT');
  });

  test('an https app link opens the watchlist', () {
    expect(links.open('https://${AppRouter.appLinkHost}/watchlist'), isTrue);
    expect(location(), '/watchlist');
  });

  test('an https app link with no symbol opens the default market', () {
    expect(links.open('https://${AppRouter.appLinkHost}/market'), isTrue);
    expect(location(), AppPaths.defaultMarket);
  });

  test('an https link to the API on the same host is ignored', () {
    final String before = location();
    expect(
      links.open('https://${AppRouter.appLinkHost}/api/v1/markets'),
      isFalse,
    );
    expect(
      location(),
      before,
      reason: 'the host serves data as well as links, and data is not a screen',
    );
  });

  test('an https link with no path is ignored', () {
    final String before = location();
    expect(links.open('https://${AppRouter.appLinkHost}'), isFalse);
    expect(location(), before);
  });

  test('an unrecognised host is ignored, not routed', () {
    final String before = location();
    expect(links.open('pulsetrade://nonsense/thing'), isFalse);
    expect(
      location(),
      before,
      reason: 'a link this build cannot map changes nothing',
    );
  });

  test('another scheme is ignored', () {
    final String before = location();
    expect(links.open('https://example.com/market/BTCUSDT'), isFalse);
    expect(location(), before);
  });
}
