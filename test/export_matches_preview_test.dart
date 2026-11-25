import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/services/overlay_raster_service.dart';
import 'package:aveditor/widgets/overlay_geometry.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const frameWidth = 1080;
  const frameHeight = 1920;

  TextOverlay overlayWith({
    String text = 'hello there',
    Offset offset = Offset.zero,
    double fontSize = 84,
    double boxWidth = 540,
    double boxHeight = 264,
    Duration start = Duration.zero,
    Duration end = const Duration(seconds: 5),
    String id = 'o1',
    double rotation = 0,
  }) {
    return TextOverlay(
      id: id,
      text: text,
      color: Colors.white,
      fontSize: fontSize,
      offset: offset,
      start: start,
      end: end,
      boxWidth: boxWidth,
      boxHeight: boxHeight,
      rotation: rotation,
    );
  }

  group('overlay raster matches preview geometry', () {
    test('rotated text stays inside the turned bounding box', () async {
      final overlay = overlayWith(rotation: math.pi / 2);
      late ui.Image image;
      late ByteData pixels;
      await TestWidgetsFlutterBinding.ensureInitialized().runAsync(() async {
        const rasterService = OverlayRasterService();
        final png = await rasterService.renderToPng(
          overlay,
          width: frameWidth,
          height: frameHeight,
        );
        image = await decodeImageFromList(png);
        pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      });

      final box = overlayBoxForFrame(overlay, frameWidth: frameWidth * 1.0);
      final centre = OverlayGeometry.boxCenter(
        previewW: frameWidth * 1.0,
        previewH: frameHeight * 1.0,
        box: box,
      );
      final turned = Rect.fromCenter(
        center: centre,
        width: box.height,
        height: box.width,
      ).inflate(box.fontSize);

      var inked = 0;
      for (var y = 0; y < frameHeight; y++) {
        for (var x = 0; x < frameWidth; x++) {
          if (pixels.getUint8((y * frameWidth + x) * 4 + 3) == 0) continue;
          inked++;
          expect(
            turned.contains(Offset(x.toDouble(), y.toDouble())),
            isTrue,
            reason: 'pixel ($x, $y) painted outside the rotated box $turned',
          );
        }
      }
      expect(inked, greaterThan(0), reason: 'overlay rendered nothing');
      image.dispose();
    });

    test('layoutOverlayText soft-wraps when given a narrow maxWidth', () {
      final overlay = overlayWith(text: 'wrap me across several lines please');
      final box = overlayBoxForFrame(overlay, frameWidth: frameWidth * 1.0);
      // Low-level API: an explicit narrow budget still wraps.
      final painter = layoutOverlayText(
        text: overlay.text,
        color: overlay.color,
        fontSize: box.fontSize,
        maxWidth: box.width * 0.35,
      );

      expect(painter.width, lessThanOrEqualTo(box.width * 0.35 + 0.001));
      expect(painter.computeLineMetrics().length, greaterThan(1));
      painter.dispose();
    });

    test('long single-line text stays one line; frame clips overflow', () {
      // Long Hangul / titles that extend past the video edges must match the
      // editor preview: one line, not soft-wrapped back into the frame.
      const long =
          '가나다라마바사아자차카타파하가나다라마바사아자차카타파하가나다라마바사';
      final overlay = overlayWith(
        text: long,
        fontSize: 120,
        boxWidth: maxOverlayBoxWidth,
        boxHeight: 200,
      );
      final box = overlayBoxForFrame(overlay, frameWidth: frameWidth * 1.0);
      final template = resolveOverlayTemplate(overlay);
      final padH = overlayTextPadH(fontSize: box.fontSize, template: template);
      final contentMaxWidth = (box.width - padH * 2).clamp(1.0, box.width);
      final style = overlayTextFillStyle(
        color: overlay.color,
        fontSize: box.fontSize,
        style: overlay.style,
        fontFamily: overlay.fontFamily,
      );
      final paintMaxWidth = overlayPaintMaxWidth(
        text: overlay.text,
        style: style,
        contentMaxWidth: contentMaxWidth,
        textAlign: overlay.textAlign,
        fallbackFontSize: box.fontSize,
      );
      final painter = layoutOverlayText(
        text: overlay.text,
        color: overlay.color,
        fontSize: box.fontSize,
        maxWidth: paintMaxWidth,
        style: overlay.style,
      );

      expect(painter.computeLineMetrics().length, 1);
      expect(painter.width, greaterThan(frameWidth.toDouble()));
      painter.dispose();

      final fitted = measureFittedOverlayBox(
        text: long,
        fontSize: 120,
        template: template,
      );
      // Chrome may clamp width, but height must stay single-line (not reflow).
      expect(fitted.height, lessThan(120 * 2.5));
    });
  });
}
