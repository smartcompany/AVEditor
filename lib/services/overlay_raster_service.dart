import 'dart:io';
import 'dart:ui' as ui;

import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/widgets/overlay_geometry.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

/// A rendered overlay ready to be composited onto the video.
@immutable
class OverlayRaster {
  const OverlayRaster({required this.overlay, required this.file});

  final TextOverlay overlay;
  final File file;
}

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

      final bytes = await renderToPng(overlay, width: width, height: height);
      final file = File(p.join(outputDir.path, 'overlay_$i.png'));
      await file.writeAsBytes(bytes, flush: true);
      rendered.add(OverlayRaster(overlay: overlay, file: file));
    }
    return rendered;
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
  }) async {
    final box = overlayBoxForFrame(overlay, frameWidth: width.toDouble());
    final painter = layoutOverlayText(
      text: overlay.text,
      color: overlay.color,
      fontSize: box.fontSize,
      maxWidth: box.width,
    );

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
    painter.paint(
      canvas,
      overlayTextOrigin(
        painter: painter,
        box: box,
        frameWidth: width.toDouble(),
        frameHeight: height.toDouble(),
      ),
    );
    if (box.rotation != 0) canvas.restore();
    painter.dispose();

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
