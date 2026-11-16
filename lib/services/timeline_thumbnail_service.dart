import 'dart:io';
import 'dart:ui' as ui;

import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/timeline_filmstrip_frame.dart';
import 'package:aveditor/services/video_frame_grab.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Builds and caches a filmstrip of frames for the timeline clip track.
class TimelineThumbnailService {
  const TimelineThumbnailService();

  static const _maxFrames = 36;
  static const _minFrames = 8;
  static const _thumbHeight = 96;

  Future<List<TimelineFilmstripFrame>> loadFilmstrip({
    required String videoPath,
    required Duration duration,
    List<ClipSegment> segments = const [],
  }) async {
    if (duration <= Duration.zero || !await File(videoPath).exists()) {
      return const [];
    }

    final frameCount = _frameCountFor(duration);
    final stepMs =
        (duration.inMilliseconds / frameCount).ceil().clamp(1, 1 << 30);
    final cacheDir = await _cacheDirectory(videoPath);
    final frames = <TimelineFilmstripFrame>[];
    final capturedMs = <int>{};

    Future<void> addFrame(int timeMs) async {
      final clampedMs = timeMs.clamp(0, duration.inMilliseconds - 1);
      if (!capturedMs.add(clampedMs)) return;

      final cacheFile = File(
        p.join(cacheDir.path, 'thumb_${clampedMs}ms.jpg'),
      );

      if (!await cacheFile.exists()) {
        final generated = await const VideoFrameGrab().jpegFile(
          video: videoPath,
          thumbnailPath: cacheFile.path,
          timeMs: clampedMs,
          maxHeight: _thumbHeight,
          quality: 65,
          accurate: true,
        );
        if (generated != null &&
            p.normalize(generated) != p.normalize(cacheFile.path)) {
          await File(generated).copy(cacheFile.path);
        }
      }

      if (!await cacheFile.exists()) return;

      final bytes = await cacheFile.readAsBytes();
      if (bytes.isEmpty) return;

      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      frames.add(
        TimelineFilmstripFrame(
          sourceTime: Duration(milliseconds: clampedMs),
          image: frame.image,
        ),
      );
    }

    for (var i = 0; i < frameCount; i++) {
      await addFrame(stepMs * i);
    }

    // Cover the clip end — evenly spaced frames often stop short of duration.
    await addFrame(duration.inMilliseconds - 1);

    // Multi-import / cut segments: pin a frame near each clip start so short
    // image clips are not painted with a neighbor video keyframe.
    for (final segment in segments) {
      if (segment.duration <= Duration.zero) continue;
      await addFrame(segment.start.inMilliseconds);
      if (segment.duration.inMilliseconds >= 500) {
        await addFrame(
          segment.start.inMilliseconds + segment.duration.inMilliseconds ~/ 2,
        );
      }
    }

    frames.sort(
      (a, b) => a.sourceTime.compareTo(b.sourceTime),
    );

    return frames;
  }

  int _frameCountFor(Duration duration) {
    final seconds = duration.inSeconds.clamp(1, 120);
    return seconds.clamp(_minFrames, _maxFrames);
  }

  Future<Directory> _cacheDirectory(String videoPath) async {
    final root = await getTemporaryDirectory();
    final stat = await File(videoPath).stat();
    // Include size so a replaced source.mp4 with the same mtime resolution
    // cannot reuse stale wrong JPEGs.
    final key =
        '${videoPath.hashCode}_${stat.modified.millisecondsSinceEpoch}_${stat.size}';
    final dir = Directory(p.join(root.path, 'aveditor_timeline_thumbs', key));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
