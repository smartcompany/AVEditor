import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:aveditor/models/text_overlay.dart';
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
  }) : assert(
         (file != null) ^ (sequenceDir != null),
         'Provide either a static file or an animated sequence',
       );

  final TextOverlay overlay;

  /// Static full-frame PNG (no entrance animation).
  final File? file;

  /// Directory of `frame_0001.png` … for entrance animation.
  final Directory? sequenceDir;
  final int? frameCount;
  final double frameRate;

  bool get isAnimated => sequenceDir != null && (frameCount ?? 0) > 0;
}

const double exportEntranceFps = 24;

/// Renders text overlays with Flutter's own text engine.
///
/// FFmpeg's `drawtext` cannot reproduce the preview: it breaks lines with its
/// own metrics and has no blurred shadow. Painting the overlays here and
/// compositing the result guarantees the export matches what the user saw.
class OverlayRasterService {
  const OverlayRasterService();

  /// Paints [overlays] onto transparent [width] x [height] PNGs in [outputDir].
  Future<List<OverlayRaster>> renderAll(
    List<TextOverlay> overlays, {
    required int width,
    required int height,
    required Directory outputDir,
  }) async {
    final rendered = <OverlayRaster>[];
    for (var i = 0; i < overlays.length; i++) {
      final overlay = overlays[i];
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

  /// PNG sequence covering the entrance; export holds the last frame after.
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
    final frameCount = math.max(2, (durationSec * fps).ceil() + 1);
    for (var f = 0; f < frameCount; f++) {
      final progress = (f / (frameCount - 1)).clamp(0.0, 1.0);
      final entrance = evaluateTextEntrance(
        animationId: animation.id,
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
