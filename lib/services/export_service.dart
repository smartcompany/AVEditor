import 'dart:io';

import 'package:aveditor/models/audio_envelope.dart';
import 'package:aveditor/models/export_preset.dart';
import 'package:aveditor/models/export_quality_profile.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/services/export_save_service.dart';
import 'package:aveditor/services/native_video_engine.dart';
import 'package:aveditor/services/overlay_raster_service.dart';
import 'package:aveditor/services/transition_engine.dart';
import 'package:aveditor/services/video_probe_service.dart';
import 'package:aveditor/utils/clip_rotation.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/export_dimensions.dart';
import 'package:aveditor/utils/ffmpeg_text.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Exports trimmed video with 9:16 crop and burned-in text overlays via the
/// native OS encoder (VideoToolbox / MediaCodec).
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

    final request = _buildNativeExportRequest(
      project: project,
      rasters: rasters,
      quality: quality,
      frame: frame,
      outputPath: outputPath,
      musicPath: musicPath,
      hasVideoAudio: hasVideoAudio,
      streamCopy: streamCopy,
    );

    onProgress?.call(0.25);

    try {
      final exportedPath = await NativeVideoEngine.instance.export(
        request: request,
        onProgress: (p) => onProgress?.call(0.25 + p.clamp(0.0, 1.0) * 0.7),
      );

      final exported = File(exportedPath);
      if (!await exported.exists()) {
        throw StateError('Export file was not created');
      }
      if (await exported.length() < ExportSaveService.minExportBytes) {
        throw StateError('Export file is empty');
      }

      onProgress?.call(1.0);
      return exportedPath;
    } finally {
      await workDir.delete(recursive: true).catchError((_) => workDir);
    }
  }

  Map<String, dynamic> _buildNativeExportRequest({
    required VideoProject project,
    required List<OverlayRaster> rasters,
    required ExportQualityProfile quality,
    required ExportFrameSize frame,
    required String outputPath,
    required String? musicPath,
    required bool hasVideoAudio,
    required bool streamCopy,
  }) {
    final segments = <Map<String, dynamic>>[];
    for (var i = 0; i < project.segments.length; i++) {
      final segment = project.segments[i];
      final next = i < project.segments.length - 1
          ? project.segments[i + 1]
          : null;
      final td = next == null
          ? Duration.zero
          : clampedTransitionDuration(segment, next: next);
      final effect = segment.hasTransition && td > Duration.zero
          ? ffmpegTransitionNameFor(segment.transition)
          : null;
      segments.add({
        'startMs': segment.start.inMilliseconds,
        'endMs': segment.end.inMilliseconds,
        'volume': segment.volume,
        'fadeInMs': segment.fadeIn.inMilliseconds,
        'fadeOutMs': segment.fadeOut.inMilliseconds,
        if (effect != null) ...{
          'transitionEffect': effect,
          'transitionDurationMs': td.inMilliseconds,
        },
      });
    }

    final overlays = <Map<String, dynamic>>[];
    for (final raster in rasters) {
      final spans = visibleSpans(raster.overlay, segments: project.segments);
      if (spans.isEmpty) continue;
      overlays.add({
        if (raster.isAnimated) ...{
          'sequenceDir': raster.sequenceDir!.path,
          'frameCount': raster.frameCount,
          'frameRate': raster.frameRate,
        } else
          'path': raster.file!.path,
        'spans': [
          for (final span in spans)
            {
              'startMs': (span.start * 1000).round(),
              'endMs': (span.end * 1000).round(),
            },
        ],
      });
    }

    final music = <Map<String, dynamic>>[];
    if (musicPath != null) {
      for (final clip in project.musicTracks) {
        music.add({
          'path': musicPath,
          'timelineStartMs': clip.timelineStart.inMilliseconds,
          'sourceOffsetMs': clip.sourceOffset.inMilliseconds,
          'durationMs': clip.clipDuration.inMilliseconds,
          'volume': clip.volume,
          'fadeInMs': clip.effectiveFadeIn.inMilliseconds,
          'fadeOutMs': clip.effectiveFadeOut.inMilliseconds,
        });
      }
    }

    return {
      'sourcePath': project.sourcePath,
      'outputPath': outputPath,
      'width': frame.width,
      'height': frame.height,
      'scaleWidth': frame.scaleWidth,
      'scaleHeight': frame.scaleHeight,
      'rotationDegrees': normalizeClipRotation(project.rotation),
      'durationMs': project.trimmedDuration.inMilliseconds,
      'streamCopy': streamCopy,
      'hasVideoAudio': hasVideoAudio,
      'quality': quality.name,
      'segments': segments,
      'overlays': overlays,
      'music': music,
    };
  }

  static String? _musicPathForProject(VideoProject project) {
    if (project.musicTracks.isEmpty) return null;
    final music = project.musicTracks.first;
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
    if (!project.segments.first.audioEnvelope.isDefault) return false;
    return true;
  }

  static String buildStreamCopyCommand({
    required String sourcePath,
    required String outputPath,
    required String startSec,
    required String durationSec,
  }) {
    // Kept for unit tests that assert legacy CLI shape; runtime uses native.
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

  /// Applies volume/fade to single-segment source audio → `[aenv]`.
  /// Assumes the encode command already seeked with `-ss` to the segment start.
  @visibleForTesting
  static FilterGraph? buildSingleSegmentAudioEnvelope(
    ClipSegment segment, {
    bool hasVideoAudio = true,
  }) {
    if (!hasVideoAudio) return null;
    if (segment.audioEnvelope.isDefault) return null;

    final chain = AudioEnvelope.appendFilters(
      chain: '[0:a]',
      envelope: segment.audioEnvelope,
      clipDuration: segment.duration,
    );
    return FilterGraph(description: '$chain[aenv]', outputLabel: 'aenv');
  }

  /// Mixes background music clips with the trimmed clip audio.
  @visibleForTesting
  static FilterGraph buildAudioMixGraph({
    ProjectMusic? music,
    List<ProjectMusic>? tracks,
    required Duration trimStart,
    required double exportDurationSec,
    required String videoAudioStream,
    required int musicInput,
    bool hasVideoAudio = true,
  }) {
    final clips = tracks ?? (music == null ? const <ProjectMusic>[] : [music]);
    if (clips.isEmpty) {
      return const FilterGraph(description: '[0:a]anull[aout]', outputLabel: 'aout');
    }

    final parts = <String>[];
    for (var i = 0; i < clips.length; i++) {
      final clip = clips[i];
      final delayMs = ((clip.timelineStart - trimStart).inMilliseconds)
          .clamp(0, (exportDurationSec * 1000).round());
      final sourceOffsetSec = clip.sourceOffset.inMilliseconds / 1000.0;
      final clipSec = (clip.clipDuration.inMilliseconds / 1000.0)
          .clamp(0.05, exportDurationSec);
      final volume = clip.volume.clamp(0.0, 1.0).toStringAsFixed(3);
      final fadeInSec = clip.effectiveFadeIn.inMilliseconds / 1000.0;
      final fadeOutSec = clip.effectiveFadeOut.inMilliseconds / 1000.0;

      final chain = StringBuffer(
        '[$musicInput:a]atrim=start=$sourceOffsetSec:duration=$clipSec,'
        'asetpts=PTS-STARTPTS',
      );
      if (fadeInSec > 0) {
        chain.write(
          ',afade=t=in:st=0:d=${fadeInSec.toStringAsFixed(3)}:curve=hsin',
        );
      }
      if (fadeOutSec > 0) {
        final start = (clipSec - fadeOutSec).clamp(0.0, clipSec);
        chain.write(
          ',afade=t=out:st=${start.toStringAsFixed(3)}:d=${fadeOutSec.toStringAsFixed(3)}:curve=hsin',
        );
      }
      if (delayMs > 0) {
        chain.write(',adelay=$delayMs|$delayMs');
      }
      chain.write(',volume=$volume[m$i]');
      parts.add(chain.toString());
    }

    String musicLabel;
    if (clips.length == 1) {
      parts[0] = parts[0].replaceAll('[m0]', '[music]');
      musicLabel = '[music]';
    } else {
      final mixInputs = List.generate(clips.length, (i) => '[m$i]').join();
      parts.add(
        '$mixInputs amix=inputs=${clips.length}:duration=longest:dropout_transition=0[music]',
      );
      musicLabel = '[music]';
    }

    final description = hasVideoAudio
        ? '$videoAudioStream aformat=sample_rates=44100:channel_layouts=stereo,volume=1[va];'
            '${parts.join(';')};'
            '[va]$musicLabel amix=inputs=2:duration=first:dropout_transition=2[aout]'
        : '${parts.join(';')};'
            '${musicLabel.replaceAll('[music]', '[aout]')}'
                .replaceFirst('[music]', '[aout]');

    // When no video audio, the last label is already [music] — rename to [aout].
    final resolved = hasVideoAudio
        ? description
        : '${parts.join(';')}'.replaceAll('[music]', '[aout]');

    return FilterGraph(
      description: hasVideoAudio ? description : resolved,
      outputLabel: 'aout',
    );
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
      final audioChain = AudioEnvelope.appendFilters(
        chain: '[0:a]atrim=start=$start:end=$end,asetpts=PTS-STARTPTS',
        envelope: segment.audioEnvelope,
        clipDuration: segment.duration,
      );
      parts.add('$audioChain[a$i]');
    }

    final usesXfade = segments
        .take(segments.length - 1)
        .any((segment) => segment.hasTransition);
    if (!usesXfade) {
      final labels = StringBuffer();
      for (var i = 0; i < segments.length; i++) {
        labels.write('[v$i][a$i]');
      }
      parts.add(
        '${labels}concat=n=${segments.length}:v=1:a=1[vcat][acat]',
      );
      return parts.join(';');
    }

    var vLabel = 'v0';
    var aLabel = 'a0';
    var cursorSec = segments.first.duration.inMilliseconds / 1000.0;

    for (var i = 0; i < segments.length - 1; i++) {
      final current = segments[i];
      final next = segments[i + 1];
      final td = clampedTransitionDuration(current, next: next);
      final nextV = 'v${i + 1}';
      final nextA = 'a${i + 1}';
      final outV = i == segments.length - 2 ? 'vcat' : 'vx$i';
      final outA = i == segments.length - 2 ? 'acat' : 'ax$i';

      if (current.hasTransition && td > Duration.zero) {
        final name = ffmpegTransitionNameFor(current.transition);
        final durationSec = td.inMilliseconds / 1000.0;
        final offsetSec =
            (cursorSec - durationSec).clamp(0.0, double.infinity);
        parts.add(
          '[$vLabel][$nextV]xfade=transition=$name:'
          'duration=${durationSec.toStringAsFixed(3)}:'
          'offset=${offsetSec.toStringAsFixed(3)}[$outV]',
        );
        parts.add(
          '[$aLabel][$nextA]acrossfade=d=${durationSec.toStringAsFixed(3)}[$outA]',
        );
        cursorSec =
            offsetSec + next.duration.inMilliseconds / 1000.0;
      } else {
        parts.add(
          '[$vLabel][$nextV][$aLabel][$nextA]concat=n=2:v=1:a=1[$outV][$outA]',
        );
        cursorSec += next.duration.inMilliseconds / 1000.0;
      }

      vLabel = outV;
      aLabel = outA;
    }

    return parts.join(';');
  }

  /// Resolves an FFmpeg `xfade` name through [TransitionEngine].
  ///
  /// Falls back to `fade` when the engine has no usable name.
  @visibleForTesting
  static String ffmpegTransitionNameFor(AppliedTransition? applied) {
    final name = TransitionEngine.instance.ffmpegNameFor(applied);
    if (name == null || name.isEmpty) return 'fade';
    return name;
  }

  /// Legacy helper — prefer [ffmpegTransitionNameFor].
  @visibleForTesting
  static String ffmpegTransitionName(String? transitionId) {
    return ffmpegTransitionNameFor(
      transitionId == null || transitionId.isEmpty || transitionId == 'none'
          ? null
          : AppliedTransition(
              id: transitionId,
              version: 1,
              duration: const Duration(milliseconds: 500),
            ),
    );
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
      final ov = 'ov$input';
      if (raster.isAnimated) {
        final span = spans.first;
        final seqSec = (raster.frameCount ?? 1) / raster.frameRate;
        final hold = (span.end - span.start - seqSec).clamp(0.0, double.infinity);
        final prep = StringBuffer('[$input:v]format=rgba');
        if (hold > 0.001) {
          prep.write(
            ',tpad=stop_mode=clone:stop_duration=${hold.toStringAsFixed(3)}',
          );
        }
        prep.write(
          ',setpts=PTS+${span.start.toStringAsFixed(3)}/TB[$ov]',
        );
        steps.add(prep.toString());
        steps.add(
          '[$label][$ov]overlay=0:0:format=auto:eof_action=pass:'
          '${buildOverlayEnableExpression(spans)}[$next]',
        );
      } else {
        steps.add(
          '[$label][$input:v]overlay=0:0:format=auto:repeatlast=1:'
          '${buildOverlayEnableExpression(spans)}[$next]',
        );
      }
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
