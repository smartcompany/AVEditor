import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';

/// Reads basic metadata from a video file via FFprobe.
class VideoProbeService {
  const VideoProbeService();

  Future<bool> hasAudioStream(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final streams = session.getMediaInformation()?.getStreams() ?? const [];
    return streams.any((stream) => stream.getType() == 'audio');
  }

  Future<({int width, int height})> readFrameSize(
    String path, {
    int fallbackWidth = 1080,
    int fallbackHeight = 1920,
  }) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final info = session.getMediaInformation();
    final streams = info?.getStreams() ?? const [];
    for (final stream in streams) {
      if (stream.getType() != 'video') continue;
      final width = stream.getWidth();
      final height = stream.getHeight();
      if (width != null && height != null && width > 0 && height > 0) {
        return (width: width, height: height);
      }
    }
    return (width: fallbackWidth, height: fallbackHeight);
  }
}
