import 'dart:io';

import 'package:aveditor/models/export_preset.dart';
import 'package:aveditor/models/export_quality_profile.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/export_save_service.dart';
import 'package:aveditor/services/overlay_raster_service.dart';
import 'package:aveditor/services/video_probe_service.dart';
import 'package:aveditor/utils/clip_rotation.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/export_dimensions.dart';
import 'package:aveditor/utils/ffmpeg_text.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Exports trimmed video with 9:16 crop and burned-in text overlays via FFmpeg.
///
/// When the edit is trim-only, [ExportQualityProfile.allowsStreamCopy] profiles
/// copy the source streams without re-encoding — the same trick CapCut uses to
/// keep originals pristine.
class ExportService {
  const ExportService({
    this.rasterService = const OverlayRasterService(),
    this.probeService = const VideoProbeService(),
  });

  final OverlayRasterService rasterService;
  final VideoProbeService probeService;

  Future<String> exportForPreset(
    VideoProject project, {
    ExportPreset preset = ExportPreset.youtubeShorts,
    ExportQualityProfile quality = ExportQualityProfile.recommended,
    void Function(double progress)? onProgress,
  }) {
    return exportToFile(
      project.copyWith(preset: preset),
      quality: quality,
      onProgress: onProgress,
    );
  }

  Future<String> exportToFile(
    VideoProject project, {
    ExportQualityProfile quality = ExportQualityProfile.recommended,
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.05);

    final sourceFile = File(project.sourcePath);
    if (!await sourceFile.exists()) {
      throw StateError('Source video not found');
    }

    final sourceSize = await probeService.readFrameSize(project.sourcePath);
    final frame = computeExportFrameSize(
      sourceWidth: sourceSize.width,
      sourceHeight: sourceSize.height,
      maxWidth: project.preset.width,
      maxHeight: project.preset.height,
      allowUpscale: quality.allowUpscale,
    );

    final outputDir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final workDir = Directory(p.join(outputDir.path, 'aveditor_overlays_$stamp'));
    await workDir.create(recursive: true);

    final visibleOverlays = project.overlays
        .where((overlay) => overlay.text.trim().isNotEmpty)
        .toList(growable: false);
    final rasters = await rasterService.renderAll(
      visibleOverlays,
      width: frame.width,
      height: frame.height,
      outputDir: workDir,
    );
    onProgress?.call(0.15);

    final outputPath = p.join(outputDir.path, 'aveditor_export_$stamp.mp4');
    final singleSegment = project.segments.length == 1;
    final startSec = singleSegment
        ? formatFfmpegSeconds(project.segments.first.start)
        : '0';
    final durationSec = formatFfmpegSeconds(project.trimmedDuration);
    final musicPath = _musicPathForProject(project);
    final hasVideoAudio = musicPath == null
        ? true
        : await probeService.hasAudioStream(project.sourcePath);

    final streamCopy = canStreamCopy(
      project: project,
      rasters: rasters,
      quality: quality,
      musicPath: musicPath,
    );

    final command = streamCopy
        ? buildStreamCopyCommand(
            sourcePath: project.sourcePath,
            outputPath: outputPath,
            startSec: startSec,
            durationSec: durationSec,
          )
        : _buildEncodeCommand(
            project: project,
            rasters: rasters,
            quality: quality,
            frame: frame,
            outputPath: outputPath,
            startSec: startSec,
            durationSec: durationSec,
            musicPath: musicPath,
            hasVideoAudio: hasVideoAudio,
            singleSegment: singleSegment,
          );

    onProgress?.call(0.25);

    if (onProgress != null && !streamCopy) {
      FFmpegKitConfig.enableStatisticsCallback((statistics) {
        final time = statistics.getTime();
        if (time <= 0) return;
        final totalMs = project.trimmedDuration.inMilliseconds;
        if (totalMs <= 0) return;
        final ratio = (time / totalMs).clamp(0.0, 1.0);
        onProgress(0.25 + ratio * 0.65);
      });
    }

    final session = await FFmpegKit.execute(command);
    FFmpegKitConfig.enableStatisticsCallback(null);

    final returnCode = await session.getReturnCode();
    await workDir.delete(recursive: true).catchError((_) => workDir);

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      throw StateError(logs ?? 'FFmpeg export failed');
    }

