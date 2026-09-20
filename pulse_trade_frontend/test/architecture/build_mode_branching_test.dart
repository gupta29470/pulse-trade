import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Screens must not branch on the Flutter build mode.
///
/// `kDebugMode` and `kReleaseMode` are compile-time constants that no test can vary,
/// so anything that branches on them is only observable in the mode it was compiled
/// for — which is how the debug console stayed reachable but empty in a release build
/// that had opted into it: the router registered the route on the build flag while the
/// page itself still refused to render its body on `kReleaseMode`. Both places have to
/// read the same flag, and this pins that they do.
///
/// The rule is deliberately about the source text rather than behaviour, because the
/// behaviour it guards cannot be reached from a test: `flutter test` always compiles in
/// debug mode. Build-mode decisions belong to `lib/app/build_flags.dart`; screens ask
/// that flag instead.
void main() {
  test('no screen under lib/features branches on the build mode', () {
    final Directory features = Directory('lib/features');
    expect(
      features.existsSync(),
      isTrue,
      reason: 'run from the package root, or this rule is vacuous',
    );

    final RegExp buildMode = RegExp(
      r'\b(kDebugMode|kReleaseMode|kProfileMode)\b',
    );
    final List<String> violations = <String>[];

    for (final FileSystemEntity entity in features.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Comments are stripped first: this rule is about code, and the doc comment
      // that explains *why* the rule exists necessarily names the constant. Only
      // whole-line comments are removed, so a `//` inside a string (a URL, say)
      // cannot hide code from the scan.
      final String source = entity
          .readAsStringSync()
          .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
          .split('\n')
          .where((String line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      for (final RegExpMatch match in buildMode.allMatches(source)) {
        violations.add('${entity.path}: ${match.group(0)}');
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'read debugConsoleEnabled from lib/app/build_flags.dart instead, so the '
          'decision can be compiled either way and still be tested',
    );
  });
}
