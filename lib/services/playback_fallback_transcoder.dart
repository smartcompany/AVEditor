import 'dart:io';

import 'package:aveditor/utils/av_editor_log.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:path/path.dart' as p;

/// Decides which Android player opens a file, from its video codec.
///
/// HEVC and ProRes stay as the original file and are played by ffmpeg.
/// Other codecs stay on ExoPlayer. [transcode] is not used on load.
class PlaybackFallbackTranscoder {
  const PlaybackFallbackTranscoder({this.run});

  /// Test hook. The last argument is the output path the command writes.
  final Future<bool> Function(List<String> arguments)? run;

  static const outputFileName = 'source.mp4';

  /// Codecs ExoPlayer does not play on Android. H.264 is not in this set.
  static const directTranscodeCodecs = {'hevc', 'h265', 'prores'};

  static bool needsFfmpegPlayer(String? codec, {bool? android}) {
    return needsDirectTranscode(codec, android: android);
  }

  static bool needsDirectTranscode(String? codec, {bool? android}) {
    final onAndroid = android ?? Platform.isAndroid;
    if (!onAndroid || codec == null || codec.isEmpty) return false;
    return directTranscodeCodecs.contains(codec.toLowerCase());
  }

  /// Video codec name from the file header. Null when the probe cannot read one.
  Future<String?> videoCodec(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) return null;
      for (final stream in info.getStreams()) {
        if (stream.getType() == 'video') return stream.getCodec();
      }
    } catch (error) {
      avEditorLog('probe failed: $error');
    }
    return null;
  }

  static List<String> arguments(String inputPath, String outputPath) {
    return [
      '-y',
      '-i',
      inputPath,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-preset',
      'veryfast',
      '-crf',
      '20',
      '-vf',
      'scale=trunc(iw/2)*2:trunc(ih/2)*2',
      '-c:a',
      'aac',
      '-b:a',
      '160k',
      '-movflags',
      '+faststart',
      outputPath,
    ];
  }

  /// Replaces [sourcePath] with an H.264 MP4 in the same directory.
  Future<String> transcode(String sourcePath) async {
    final directory = p.dirname(sourcePath);
    final outputPath = p.join(directory, outputFileName);
    final tempPath = p.join(directory, '.source.transcode.mp4');
    final succeeded = await (run ?? _runFfmpeg)(arguments(sourcePath, tempPath));
    final temp = File(tempPath);
    if (!succeeded || !await temp.exists() || await temp.length() == 0) {
      if (await temp.exists()) {
        await temp.delete();
      }
      throw StateError('playback fallback transcode failed');
    }

    final output = File(outputPath);
    final replacingOriginal = p.normalize(sourcePath) == p.normalize(outputPath);
    File? backup;
    if (replacingOriginal) {
      backup = File('$sourcePath.playback-bak');
      if (await backup.exists()) {
        await backup.delete();
      }
      await File(sourcePath).rename(backup.path);
    } else if (await output.exists()) {
      await output.delete();
    }

    try {
      await temp.rename(outputPath);
    } catch (error) {
      if (backup != null && await backup.exists() && !await output.exists()) {
        await backup.rename(sourcePath);
      }
      rethrow;
    }

    if (backup != null && await backup.exists()) {
      await backup.delete();
    }
    if (!replacingOriginal) {
      final original = File(sourcePath);
      if (await original.exists()) {
        await original.delete();
      }
    }
    return outputPath;
  }

  Future<bool> _runFfmpeg(List<String> arguments) async {
    avEditorLog('ffmpeg exec ${arguments.join(' ')}');
    final session = await FFmpegKit.executeWithArguments(arguments);
    final code = await session.getReturnCode();
    if (ReturnCode.isSuccess(code)) {
      avEditorLog('ffmpeg ok');
      return true;
    }
    final output = await session.getOutput();
    final text = output ?? '';
    final tail = text.length > 800 ? text.substring(text.length - 800) : text;
    avEditorLog('ffmpeg failed code=${code?.getValue()} $tail');
    return false;
  }
}
