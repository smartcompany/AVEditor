import 'package:flutter/foundation.dart';

/// Giphy Stickers API keys (one per store listing in the Giphy dashboard).
///
/// A single key works on both OSes; separate keys are only for quota / console
/// tracking. Override with `--dart-define=GIPHY_API_KEY=...` if needed.
abstract final class GiphyConfig {
  static const iosApiKey = String.fromEnvironment(
    'GIPHY_IOS_API_KEY',
    defaultValue: 'fPQ7AaE3gXx5yGxA9gsIw6aYhSzwRUuA',
  );

  static const androidApiKey = String.fromEnvironment(
    'GIPHY_ANDROID_API_KEY',
    defaultValue: 'ZUzz2hNrTMvhNUEWt8YIO0sbVxhgIVRz',
  );

  /// Legacy single-key override (wins over platform defaults when set).
  static const _override = String.fromEnvironment('GIPHY_API_KEY');

  static String get apiKey {
    if (_override.trim().isNotEmpty) return _override.trim();
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return iosApiKey;
      case TargetPlatform.android:
        return androidApiKey;
      default:
        return iosApiKey;
    }
  }
}
