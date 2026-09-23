import 'dart:io';

import 'package:aveditor/models/export_preset.dart';
import 'package:aveditor/models/export_quality_profile.dart';
import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/models/applied_transition.dart';
import 'package:aveditor/models/transition_item.dart';
import 'package:aveditor/services/export_save_service.dart';
import 'package:aveditor/services/native_video_engine.dart';
import 'package:aveditor/services/overlay_raster_service.dart';
import 'package:aveditor/models/transition_role_effect.dart';
import 'package:aveditor/services/transition_catalog_service.dart';
import 'package:aveditor/services/transition_engine.dart';
import 'package:aveditor/services/video_probe_service.dart';
import 'package:aveditor/utils/clip_rotation.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/export_dimensions.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Exports trimmed video with 9:16 crop and burned-in text overlays via the
/// native OS encoder (VideoToolbox / MediaCodec).
///
/// When the edit is trim-only, [ExportQualityProfile.allowsStreamCopy] profiles
/// copy the source streams without re-encoding.
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

    await TransitionCatalogService.instance.ensureInitialized();

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
          ? transitionEffectNameFor(segment.transition)
          : null;
      final motion = segment.hasTransition && td > Duration.zero
          ? transitionMotionFor(segment.transition)
          : const <Map<String, Object>>[];
      final role = segment.hasTransition
          ? TransitionEngine.instance.plan(segment.transition).definition?.roleEffect
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
          if (motion.isNotEmpty) 'transitionLayers': motion,
          if (role != null) ...{
            'transitionKind': role.kind,
            'transitionReverse': role.reverse,
            'transitionParams': {
              for (final entry in role.params.entries)
                if (entry.value is num ||
                    entry.value is bool ||
                    entry.value is String)
                  entry.key: entry.value,
            },
          },
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

  /// Native compositor / GPU effect id (slideleft, dissolve, …).
  @visibleForTesting
  static String transitionEffectNameFor(AppliedTransition? applied) {
    final name = TransitionEngine.instance.effectNameFor(applied);
    if (name == null || name.isEmpty) return 'fade';
    return name;
  }

  /// Catalog motion the exporter replays. Not limited to scale/rotation —
  /// translate, opacity, blur and brightness are part of the saved look.
  @visibleForTesting
  static List<Map<String, Object>> transitionMotionFor(
    AppliedTransition? applied,
  ) {
    final layers =
        TransitionEngine.instance.plan(applied).definition?.layers ?? const [];
    return [
      for (final layer in layers)
        {
          'property': layer.property.name,
          'from': layer.from,
          'to': layer.to,
          'easing': layer.easing.name,
          'target': layer.target.toJson(),
          'start': layer.start,
          'end': layer.end,
          if (layer.param != null) 'param': layer.param!,
          if (layer.mode != null) 'mode': layer.mode!,
        },
    ];
  }

  /// How album export should draw [item]. Empty means the effect would be dropped.
  @visibleForTesting
  static String? exportVisualFor(TransitionItem item) {
    if (item.roleEffect != null) return 'kind:${item.roleEffect!.kind}';
    if (item.layers.isNotEmpty) return 'layers';
    const named = {
      'fade',
      'dissolve',
      'fadeblack',
      'fadewhite',
      'circleopen',
      'circleclose',
      'radial',
      'slideleft',
      'slideright',
      'slideup',
      'slidedown',
    };
    if (named.contains(item.effectName)) return 'name:${item.effectName}';
    return null;
  }

  /// Visible spans of [overlay] on the packed export timeline.
  @visibleForTesting
  static List<({double start, double end})> visibleSpans(
    TextOverlay overlay, {
    required List<ClipSegment> segments,
  }) {
    return overlayExportSpans(overlay, segments);
  }

  /// Builds the map sent to [NativeVideoEngine.export] (test helper).
  @visibleForTesting
  Map<String, dynamic> buildNativeExportRequestForTest({
    required VideoProject project,
    required List<OverlayRaster> rasters,
    required ExportQualityProfile quality,
    required ExportFrameSize frame,
    required String outputPath,
    String? musicPath,
    bool hasVideoAudio = true,
  }) {
    return _buildNativeExportRequest(
      project: project,
      rasters: rasters,
      quality: quality,
      frame: frame,
      outputPath: outputPath,
      musicPath: musicPath,
      hasVideoAudio: hasVideoAudio,
      streamCopy: canStreamCopy(
        project: project,
        rasters: rasters,
        quality: quality,
        musicPath: musicPath,
      ),
    );
  }
}
