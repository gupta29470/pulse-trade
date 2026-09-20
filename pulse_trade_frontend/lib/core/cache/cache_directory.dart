import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Resolves the directory the file cache lives in.
///
/// The umbrella `path_provider` package is not a dependency: its Apple
/// implementation pulls in `objective_c`, whose build hook needs an Apple SDK
/// at test time, and this app is Android-only. The two paths the cache needs
/// are available from the platform interface directly, which is also what the
/// umbrella package calls.
abstract final class CacheDirectory {
  /// The OS cache directory, or null when the platform cannot provide one.
  static Future<String?> applicationCache() =>
      PathProviderPlatform.instance.getApplicationCachePath();

  /// The OS temporary directory, used when no cache directory is available.
  static Future<String?> temporary() =>
      PathProviderPlatform.instance.getTemporaryPath();
}