    final exported = File(outputPath);
    if (!await exported.exists()) {
      throw StateError('Export file was not created');
    }
    if (await exported.length() < ExportSaveService.minExportBytes) {
      throw StateError('Export file is empty');
    }

    onProgress?.call(1.0);
    return outputPath;
  }

  static String? _musicPathForProject(VideoProject project) {
    final music = project.backgroundMusic;
    if (music == null) return null;
    final projectDir = p.dirname(project.sourcePath);
    return p.join(projectDir, music.fileName);
  }

  @visibleForTesting
  static bool canStreamCopy({
    required VideoProject project,
    required List<OverlayRaster> rasters,
    required ExportQualityProfile quality,
    String? musicPath,
  }) {
    if (!quality.allowsStreamCopy) return false;
    if (project.rotation != 0) return false;
    if (rasters.isNotEmpty) return false;
    if (musicPath != null) return false;
    if (project.segments.length != 1) return false;
    return true;
  }

  static String buildStreamCopyCommand({
    required String sourcePath,
    required String outputPath,
    required String startSec,
    required String durationSec,
  }) {
    return [
      '-y',
      '-ss',
      startSec,
      '-i',
      quoteShell(sourcePath),
      '-t',
      durationSec,
      '-c',
      'copy',
      '-movflags',
      '+faststart',
      quoteShell(outputPath),
    ].join(' ');
  }

  String _buildEncodeCommand({
    required VideoProject project,
    required List<OverlayRaster> rasters,
    required ExportQualityProfile quality,
    required ExportFrameSize frame,
    required String outputPath,
    required String startSec,
    required String durationSec,
    String? musicPath,
    bool hasVideoAudio = true,
    bool singleSegment = true,
  }) {
    final graph = buildFilterGraph(
      project: project,
      rasters: rasters,
      frame: frame,
    );
    final crf = quality.crf ?? quality.fallbackCrf;
    final music = project.backgroundMusic;
    final hasConcat = project.segments.length > 1;
    final exportDurationSec =
        project.trimmedDuration.inMilliseconds / 1000.0;
    final audioGraph = music != null && musicPath != null
        ? buildAudioMixGraph(
            music: music,
            trimStart: project.trim.start,
            exportDurationSec: exportDurationSec,
            videoAudioStream: hasConcat ? '[acat]' : '[0:a]',
            musicInput: 1 + rasters.length,
            hasVideoAudio: hasVideoAudio,
          )
        : null;
    final audioMap = hasConcat ? '[acat]' : '0:a?';

    return [
      '-y',
      if (singleSegment) ...['-ss', startSec],
      '-i',
      quoteShell(project.sourcePath),
      for (final raster in rasters) ...['-i', quoteShell(raster.file.path)],
      if (musicPath != null) ...['-i', quoteShell(musicPath)],
      if (audioGraph != null && graph.description.isNotEmpty) ...[
        '-filter_complex',
        quoteShell('${graph.description};${audioGraph.description}'),
        '-map',
        quoteShell('[${graph.outputLabel}]'),
        '-map',
        quoteShell('[${audioGraph.outputLabel}]'),
      ] else if (audioGraph != null) ...[
        '-filter_complex',
        quoteShell(audioGraph.description),
        '-map',
        '0:v:0',
        '-map',
        quoteShell('[${audioGraph.outputLabel}]'),
      ] else if (graph.description.isNotEmpty) ...[
        '-filter_complex',
        quoteShell(graph.description),
        '-map',
        quoteShell('[${graph.outputLabel}]'),
        '-map',
        quoteShell(audioMap),
      ] else ...[
        '-map',
        '0:v:0',
        '-map',
        '0:a?',
      ],
      '-t',
      durationSec,
      '-c:v',
      'libx264',
      '-preset',
      quality.encodePreset,
      '-crf',
      crf,
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
  }

  /// Mixes background music with the trimmed clip audio.
  @visibleForTesting
  static FilterGraph buildAudioMixGraph({
    required ProjectMusic music,
    required Duration trimStart,
    required double exportDurationSec,
    required String videoAudioStream,
    required int musicInput,
    bool hasVideoAudio = true,
  }) {
    final delaySec = ((music.timelineStart - trimStart).inMilliseconds / 1000.0)
        .clamp(0.0, exportDurationSec);
    final sourceOffsetSec = music.sourceOffset.inMilliseconds / 1000.0;
    final volume = music.volume.clamp(0.0, 1.0).toStringAsFixed(3);

    final musicChain = StringBuffer(
      '[$musicInput:a]atrim=start=$sourceOffsetSec:duration=$exportDurationSec,'
      'asetpts=PTS-STARTPTS',
    );
    if (delaySec > 0) {
      musicChain.write(
        ',adelay=${(delaySec * 1000).round()}|${(delaySec * 1000).round()}',
      );
    }
    musicChain.write(',volume=$volume[music]');

    final description = hasVideoAudio
        ? '$videoAudioStream aformat=sample_rates=44100:channel_layouts=stereo,volume=1[va];'
            '${musicChain.toString()};'
            '[va][music]amix=inputs=2:duration=first:dropout_transition=2[aout]'
        : musicChain.toString().replaceAll('[music]', '[aout]');

    return FilterGraph(description: description, outputLabel: 'aout');
  }

  /// Visible spans of [overlay] on the concatenated export timeline.
  @visibleForTesting
  static List<({double start, double end})> visibleSpans(
    TextOverlay overlay, {
    required List<ClipSegment> segments,
  }) {
    return overlayExportSpans(overlay, segments);
  }

  @visibleForTesting
  static String buildOverlayEnableExpression(
    List<({double start, double end})> spans,
  ) {
    if (spans.isEmpty) return '';
    if (spans.length == 1) {
      final span = spans.single;
      return "enable='between(t\\,${span.start.toStringAsFixed(3)}"
          "\\,${span.end.toStringAsFixed(3)})'";
    }
    final parts = spans
        .map(
          (span) =>
              'between(t\\,${span.start.toStringAsFixed(3)}'
              '\\,${span.end.toStringAsFixed(3)})',
        )
        .join('+');
    return "enable='$parts'";
  }

  @visibleForTesting
  static String? buildSegmentConcatGraph(List<ClipSegment> segments) {
    if (segments.length <= 1) return null;

    final parts = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final start = segment.start.inMilliseconds / 1000.0;
      final end = segment.end.inMilliseconds / 1000.0;
      parts.add(
        '[0:v]trim=start=$start:end=$end,setpts=PTS-STARTPTS[v$i]',
      );
      parts.add(
        '[0:a]atrim=start=$start:end=$end,asetpts=PTS-STARTPTS[a$i]',
      );
    }

    final labels = StringBuffer();
    for (var i = 0; i < segments.length; i++) {
      labels.write('[v$i][a$i]');
    }
    parts.add(
      '${labels}concat=n=${segments.length}:v=1:a=1[vcat][acat]',
    );
    return parts.join(';');
  }

  /// Builds the crop-and-composite graph.
  @visibleForTesting
  FilterGraph buildFilterGraph({
    required VideoProject project,
    required List<OverlayRaster> rasters,
    required ExportFrameSize frame,
  }) {
    final width = frame.width;
    final height = frame.height;
    final steps = <String>[];

    final concat = buildSegmentConcatGraph(project.segments);
    var videoIn = '0:v';
    if (concat != null) {
      steps.add(concat);
      videoIn = 'vcat';
    }

    final placement = StringBuffer(
      '[$videoIn]scale=${frame.scaleWidth}:${frame.scaleHeight}:'
      'flags=$kExportScaleFlags,'
      'crop=$width:$height',
    );
    final rotation = normalizeClipRotation(project.rotation);
    if (rotation != 0) {
      placement.write(
        ',rotate=${rotation.toStringAsFixed(6)}:'
        'ow=$width:oh=$height:c=black',
      );
    }
    placement.write('[base]');
    steps.add(placement.toString());

    var label = 'base';
    var input = 1;
    for (final raster in rasters) {
      final spans = visibleSpans(
        raster.overlay,
        segments: project.segments,
      );
      if (spans.isEmpty) {
        input++;
        continue;
      }

      final next = 'v$input';
      steps.add(
        '[$label][$input:v]overlay=0:0:format=auto:repeatlast=1:'
        '${buildOverlayEnableExpression(spans)}[$next]',
      );
      label = next;
      input++;
    }

    return FilterGraph(description: steps.join(';'), outputLabel: label);
  }
}

/// A `-filter_complex` graph plus the label carrying its result.
@immutable
class FilterGraph {
  const FilterGraph({required this.description, required this.outputLabel});

  final String description;
  final String outputLabel;
}
