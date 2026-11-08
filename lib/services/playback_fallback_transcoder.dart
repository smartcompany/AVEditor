import 'dart:async';
import 'dart:io';

import 'package:aveditor/utils/av_editor_log.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:path/path.dart' as p;

/// Turns a file the Android player cannot decode into a local H.264 SDR MP4.
///
/// HEVC, ProRes, and HDR transfers are replaced on import. Playback and
/// transitions then open that file with ExoPlayer.
class PlaybackFallbackTranscoder {
  const PlaybackFallbackTranscoder({this.run, this.shouldTranscode});

  /// Test hook. The last argument is the output path the command writes.
  final Future<bool> Function(List<String> arguments)? run;

  /// Test hook. When set, skips the file probe.
  final Future<bool> Function(String path)? shouldTranscode;

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

  /// HLG and PQ still take the HDR compositor even after the codec is H.264.
  static bool needsSdrConversion(String? colorTransfer, {bool? android}) {
    final onAndroid = android ?? Platform.isAndroid;
    if (!onAndroid || colorTransfer == null || colorTransfer.isEmpty) {
      return false;
    }
    final transfer = colorTransfer.toLowerCase();
    return transfer == 'arib-std-b67' || transfer == 'smpte2084';
  }

  /// True when the stored project file must be replaced with H.264 SDR.
  static bool needsStoredTranscode(
    String? codec,
    String? colorTransfer, {
    bool? android,
  }) {
    return needsDirectTranscode(codec, android: android) ||
        needsSdrConversion(colorTransfer, android: android);
  }

  Future<bool> shouldReplace(String path) async {
    final hook = shouldTranscode;
    if (hook != null) return hook(path);
    final codec = await videoCodec(path);
    final transfer = await colorTransfer(path);
    return needsStoredTranscode(codec, transfer);
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

  /// ffprobe `color_transfer`. Null when the header has none.
  Future<String?> colorTransfer(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) return null;
      for (final stream in info.getStreams()) {
        if (stream.getType() != 'video') continue;
        return stream.getStringProperty('color_transfer');
      }
    } catch (error) {
      avEditorLog('probe failed: $error');
    }
    return null;
  }

  /// This ffmpeg build's colorspace filter rejects HLG and PQ. Output tags
  /// still mark the file bt709 so playback and export stay on Media3.
  static String videoFilter(String? colorTransfer) {
    return 'scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p';
  }

  static List<String> arguments(
    String inputPath,
    String outputPath, {
    String? colorTransfer,
  }) {
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
      videoFilter(colorTransfer),
      '-color_primaries',
      'bt709',
      '-color_trc',
      'bt709',
      '-colorspace',
      'bt709',
      '-color_range',
      'tv',
      '-x264-params',
      'colorprim=bt709:transfer=bt709:colormatrix=bt709',
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
  ///
  /// [onProgress] receives 0 when encoding starts and 1 when the file is written.
  Future<String> transcode(
    String sourcePath, {
    void Function(double progress)? onProgress,
  }) async {
    final directory = p.dirname(sourcePath);
    final outputPath = p.join(directory, outputFileName);
    final tempPath = p.join(directory, '.source.transcode.mp4');
    final probed = run == null ? await _probe(sourcePath) : null;
    onProgress?.call(0);
    final succeeded = await (run ??
        (arguments) => _runFfmpeg(
              arguments,
              onProgress: onProgress,
              durationMs: probed?.durationMs,
            ))(
      arguments(sourcePath, tempPath, colorTransfer: probed?.colorTransfer),
    );
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

  Future<({String? colorTransfer, int? durationMs})?> _probe(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) return null;
      String? transfer;
      for (final stream in info.getStreams()) {
        if (stream.getType() != 'video') continue;
        transfer = stream.getStringProperty('color_transfer');
        break;
      }
      final seconds = double.tryParse(info.getDuration() ?? '');
      final durationMs = seconds == null || seconds <= 0
          ? null
          : (seconds * 1000).round();
      return (colorTransfer: transfer, durationMs: durationMs);
    } catch (error) {
      avEditorLog('probe failed: $error');
      return null;
    }
  }

  Future<bool> _runFfmpeg(
    List<String> arguments, {
    void Function(double progress)? onProgress,
    required int? durationMs,
  }) async {
    avEditorLog('ffmpeg exec ${arguments.join(' ')}');
    final done = Completer<FFmpegSession>();
    final total = durationMs ?? 0;
    await FFmpegKit.executeWithArgumentsAsync(
      arguments,
      (session) {
        if (!done.isCompleted) done.complete(session);
      },
      null,
      (statistics) {
        if (onProgress == null || total <= 0) return;
        final fraction = statistics.getTime() / total;
        if (fraction.isNaN) return;
        onProgress(fraction.clamp(0.0, 0.99));
      },
    );
    final session = await done.future;
    final code = await session.getReturnCode();
    if (ReturnCode.isSuccess(code)) {
      onProgress?.call(1);
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
