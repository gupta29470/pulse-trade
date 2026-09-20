import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Enforces the layering the README claims, by reading the imports.
///
/// A diagram in a document rots the moment someone adds an import; these
/// assertions turn two of the document's sentences into something the build
/// checks. They are deliberately written as *rules about layers* rather than a
/// whitelist of current files, so a new feature file is not a failure — a new
/// feature file that reaches for `dio` is.
void main() {
  /// Every `.dart` file under `lib/`, as `/`-separated paths relative to it.
  final List<String> sources =
      Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .map((File file) => file.path)
          .where((String path) => path.endsWith('.dart'))
          .toList()
        ..sort();

  /// The `package:`/relative targets this file imports.
  List<String> importsOf(String path) => File(path)
      .readAsLinesSync()
      .map((String line) => line.trim())
      .where((String line) => line.startsWith('import '))
      .toList();

  String relative(String path) =>
      path.startsWith('lib/') ? path.substring('lib/'.length) : path;

  bool imports(String path, String target) =>
      importsOf(path).any((String line) => line.contains("'$target'"));

  test('the source tree is discoverable', () {
    // Guards the guards: a bad path would make every assertion below vacuous.
    expect(sources.length, greaterThan(100));
  });

  test('features and domain never import a transport', () {
    const List<String> transports = <String>[
      'package:dio/dio.dart',
      'package:web_socket_channel/web_socket_channel.dart',
    ];
    final List<String> violations = <String>[
      for (final String path in sources)
        if (relative(path).startsWith('features/') ||
            relative(path).startsWith('domain/'))
          for (final String transport in transports)
            if (imports(path, transport)) '$path imports $transport',
    ];
    expect(
      violations,
      isEmpty,
      reason:
          'A feature or domain file must go through a repository or the '
          'MarketApi/MarketWebSocketClient interfaces, never a transport.',
    );
  });

  test('dio and the socket live only in the transport seams', () {
    const List<String> allowedPrefixes = <String>[
      'core/networking/',
      'core/error/',
      'app/bootstrap/',
      'data/repositories/',
    ];
    final List<String> violations = <String>[
      for (final String path in sources)
        if (imports(path, 'package:dio/dio.dart') ||
            imports(path, 'package:web_socket_channel/web_socket_channel.dart'))
          if (!allowedPrefixes.any(relative(path).startsWith))
            '$path is outside the transport seams',
    ];
    expect(violations, isEmpty, reason: allowedPrefixes.join(', '));
  });

  test('the chart package reaches no data source', () {
    final List<String> chartUsers = <String>[
      for (final String path in sources)
        if (imports(path, 'package:fl_chart/fl_chart.dart')) path,
    ];
    expect(chartUsers, isNotEmpty, reason: 'fl_chart stopped being used');

    // The README's claim: `fl_chart` renders data the app owns and performs no
    // I/O. A chart that can reach `dio`, the socket, or a repository could
    // fetch on its own, which is exactly what the claim rules out.
    final List<String> violations = <String>[
      for (final String path in chartUsers)
        for (final String banned in <String>[
          'package:dio/dio.dart',
          'package:web_socket_channel/web_socket_channel.dart',
        ])
          if (imports(path, banned)) '$path imports $banned',
      for (final String path in chartUsers)
        for (final String line in importsOf(path))
          if (line.contains('/repositories/')) '$path imports $line',
    ];
    expect(violations, isEmpty);
  });

  test('there is no WebView dependency', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final List<String> webview = pubspec
        .split('\n')
        .where((String line) => line.toLowerCase().contains('webview'))
        .toList();
    expect(webview, isEmpty);
    final List<String> users = <String>[
      for (final String path in sources)
        if (importsOf(path).any((String line) => line.contains('webview')))
          path,
    ];
    expect(users, isEmpty);
  });
}
