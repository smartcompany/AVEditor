import 'dart:async';
import 'dart:io';

import 'package:aveditor/utils/av_editor_log.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:path/path.dart' as p;

/// Default on-timeline length for a still image imported as a clip.
const Duration kDefaultImageClipDuration = Duration(seconds: 3);

/// How long the still is baked into the source so the right trim handle can
/// extend past the default without showing the next clip's frames.
const Duration kMaxImageClipDuration = Duration(seconds: 60);

/// Builds one H.264 source from ordered video/image paths and cut boundaries.
class MediaConcatService {
  const MediaConcatService({this.run});

  /// Test hook. The last argument is the output path the command writes.
  final Future<bool> Function(List<String> arguments)? run;

  static const imageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.heic',
    '.heif',
    '.gif',
    '.bmp',
  };

  static const videoExtensions = {
    '.mp4',
    '.mov',
    '.m4v',
    '.webm',
    '.mkv',
  };

  static bool isImagePath(String path) {
    return imageExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isVideoPath(String path) {
    return videoExtensions.contains(p.extension(path).toLowerCase());
  }

  /// Prepares each asset, concatenates in order, returns output + piece lengths.
  Future<({String outputPath, List<Duration> pieceDurations})> buildSource({
    required List<String> inputPaths,
    required String workDir,
    void Function(double progress)? onProgress,
  }) async {
    if (inputPaths.isEmpty) {
      throw StateError('empty_video');
    }
    await Directory(workDir).create(recursive: true);

    final size = await _resolveOutputSize(inputPaths);
    final pieces = <String>[];
    final durations = <Duration>[];
    final totalSteps = inputPaths.length + 1;

    for (var i = 0; i < inputPaths.length; i++) {
      onProgress?.call(i / totalSteps);
      final input = inputPaths[i];
      final piecePath = p.join(workDir, 'piece_$i.mp4');
      final duration = isImagePath(input)
          ? await _imageToClip(
              input,
              piecePath,
              width: size.$1,
              height: size.$2,
            )
          : await _normalizeVideo(
              input,
              piecePath,
              width: size.$1,
              height: size.$2,
            );
      pieces.add(piecePath);
      durations.add(duration);
    }

    onProgress?.call(inputPaths.length / totalSteps);
    final outputPath = p.join(workDir, 'source.mp4');
    await _concat(pieces, outputPath);
    onProgress?.call(1);
    return (outputPath: outputPath, pieceDurations: durations);
  }

  Future<(int, int)> _resolveOutputSize(List<String> paths) async {
    for (final path in paths) {
      if (isImagePath(path)) continue;
      final probed = await _probeVideoSize(path);
      if (probed != null) return probed;
    }
    return (1080, 1920);
  }

  Future<(int, int)?> _probeVideoSize(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) return null;
      for (final stream in info.getStreams()) {
        if (stream.getType() != 'video') continue;
        final width = stream.getWidth();
        final height = stream.getHeight();
        if (width == null || height == null || width <= 0 || height <= 0) {
          continue;
        }
        return (_even(width), _even(height));
      }
    } catch (error) {
      avEditorLog('concat probe size failed: $error');
    }
    return null;
  }

  Future<Duration> _imageToClip(
    String input,
    String output, {
    required int width,
    required int height,
  }) async {
    // Encode the full extendable window; import only keeps the first
    // [kDefaultImageClipDuration] on the timeline until the user drags.
    final seconds = kMaxImageClipDuration.inMilliseconds / 1000.0;
    final ok = await _execute([
      '-y',
      '-loop',
      '1',
      '-t',
      '$seconds',
      '-i',
      input,
      '-f',
      'lavfi',
      '-t',
      '$seconds',
      '-i',
      'anullsrc=channel_layout=stereo:sample_rate=44100',
      '-vf',
      _fitFilter(width, height),
      '-r',
      '30',
      '-c:v',
      'libx264',
      '-tune',
      'stillimage',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      '-shortest',
      '-movflags',
      '+faststart',
      output,
    ]);
    if (!ok) throw StateError('image_clip_failed');
    final probed = await _probeDurationMs(output);
    if (probed != null && probed > 0) {
      return Duration(milliseconds: probed);
    }
    return kMaxImageClipDuration;
  }

  Future<Duration> _normalizeVideo(
    String input,
    String output, {
    required int width,
    required int height,
  }) async {
    final probedMs = await _probeDurationMs(input);
    final vf = '${_fitFilter(width, height)},fps=30,format=yuv420p';
    // Prefer keeping the source audio track when present.
    var ok = await _execute([
      '-y',
      '-i',
      input,
      '-vf',
      vf,
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '20',
      '-c:a',
      'aac',
      '-ar',
      '44100',
      '-ac',
      '2',
      '-b:a',
      '160k',
      '-movflags',
      '+faststart',
      output,
    ]);
    if (!ok) {
      // Silent audio so concat pieces all have an AAC track.
      ok = await _execute([
        '-y',
        '-i',
        input,
        '-f',
        'lavfi',
        '-i',
        'anullsrc=channel_layout=stereo:sample_rate=44100',
        '-vf',
        vf,
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-crf',
        '20',
        '-c:a',
        'aac',
        '-b:a',
        '160k',
        '-shortest',
        '-movflags',
        '+faststart',
        output,
      ]);
    }
    if (!ok) throw StateError('video_normalize_failed');
    final outMs = await _probeDurationMs(output) ?? probedMs;
    if (outMs == null || outMs <= 0) {
      throw StateError('empty_video');
    }
    return Duration(milliseconds: outMs);
  }

  Future<void> _concat(List<String> pieces, String outputPath) async {
    if (pieces.length == 1) {
      await File(pieces.first).copy(outputPath);
      return;
    }
    final listPath = p.join(p.dirname(outputPath), 'concat.txt');
    final body = pieces
        .map((path) => "file '${path.replaceAll("'", r"'\''")}'")
        .join('\n');
    await File(listPath).writeAsString(body);
    // Re-encode so PTS is continuous — `-c copy` breaks thumbnail seeks on
    // platform generators (AVAssetImageGenerator / MediaMetadataRetriever).
    final ok = await _execute([
      '-y',
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      listPath,
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '20',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-ar',
      '44100',
      '-ac',
      '2',
      '-b:a',
      '160k',
      '-movflags',
      '+faststart',
      outputPath,
    ]);
    if (!ok) throw StateError('concat_failed');
  }

  String _fitFilter(int width, int height) {
    return 'scale=$width:$height:force_original_aspect_ratio=decrease,'
        'pad=$width:$height:(ow-iw)/2:(oh-ih)/2,setsar=1';
  }

  int _even(int value) => value.isEven ? value : value - 1;

  Future<int?> _probeDurationMs(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) return null;
      final seconds = double.tryParse(info.getDuration() ?? '');
      if (seconds == null || seconds <= 0) return null;
      return (seconds * 1000).round();
    } catch (error) {
      avEditorLog('concat probe duration failed: $error');
      return null;
    }
  }

  Future<bool> _execute(List<String> arguments) async {
    final hook = run;
    if (hook != null) return hook(arguments);
    avEditorLog('ffmpeg concat ${arguments.join(' ')}');
    final done = Completer<FFmpegSession>();
    await FFmpegKit.executeWithArgumentsAsync(arguments, (session) {
      if (!done.isCompleted) done.complete(session);
    });
    final session = await done.future;
    final code = await session.getReturnCode();
    if (ReturnCode.isSuccess(code)) return true;
    final output = await session.getOutput();
    final text = output ?? '';
    final tail = text.length > 800 ? text.substring(text.length - 800) : text;
    avEditorLog('ffmpeg concat failed code=${code?.getValue()} $tail');
    return false;
  }
}
