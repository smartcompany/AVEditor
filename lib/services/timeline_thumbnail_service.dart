import 'dart:async';
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
import 'package:flutter/painting.dart';
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
      // project.duration is packed timeline length — never use it as the
      // source-file sample window. Cover every segment's local in/out.
      var minStart = segs.first.start;
      var maxEnd = segs.first.end;
      String? mediaId;
      for (final segment in segs) {
        if (segment.start < minStart) minStart = segment.start;
        if (segment.end > maxEnd) maxEnd = segment.end;
        mediaId ??= segment.mediaId;
      }
      if (maxEnd <= minStart) {
        maxEnd = minStart + const Duration(seconds: 1);
      }
      return loadFilmstrip(
        videoPath: project.sourcePath,
        duration: maxEnd - minStart,
        segments: segs,
        mediaId: mediaId,
        baseTime: minStart,
      );
    }

    final frames = <TimelineFilmstripFrame>[];
    final byMedia = <String, List<ClipSegment>>{};
    final fallbackId = project.mediaAssets.first.id;
    for (final segment in segs) {
      final id = segment.mediaId ?? fallbackId;
      (byMedia[id] ??= <ClipSegment>[]).add(segment);
    }

    if (byMedia.isEmpty) {
      for (final asset in project.mediaAssets) {
        byMedia[asset.id] = List<ClipSegment>.from(segs);
      }
    }

    for (final entry in byMedia.entries) {
      final id = entry.key;
      final mediaSegs = entry.value;
      final asset = project.assetById(id);
      if (asset == null) {
        avEditorLog('filmstrip missing asset id=$id');
        continue;
      }
      final path = project.absoluteMediaPath(asset);
      if (!await File(path).exists()) {
        avEditorLog('filmstrip missing media $path');
        continue;
      }
      if (asset.isImage || MediaConcatService.isImagePath(path)) {
        frames.addAll(await _loadImageStill(path, mediaId: id));
        continue;
      }

      // Sample the union of kept windows (+ small pad), not the whole file —
      // full-file accurate ffmpeg grabs were empty/slow and wiped the strip.
      var minStart = mediaSegs.first.start;
      var maxEnd = mediaSegs.first.end;
      for (final segment in mediaSegs) {
        if (segment.start < minStart) minStart = segment.start;
        if (segment.end > maxEnd) maxEnd = segment.end;
      }
      const pad = Duration(milliseconds: 400);
      var base = minStart > pad ? minStart - pad : Duration.zero;
      var end = maxEnd + pad;
      if (asset.duration > Duration.zero && end > asset.duration) {
        end = asset.duration;
      }
      if (end <= base) {
        end = base + const Duration(milliseconds: 1);
      }

      final loaded = await loadFilmstrip(
        videoPath: path,
        duration: end - base,
        segments: mediaSegs,
        mediaId: id,
        baseTime: base,
      );
      avEditorLog(
        'filmstrip media=$id frames=${loaded.length} '
        'baseMs=${base.inMilliseconds} endMs=${end.inMilliseconds}',
      );
      frames.addAll(loaded);
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
    /// Local media time of the first sample (clip in-point).
    Duration baseTime = Duration.zero,
  }) async {
    if (duration <= Duration.zero || !await File(videoPath).exists()) {
      return const [];
    }

    final frameCount = _frameCountFor(duration);
    final durationMs = duration.inMilliseconds;
    final baseMs = baseTime.inMilliseconds;
    // Stay off the last millisecond — short/probe-rounded clips often have no
    // frame there and ffmpeg exits 0 with an empty file.
    final lastOffsetMs = durationMs <= 1
        ? 0
        : (durationMs > 500 ? durationMs - 250 : durationMs ~/ 2);
    final stepMs = (durationMs / frameCount).ceil().clamp(1, 1 << 30);
    final cacheDir = await _cacheDirectory(videoPath);
    final frames = <TimelineFilmstripFrame>[];
    final capturedMs = <int>{};

    Future<void> addFrame(int mediaTimeMs) async {
      final lo = baseMs;
      final hi = baseMs + lastOffsetMs;
      final clampedMs = mediaTimeMs.clamp(lo, hi);
      if (!capturedMs.add(clampedMs)) return;

      try {
        final cacheFile = File(
          p.join(cacheDir.path, 'thumb_${clampedMs}ms.jpg'),
        );

        // Empty / corrupt leftovers from failed grabs must be regenerated.
        if (await cacheFile.exists() && await cacheFile.length() == 0) {
          await cacheFile.delete();
        }

        if (!await cacheFile.exists()) {
          // Prefer the platform thumbnailer; ffmpeg only as fallback.
          final generated = await const VideoFrameGrab().jpegFile(
            video: videoPath,
            thumbnailPath: cacheFile.path,
            timeMs: clampedMs,
            maxHeight: _thumbHeight,
            quality: 65,
          );
          if (generated != null &&
              p.normalize(generated) != p.normalize(cacheFile.path)) {
            await File(generated).copy(cacheFile.path);
          }
        }

        if (!await cacheFile.exists() || await cacheFile.length() == 0) {
          return;
        }

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
      } catch (error) {
        // One bad tile must not abort the whole strip.
        avEditorLog('filmstrip frame failed ms=$clampedMs: $error');
      }
    }

    for (var i = 0; i < frameCount; i++) {
      await addFrame(baseMs + stepMs * i);
    }
    await addFrame(baseMs + lastOffsetMs);

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

    // 1) Platform image pipeline (FileImage) — required for iPhone HEIC/HEIF.
    //    Raw instantiateImageCodec / min-gpl ffmpeg often cannot decode those.
    final platformImage = await _decodeStillViaFileImage(imagePath);
    if (platformImage != null) {
      avEditorLog('filmstrip image via FileImage $imagePath');
      return [
        TimelineFilmstripFrame(
          sourceTime: Duration.zero,
          image: platformImage,
          mediaId: mediaId,
        ),
      ];
    }

    // 2) JPEG/PNG/WebP bytes via dart:ui codec.
    try {
      final bytes = await File(imagePath).readAsBytes();
      if (bytes.isNotEmpty) {
        final codec = await ui.instantiateImageCodec(
          bytes,
          targetHeight: _thumbHeight,
        );
        final frame = await codec.getNextFrame();
        avEditorLog('filmstrip image via codec $imagePath');
        return [
          TimelineFilmstripFrame(
            sourceTime: Duration.zero,
            image: frame.image,
            mediaId: mediaId,
          ),
        ];
      }
    } catch (error) {
      avEditorLog('filmstrip image codec failed: $error');
    }

    // 3) ffmpeg → JPEG cache, then codec.
    final cacheDir = await _cacheDirectory(imagePath);
    final cacheFile = File(p.join(cacheDir.path, 'still.jpg'));
    if (await cacheFile.exists() && await cacheFile.length() == 0) {
      await cacheFile.delete();
    }
    if (!await cacheFile.exists()) {
      final ready = await _ffmpegImageJpeg(imagePath, cacheFile.path);
      if (!ready) {
        avEditorLog('filmstrip image all decoders failed $imagePath');
        return const [];
      }
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
      avEditorLog('filmstrip image jpeg-cache decode failed: $error');
      return const [];
    }
  }

  /// Uses the same OS decoder as [Image.file] (HEIC on iOS, etc.).
  Future<ui.Image?> _decodeStillViaFileImage(String imagePath) async {
    final completer = Completer<ui.Image?>();
    final provider = ResizeImage(
      FileImage(File(imagePath)),
      height: _thumbHeight,
      allowUpscaling: false,
    );
    late final ImageStreamListener listener;
    final stream = provider.resolve(ImageConfiguration.empty);
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) {
          completer.complete(info.image.clone());
        }
        stream.removeListener(listener);
      },
      onError: (error, stack) {
        avEditorLog('filmstrip FileImage failed: $error');
        if (!completer.isCompleted) completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        stream.removeListener(listener);
        avEditorLog('filmstrip FileImage timeout $imagePath');
        return null;
      },
    );
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
        '-vf',
        'scale=-2:$_thumbHeight',
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
