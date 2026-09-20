import 'package:flutter/foundation.dart';

/// Whether this build carries the debug console.
///
/// Debug builds do. A release build opts in at compile time with
/// `--dart-define=PULSETRADE_DEBUG_CONSOLE=true`, which exists so the build that has
/// to demonstrate a forced tier change can be a release build — the alternative was
/// shipping a debug build for the demo, which is slower and larger.
///
/// The flag decides whether the console is **registered**: with it off, neither the
/// route nor the two entry points are created, and the build behaves exactly as a
/// release build always has. It is not a way to remove code from a binary — the
/// router's route list is built from a runtime parameter, so the screen stays
/// compiled in either way. Measured: a release build with the flag on and one with it
/// off produce `libapp.so` files of identical size (the folded branches are the same
/// size) whose contents differ, which is how the flag was confirmed to reach the AOT
/// compile at all.
const bool debugConsoleEnabled = bool.fromEnvironment(
  'PULSETRADE_DEBUG_CONSOLE',
  defaultValue: kDebugMode,
);
