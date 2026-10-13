import 'dart:io';
import 'dart:typed_data';

import 'package:aveditor/services/playback_fallback_transcoder.dart';
import 'package:aveditor/utils/av_editor_log.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// Still frames for the filmstrip, thumbnail editor, and export card.
///
/// Android HEVC and ProRes stay on ffmpeg. MediaMetadataRetriever returns a
/// null frame for those files and the thumbnail plugin reports that as a
/// missing method.
class VideoFrameGrab {
  const VideoFrameGrab();

  static final _ffmpegByPath = <String, bool>{};

  Future<String?> jpegFile({
    required String video,
    String? thumbnailPath,
    int maxHeight = 0,
    int maxWidth = 0,
    int timeMs = 0,
    int quality = 75,
  }) async {
    if (await _usesFfmpeg(video)) {
      return _ffmpegJpeg(
        video: video,
        thumbnailPath: thumbnailPath,
        maxHeight: maxHeight,
        maxWidth: maxWidth,
        timeMs: timeMs,
        quality: quality,
      );
    }

    try {
      final generated = await VideoThumbnail.thumbnailFile(
        video: video,
        thumbnailPath: thumbnailPath,
        imageFormat: ImageFormat.JPEG,
        maxHeight: maxHeight,
        maxWidth: maxWidth,
        timeMs: timeMs,
        quality: quality,
      );
      if (generated != null && await File(generated).exists()) return generated;
    } catch (error) {
      avEditorLog('thumbnail platform failed: $error');
    }

    _ffmpegByPath[video] = true;
    return _ffmpegJpeg(
      video: video,
      thumbnailPath: thumbnailPath,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      timeMs: timeMs,
      quality: quality,
    );
  }

  Future<Uint8List?> jpegBytes({
    required String video,
    int maxHeight = 0,
    int maxWidth = 0,
    int timeMs = 0,
    int quality = 75,
  }) async {
    if (!await _usesFfmpeg(video)) {
      try {
        final bytes = await VideoThumbnail.thumbnailData(
          video: video,
          imageFormat: ImageFormat.JPEG,
          maxHeight: maxHeight,
          maxWidth: maxWidth,
          timeMs: timeMs,
          quality: quality,
        );
        if (bytes != null && bytes.isNotEmpty) return bytes;
      } catch (error) {
        avEditorLog('thumbnail platform failed: $error');
      }
      _ffmpegByPath[video] = true;
    }

    final path = await _ffmpegJpeg(
      video: video,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      timeMs: timeMs,
      quality: quality,
    );
    if (path == null) return null;
    final bytes = await File(path).readAsBytes();
    return bytes.isEmpty ? null : bytes;
  }

  Future<bool> _usesFfmpeg(String video) async {
    final cached = _ffmpegByPath[video];
    if (cached != null) return cached;
    final codec = await const PlaybackFallbackTranscoder().videoCodec(video);
    final use = PlaybackFallbackTranscoder.needsFfmpegPlayer(codec);
    _ffmpegByPath[video] = use;
    if (use) avEditorLog('thumbnail: ffmpeg codec=$codec');
    return use;
  }

  Future<String?> _ffmpegJpeg({
    required String video,
    String? thumbnailPath,
    required int maxHeight,
    required int maxWidth,
    required int timeMs,
    required int quality,
  }) async {
    final output = thumbnailPath ??
        p.join(
          (await getTemporaryDirectory()).path,
          'aveditor_thumb_${video.hashCode}_$timeMs.jpg',
        );
    final parent = Directory(p.dirname(output));
    if (!await parent.exists()) await parent.create(recursive: true);

    final written = await _encodeJpeg(
      video: video,
      output: output,
      timeMs: timeMs,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      quality: quality,
    );
    if (written) return output;
    // A seek on the last millisecond lands past the final frame and ffmpeg
    // still exits 0 with no image. Pull back and take the frame that exists.
    if (timeMs > 0) {
      final pulled = timeMs > 400 ? timeMs - 400 : 0;
      final retry = await _encodeJpeg(
        video: video,
        output: output,
        timeMs: pulled,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        quality: quality,
      );
      if (retry) return output;
    }
    return null;
  }

  Future<bool> _encodeJpeg({
    required String video,
    required String output,
    required int timeMs,
    required int maxWidth,
    required int maxHeight,
    required int quality,
  }) async {
    final arguments = <String>[
      '-y',
      '-ss',
      (timeMs / 1000).toStringAsFixed(3),
      '-i',
      video,
      '-frames:v',
      '1',
      '-update',
      '1',
      '-q:v',
      '${_qscale(quality)}',
    ];
    final scale = _scale(maxWidth, maxHeight);
    if (scale != null) arguments.addAll(['-vf', scale]);
    arguments.add(output);

    final session = await FFmpegKit.executeWithArguments(arguments);
    final code = await session.getReturnCode();
    final file = File(output);
    if (ReturnCode.isSuccess(code) &&
        await file.exists() &&
        await file.length() > 0) {
      return true;
    }
    if (await file.exists()) await file.delete();
    final text = await session.getOutput() ?? '';
    final tail = text.length > 400 ? text.substring(text.length - 400) : text;
    avEditorLog(
      'thumbnail ffmpeg failed timeMs=$timeMs code=${code?.getValue()} $tail',
    );
    return false;
  }

  String? _scale(int maxWidth, int maxHeight) {
    if (maxWidth > 0 && maxHeight > 0) {
      return 'scale=$maxWidth:$maxHeight:force_original_aspect_ratio=decrease';
    }
    if (maxHeight > 0) return 'scale=-2:$maxHeight';
    if (maxWidth > 0) return 'scale=$maxWidth:-2';
    return null;
  }

  int _qscale(int quality) {
    final q = quality.clamp(1, 100);
    return (31 - ((q - 1) * 29 / 99)).round().clamp(2, 31);
  }
}
