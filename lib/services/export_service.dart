import 'dart:io';

import 'package:aveditor/models/export_preset.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/utils/ffmpeg_text.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Exports trimmed video with 9:16 crop and burned-in text overlays via FFmpeg.
class ExportService {
  static const _fontAssetPath = 'assets/fonts/Arial.ttf';
  static const _fontFileName = 'Arial.ttf';

  String? _cachedFontPath;

  Future<String> exportForPreset(
    VideoProject project, {
    ExportPreset preset = ExportPreset.youtubeShorts,
    void Function(double progress)? onProgress,
  }) {
    return exportToFile(
      project.copyWith(preset: preset),
      onProgress: onProgress,
    );
  }

  Future<String> exportToFile(
    VideoProject project, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.05);

    final sourceFile = File(project.sourcePath);
    if (!await sourceFile.exists()) {
      throw StateError('Source video not found');
    }

    final fontPath = await _ensureFontFile();
    onProgress?.call(0.15);

    final outputDir = await getTemporaryDirectory();
    final outputPath = p.join(
      outputDir.path,
      'aveditor_export_${DateTime.now().millisecondsSinceEpoch}.mp4',
    );

    final filter = _buildVideoFilter(project, fontPath);
    final startSec = formatFfmpegSeconds(project.trim.start);
    final durationSec = formatFfmpegSeconds(project.trim.duration);

    final command = [
      '-y',
      '-ss',
      startSec,
      '-i',
      quoteShell(project.sourcePath),
      '-t',
      durationSec,
      '-vf',
      quoteShell(filter),
      '-c:v',
      'libx264',
      '-preset',
      'fast',
      '-crf',
      '23',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      '-movflags',
      '+faststart',
      quoteShell(outputPath),
    ].join(' ');

    onProgress?.call(0.25);

    if (onProgress != null) {
      FFmpegKitConfig.enableStatisticsCallback((statistics) {
        final time = statistics.getTime();
        if (time <= 0) return;
        final totalMs = project.trim.duration.inMilliseconds;
        if (totalMs <= 0) return;
        final ratio = (time / totalMs).clamp(0.0, 1.0);
        onProgress(0.25 + ratio * 0.65);
      });
    }

    final session = await FFmpegKit.execute(command);
    FFmpegKitConfig.enableStatisticsCallback(null);

    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      throw StateError(logs ?? 'FFmpeg export failed');
    }

    final exported = File(outputPath);
    if (!await exported.exists()) {
      throw StateError('Export file was not created');
    }

    onProgress?.call(1.0);
    return outputPath;
  }

  Future<String> _ensureFontFile() async {
    if (_cachedFontPath != null) {
      final cached = File(_cachedFontPath!);
      if (await cached.exists()) {
        await _registerFontDirectory(cached.parent.path);
        return _cachedFontPath!;
      }
    }

    final supportDir = await getApplicationSupportDirectory();
    final fontsDir = Directory(p.join(supportDir.path, 'fonts'));
    if (!await fontsDir.exists()) {
      await fontsDir.create(recursive: true);
    }

    final fontFile = File(p.join(fontsDir.path, _fontFileName));
    if (!await fontFile.exists()) {
      final data = await rootBundle.load(_fontAssetPath);
      await fontFile.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }

    await _registerFontDirectory(fontsDir.path);
    _cachedFontPath = fontFile.path;
    return fontFile.path;
  }

  Future<void> _registerFontDirectory(String directoryPath) async {
    await FFmpegKitConfig.setFontDirectory(
      directoryPath,
      {_fontFileName: 'Regular'},
    );
  }

  String _buildVideoFilter(VideoProject project, String fontPath) {
    final preset = project.preset;
    final width = preset.width;
    final height = preset.height;
    final trimStartSec = project.trim.start.inMilliseconds / 1000.0;
    final trimDurationSec = project.trim.duration.inMilliseconds / 1000.0;
    final fontEscaped = escapeFfmpegPath(fontPath);

    final filters = <String>[
      'scale=$width:$height:force_original_aspect_ratio=increase',
      'crop=$width:$height',
    ];

    for (final overlay in project.overlays) {
      final drawtext = _drawtextFilter(
        overlay: overlay,
        fontEscaped: fontEscaped,
        trimStartSec: trimStartSec,
        trimDurationSec: trimDurationSec,
        width: width,
        height: height,
      );
      if (drawtext != null) {
        filters.add(drawtext);
      }
    }

    return filters.join(',');
  }

  String? _drawtextFilter({
    required TextOverlay overlay,
    required String fontEscaped,
    required double trimStartSec,
    required double trimDurationSec,
    required int width,
    required int height,
  }) {
    final start = overlay.start.inMilliseconds / 1000.0 - trimStartSec;
    final end = overlay.end.inMilliseconds / 1000.0 - trimStartSec;

    if (end <= 0 || start >= trimDurationSec) {
      return null;
    }

    final startClamped = start.clamp(0.0, trimDurationSec);
    final endClamped = end.clamp(0.0, trimDurationSec);
    if (endClamped <= startClamped) {
      return null;
    }

    final offsetX = overlay.offset.dx * (width / 2);
    final offsetY = overlay.offset.dy * (height / 2);
    final text = escapeDrawText(overlay.text);
    final color = colorToFfmpeg(overlay.color);
    final fontSize = overlay.fontSize.round();

    return "drawtext=fontfile='$fontEscaped':text='$text':fontsize=$fontSize:"
        'fontcolor=$color:'
        'x=(w-text_w)/2+${offsetX.toStringAsFixed(1)}:'
        'y=(h-text_h)/2+${offsetY.toStringAsFixed(1)}:'
        "enable='between(t\\,${startClamped.toStringAsFixed(3)}\\,${endClamped.toStringAsFixed(3)})'";
  }
}
