import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/services/sticker_storage_service.dart';
import 'package:aveditor/widgets/overlay_geometry.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:aveditor/widgets/text_entrance.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

/// A rendered overlay ready to be composited onto the video.
@immutable
class OverlayRaster {
  const OverlayRaster({
    required this.overlay,
    this.file,
    this.sequenceDir,
    this.frameCount,
    this.frameRate = exportEntranceFps,
    this.sequenceDurationMs,
    this.loop = false,
  }) : assert(
         (file != null) ^ (sequenceDir != null),
         'Provide either a static file or an animated sequence',
       );

  final TextOverlay overlay;

  /// Static full-frame PNG (no entrance animation).
  final File? file;

  /// Directory of `frame_0001.png` … for entrance animation / sticker GIF.
  final Directory? sequenceDir;
  final int? frameCount;
  final double frameRate;

  /// One-loop duration in ms (GIF length or entrance length).
  final int? sequenceDurationMs;

  /// When true, native burns cycle frames for the whole overlay span.
  final bool loop;

  bool get isAnimated => sequenceDir != null && (frameCount ?? 0) > 0;
}

const double exportEntranceFps = 24;
const double exportStickerFps = 15;

/// Paints text overlays with Flutter's own text engine, then composites via
/// the native OS exporter (AVFoundation / Media3).
class OverlayRasterService {
  const OverlayRasterService();

  /// Paints [overlays] onto transparent [width] x [height] PNGs in [outputDir].
  Future<List<OverlayRaster>> renderAll(
    List<TextOverlay> overlays, {
    required int width,
    required int height,
    required Directory outputDir,
    String? projectDir,
  }) async {
    final rendered = <OverlayRaster>[];
    for (var i = 0; i < overlays.length; i++) {
      final overlay = overlays[i];
      if (overlay.isSticker) {
        final sticker = await renderStickerSequence(
          overlay,
          width: width,
          height: height,
          outputDir: Directory(p.join(outputDir.path, 'overlay_${i}_seq')),
          projectDir: projectDir,
        );
        if (sticker != null) rendered.add(sticker);
        continue;
      }

      if (overlay.text.trim().isEmpty) continue;

      final anim = resolveOverlayAnimation(overlay);
      if (!anim.isNone) {
        final seqDir = Directory(p.join(outputDir.path, 'overlay_${i}_seq'));
        await seqDir.create(recursive: true);
        final count = await renderEntranceSequence(
          overlay,
          animation: anim,
          width: width,
          height: height,
          outputDir: seqDir,
        );
        rendered.add(
          OverlayRaster(
            overlay: overlay,
            sequenceDir: seqDir,
            frameCount: count,
            frameRate: exportEntranceFps,
            sequenceDurationMs: resolvedEntranceDuration(
              overlay: overlay,
              animation: anim,
            ).inMilliseconds,
          ),
        );
        continue;
      }

      final bytes = await renderToPng(overlay, width: width, height: height);
      final file = File(p.join(outputDir.path, 'overlay_$i.png'));
      await file.writeAsBytes(bytes, flush: true);
      rendered.add(OverlayRaster(overlay: overlay, file: file));
    }
    return rendered;
  }

