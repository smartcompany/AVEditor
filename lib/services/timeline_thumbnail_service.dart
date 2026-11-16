import 'dart:io';
import 'dart:ui' as ui;

import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/timeline_filmstrip_frame.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/media_concat_service.dart';
import 'package:aveditor/services/video_frame_grab.dart';
import 'package:aveditor/utils/av_editor_log.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Builds and caches a filmstrip of frames for the timeline clip track.
class TimelineThumbnailService {
  const TimelineThumbnailService();

  static const _maxFrames = 36;
  static const _minFrames = 8;
  static const _thumbHeight = 96;

  /// Loads frames for every media asset referenced by [segments].
  Future<List<TimelineFilmstripFrame>> loadProjectFilmstrip(
    VideoProject project, {
    List<ClipSegment>? segments,
  }) async {
    final segs = segments ?? project.segments;
    if (segs.isEmpty) return const [];

    if (project.mediaAssets.isEmpty) {
      return loadFilmstrip(
        videoPath: project.sourcePath,
        duration: project.duration,
        segments: segs,
      );
    }

    final frames = <TimelineFilmstripFrame>[];
    final seen = <String>{};
    for (final segment in segs) {
      final id = segment.mediaId;
      if (id == null || !seen.add(id)) continue;
      final asset = project.assetById(id);
      if (asset == null) continue;
      final path = project.absoluteMediaPath(asset);
      if (!await File(path).exists()) {
        avEditorLog('filmstrip missing media $path');
        continue;
      }
      if (asset.isImage || MediaConcatService.isImagePath(path)) {
        frames.addAll(await _loadImageStill(path, mediaId: id));
      } else {
        final duration = asset.duration > Duration.zero
            ? asset.duration
            : (segment.end > segment.start ? segment.end : const Duration(seconds: 1));
        frames.addAll(
          await loadFilmstrip(
            videoPath: path,
            duration: duration,
            segments: [segment],
            mediaId: id,
          ),
        );
      }
    }
    frames.sort((a, b) {
      final byMedia = (a.mediaId ?? '').compareTo(b.mediaId ?? '');
      if (byMedia != 0) return byMedia;
      return a.sourceTime.compareTo(b.sourceTime);
    });
    return frames;
  }

  Future<List<TimelineFilmstripFrame>> loadFilmstrip({
    required String videoPath,
    required Duration duration,
    List<ClipSegment> segments = const [],
    String? mediaId,
  }) async {
    if (duration <= Duration.zero || !await File(videoPath).exists()) {
      return const [];
    }

    final frameCount = _frameCountFor(duration);
    final durationMs = duration.inMilliseconds;
    // Stay off the last millisecond — short/probe-rounded clips often have no
    // frame there and ffmpeg exits 0 with an empty file.
    final lastSafeMs = durationMs <= 1
        ? 0
        : (durationMs > 500 ? durationMs - 250 : durationMs ~/ 2);
    final stepMs =
        (durationMs / frameCount).ceil().clamp(1, 1 << 30);
    final cacheDir = await _cacheDirectory(videoPath);
    final frames = <TimelineFilmstripFrame>[];
    final capturedMs = <int>{};

    Future<void> addFrame(int timeMs) async {
      final clampedMs = timeMs.clamp(0, lastSafeMs);
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
          mediaId: mediaId,
        ),
      );
    }

    for (var i = 0; i < frameCount; i++) {
      await addFrame(stepMs * i);
    }
    await addFrame(lastSafeMs);

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

  Future<List<TimelineFilmstripFrame>> _loadImageStill(
    String imagePath, {
    required String mediaId,
  }) async {
    if (!await File(imagePath).exists()) return const [];
    final cacheDir = await _cacheDirectory(imagePath);
    final cacheFile = File(p.join(cacheDir.path, 'still.jpg'));

    if (!await cacheFile.exists() || await cacheFile.length() == 0) {
      var ready = false;
      // Prefer a JPEG copy so ui.instantiateImageCodec can decode HEIC/PNG too.
      try {
        final ext = p.extension(imagePath).toLowerCase();
        if (ext == '.jpg' || ext == '.jpeg') {
          await File(imagePath).copy(cacheFile.path);
          ready = await cacheFile.exists() && await cacheFile.length() > 0;
        }
      } catch (_) {}
      if (!ready) {
        ready = await _ffmpegImageJpeg(imagePath, cacheFile.path);
      }
      if (!ready) return const [];
    }

    try {
      final bytes = await cacheFile.readAsBytes();
      if (bytes.isEmpty) return const [];
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetHeight: _thumbHeight,
      );
      final frame = await codec.getNextFrame();
      return [
        TimelineFilmstripFrame(
          sourceTime: Duration.zero,
          image: frame.image,
          mediaId: mediaId,
        ),
      ];
    } catch (error) {
      avEditorLog('filmstrip image decode failed: $error');
      return const [];
    }
  }

  Future<bool> _ffmpegImageJpeg(String imagePath, String output) async {
    try {
      final session = await FFmpegKit.executeWithArguments([
        '-y',
        '-i',
        imagePath,
        '-frames:v',
        '1',
        '-update',
        '1',
        '-q:v',
        '4',
        output,
      ]);
      final code = await session.getReturnCode();
      final file = File(output);
      return ReturnCode.isSuccess(code) &&
          await file.exists() &&
          await file.length() > 0;
    } catch (error) {
      avEditorLog('filmstrip image ffmpeg failed: $error');
      return false;
    }
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
