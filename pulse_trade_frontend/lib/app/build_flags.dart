import 'package:flutter/foundation.dart';

/// Whether this build carries the debug console.
///
/// Debug builds do. A release build opts in at compile time with
/// `--dart-define=PULSETRADE_DEBUG_CONSOLE=true`, which exists so the build that has
/// to demonstrate a forced tier change can be a release build — the alternative was
/// shipping a debug build for the demo, which is slower and larger.
///
/// Being `const`, the flag also removes the screen and its entry points from a build
/// that switches it off. It decides only whether the console exists; the debug
/// endpoints it calls are a backend setting of their own, and the tier machine
/// behaves identically whether or not the console is present.
const bool debugConsoleEnabled = bool.fromEnvironment(
  'PULSETRADE_DEBUG_CONSOLE',
  defaultValue: kDebugMode,
);