  /// Decodes a sticker GIF into a full-frame transparent PNG sequence that
  /// loops for the clip duration (`loop: true` on the native overlay map).
  @visibleForTesting
  Future<OverlayRaster?> renderStickerSequence(
    TextOverlay overlay, {
    required int width,
    required int height,
    required Directory outputDir,
    String? projectDir,
    double fps = exportStickerFps,
  }) async {
    final relative = overlay.stickerLocalPath;
    if (relative == null || relative.isEmpty) return null;
    final root = projectDir;
    if (root == null || root.isEmpty) return null;

    final gifFile = File(StickerStorageService.absolutePath(root, relative));
    if (!await gifFile.exists()) return null;

    final bytes = await gifFile.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frameCount = codec.frameCount;
      if (frameCount <= 0) return null;

      final frames = <ui.FrameInfo>[];
      var totalMs = 0;
      for (var i = 0; i < frameCount; i++) {
        final info = await codec.getNextFrame();
        frames.add(info);
        final d = info.duration.inMilliseconds;
        totalMs += d > 0 ? d : (1000 / fps).round();
      }
      if (totalMs <= 0) {
        totalMs = math.max(1, (frameCount / fps * 1000).round());
      }

      await outputDir.create(recursive: true);
      for (var i = 0; i < frames.length; i++) {
        final png = await renderStickerFrameToPng(
          overlay,
          frame: frames[i].image,
          width: width,
          height: height,
        );
        frames[i].image.dispose();
        final name = 'frame_${(i + 1).toString().padLeft(4, '0')}.png';
        await File(p.join(outputDir.path, name)).writeAsBytes(png, flush: true);
      }

      final effectiveFps = frameCount / (totalMs / 1000.0);
      return OverlayRaster(
        overlay: overlay,
        sequenceDir: outputDir,
        frameCount: frameCount,
        frameRate: effectiveFps.isFinite && effectiveFps > 0
            ? effectiveFps
            : fps,
        sequenceDurationMs: totalMs,
        loop: true,
      );
    } finally {
      // Codec has no dispose on all platforms; frames are disposed above.
    }
  }

  /// PNG sequence covering the entrance (or full crawl span); export holds
  /// the last frame after.
  @visibleForTesting
  Future<int> renderEntranceSequence(
    TextOverlay overlay, {
    required TextEntranceAnimation animation,
    required int width,
    required int height,
    required Directory outputDir,
    double fps = exportEntranceFps,
  }) async {
    final duration = resolvedEntranceDuration(
      overlay: overlay,
      animation: animation,
    );
    final durationSec = duration.inMilliseconds / 1000.0;
    final maxFrames =
        (TextEntranceAnimation.maxContinuousMs / 1000.0 * fps).ceil() + 1;
    final frameCount = math
        .max(2, (durationSec * fps).ceil() + 1)
        .clamp(2, maxFrames);
    for (var f = 0; f < frameCount; f++) {
      final progress = (f / (frameCount - 1)).clamp(0.0, 1.0);
      final entrance = evaluateTextEntrance(
        animationId: animation.id,
        animation: animation,
        text: overlay.text,
        progress: progress,
        fontSize: overlayBoxForFrame(
          overlay,
          frameWidth: width.toDouble(),
        ).fontSize,
      );
      final bytes = await renderToPng(
        overlay,
        width: width,
        height: height,
        entrance: entrance,
      );
      final name = 'frame_${(f + 1).toString().padLeft(4, '0')}.png';
      await File(p.join(outputDir.path, name)).writeAsBytes(bytes, flush: true);
    }
    return frameCount;
  }

  @visibleForTesting
  Offset textOriginFor(
    TextOverlay overlay, {
    required int width,
    required int height,
  }) {
    final box = overlayBoxForFrame(overlay, frameWidth: width.toDouble());
    final painter = layoutOverlayText(
      text: overlay.text,
      color: overlay.color,
      fontSize: box.fontSize,
      maxWidth: box.width,
      style: overlay.style,
    );
    final origin = overlayTextOrigin(
      painter: painter,
      box: box,
      frameWidth: width.toDouble(),
      frameHeight: height.toDouble(),
    );
    painter.dispose();
    return origin;
  }

  @visibleForTesting
  Future<Uint8List> renderStickerFrameToPng(
    TextOverlay overlay, {
    required ui.Image frame,
    required int width,
    required int height,
  }) async {
    final box = overlayBoxForFrame(overlay, frameWidth: width.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    final centre = OverlayGeometry.boxCenter(
      previewW: width.toDouble(),
      previewH: height.toDouble(),
      box: box,
    );
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    if (box.rotation != 0) {
      canvas.rotate(box.rotation);
    }
    final dst = Rect.fromCenter(
      center: Offset.zero,
      width: box.width,
      height: box.height,
    );
    paintImage(
      canvas: canvas,
      rect: dst,
      image: frame,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.medium,
    );
    canvas.restore();

    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) {
          throw StateError('Failed to encode sticker ${overlay.id}');
        }
        return data.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  @visibleForTesting
  Future<Uint8List> renderToPng(
    TextOverlay overlay, {
    required int width,
    required int height,
    TextEntranceState? entrance,
  }) async {
    final box = overlayBoxForFrame(overlay, frameWidth: width.toDouble());

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    // The preview rotates the whole chrome about the box centre; rotating the
    // canvas the same way keeps the text layout itself identical.
    if (box.rotation != 0) {
      final centre = OverlayGeometry.boxCenter(
        previewW: width.toDouble(),
        previewH: height.toDouble(),
        box: box,
      );
      canvas
        ..save()
        ..translate(centre.dx, centre.dy)
        ..rotate(box.rotation)
        ..translate(-centre.dx, -centre.dy);
    }
    paintOverlayTextLayer(
      canvas: canvas,
      overlay: overlay,
      box: box,
      frameWidth: width.toDouble(),
      frameHeight: height.toDouble(),
      entrance: entrance,
    );
    if (box.rotation != 0) canvas.restore();

    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) {
          throw StateError('Failed to encode overlay ${overlay.id}');
        }
        return data.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }
}
