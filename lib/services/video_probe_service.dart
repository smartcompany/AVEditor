import 'package:aveditor/services/native_video_engine.dart';

/// Reads basic metadata from a media file via the native video engine
/// (AVFoundation on iOS, MediaMetadataRetriever / Media3 on Android).
class VideoProbeService {
  const VideoProbeService();

  Future<bool> hasAudioStream(String path) async {
    final info = await NativeVideoEngine.instance.probe(path);
    return info.hasAudio;
  }

  /// Media duration (video or audio). Null when probing fails.
  Future<Duration?> readDuration(String path) async {
    try {
      final info = await NativeVideoEngine.instance.probe(path);
      return info.duration;
    } catch (_) {
      return null;
    }
  }

  Future<({int width, int height})> readFrameSize(
    String path, {
    int fallbackWidth = 1080,
    int fallbackHeight = 1920,
  }) async {
    try {
      final info = await NativeVideoEngine.instance.probe(path);
      if (info.width > 0 && info.height > 0) {
        return (width: info.width, height: info.height);
      }
    } catch (_) {}
    return (width: fallbackWidth, height: fallbackHeight);
  }
}
