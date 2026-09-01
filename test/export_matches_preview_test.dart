import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aveditor/models/clip_trim.dart';
import 'package:aveditor/models/export_preset.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/video_project.dart';
import 'package:aveditor/services/export_service.dart';
import 'package:aveditor/services/overlay_raster_service.dart';
import 'package:aveditor/utils/export_dimensions.dart';
import 'package:aveditor/widgets/overlay_geometry.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const frameWidth = 1080;
  const frameHeight = 1920;
  const exportFrame = ExportFrameSize(
    width: frameWidth,
    height: frameHeight,
    scaleWidth: frameWidth,
    scaleHeight: frameHeight,
  );

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
      start: start,
      end: end,
      fontSize: fontSize,
      boxWidth: boxWidth,
      boxHeight: boxHeight,
      offset: offset,
      rotation: rotation,
    );
  }

  group('raster placement', () {
    test('text is centred in the same box the preview draws', () {
      final overlay = overlayWith(offset: const Offset(0.25, -0.4));

      final box = overlayBoxForFrame(overlay, frameWidth: frameWidth * 1.0);
      final body = OverlayGeometry.bodyRect(
        previewW: frameWidth * 1.0,
        previewH: frameHeight * 1.0,
        box: box,
      );
      final painter = layoutOverlayText(
        text: overlay.text,
        color: overlay.color,
        fontSize: box.fontSize,
        maxWidth: box.width,
      );

      final origin = const OverlayRasterService()
          .textOriginFor(overlay, width: frameWidth, height: frameHeight);

      expect(origin.dx + painter.width / 2, closeTo(body.center.dx, 0.001));
      expect(origin.dy + painter.height / 2, closeTo(body.center.dy, 0.001));
      painter.dispose();
    });

    test('the box centre follows the normalized offset', () {
      final overlay = overlayWith(offset: const Offset(0.5, 0.25));
      final box = overlayBoxForFrame(overlay, frameWidth: frameWidth * 1.0);
      final body = OverlayGeometry.bodyRect(
        previewW: frameWidth * 1.0,
        previewH: frameHeight * 1.0,
        box: box,
      );

      expect(body.center.dx, closeTo(frameWidth / 2 + 0.5 * frameWidth / 2, 0.001));
      expect(body.center.dy, closeTo(frameHeight / 2 + 0.25 * frameHeight / 2, 0.001));
    });

    testWidgets('renders a frame-sized PNG with ink inside the box only',
        (tester) async {
      final overlay = overlayWith(offset: const Offset(0.4, -0.5));
      late final ui.Image image;

      await tester.runAsync(() async {
        final png = await const OverlayRasterService()
            .renderToPng(overlay, width: frameWidth, height: frameHeight);
        image = await decodeImageFromList(png);
      });

      expect(image.width, frameWidth);
      expect(image.height, frameHeight);

      late final ByteData pixels;
      await tester.runAsync(() async {
        pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      });

      final box = overlayBoxForFrame(overlay, frameWidth: frameWidth * 1.0);
      final body = OverlayGeometry.bodyRect(
        previewW: frameWidth * 1.0,
        previewH: frameHeight * 1.0,
        box: box,
      );
      // The blurred shadow bleeds a little past the glyphs.
      final allowed = body.inflate(box.fontSize);

      var inked = 0;
      for (var y = 0; y < frameHeight; y++) {
        for (var x = 0; x < frameWidth; x++) {
          final alpha = pixels.getUint8((y * frameWidth + x) * 4 + 3);
          if (alpha == 0) continue;
          inked++;
          expect(
            allowed.contains(Offset(x.toDouble(), y.toDouble())),
            isTrue,
            reason: 'pixel ($x, $y) painted outside $allowed',
          );
        }
      }
      expect(inked, greaterThan(0), reason: 'overlay rendered nothing');
      image.dispose();
    });

    testWidgets('rotation turns the ink about the box centre, not the frame',
        (tester) async {
      // A wide, short box off to one side: after a quarter turn the ink must
      // occupy the *transposed* box around the same centre. Rotating about the
      // frame centre instead would move it across the frame.
      final overlay = overlayWith(
        text: 'rotate me',
        offset: const Offset(0.4, -0.5),
        rotation: math.pi / 2,
      );
      late final ui.Image image;
      late final ByteData pixels;

      await tester.runAsync(() async {
        final png = await const OverlayRasterService()
            .renderToPng(overlay, width: frameWidth, height: frameHeight);
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

    test('text wraps against the box width, not the frame', () {
      final overlay = overlayWith(text: 'wrap me across several lines please');
      final box = overlayBoxForFrame(overlay, frameWidth: frameWidth * 1.0);
      final painter = layoutOverlayText(
        text: overlay.text,
        color: overlay.color,
        fontSize: box.fontSize,
        maxWidth: box.width,
      );

      expect(painter.width, lessThanOrEqualTo(box.width + 0.001));
      expect(painter.computeLineMetrics().length, greaterThan(1));
      painter.dispose();
    });
  });

  group('filter graph', () {
    VideoProject projectWith(
      List<TextOverlay> overlays, {
      ClipTrim? trim,
      double rotation = 0,
    }) =>
        VideoProject(
          id: 'test-project',
          sourcePath: '/tmp/in.mp4',
          duration: const Duration(seconds: 10),
          trim: trim,
          overlays: overlays,
          rotation: rotation,
        );

    OverlayRaster rasterFor(TextOverlay overlay, int index) => OverlayRaster(
          overlay: overlay,
          file: File('/tmp/overlay_$index.png'),
        );

    test('crops to the preset then composites each overlay in order', () {
      final a = overlayWith(id: 'a', end: const Duration(seconds: 4));
      final b = overlayWith(
        id: 'b',
        start: const Duration(seconds: 4),
        end: const Duration(seconds: 9),
      );

      final graph = const ExportService().buildFilterGraph(
        project: projectWith([a, b]),
        rasters: [rasterFor(a, 0), rasterFor(b, 1)],
        frame: exportFrame,
      );

      expect(
        graph.description,
        '[0:v]scale=1080:1920:flags=lanczos,crop=1080:1920[base];'
        '[base][1:v]overlay=0:0:format=auto:repeatlast=1:'
        "enable='between(t\\,0.000\\,4.000)'[v1];"
        '[v1][2:v]overlay=0:0:format=auto:repeatlast=1:'
        "enable='between(t\\,4.000\\,9.000)'[v2]",
      );
      expect(graph.outputLabel, 'v2');
    });

    test('overlays outside the trim are dropped but input indexes hold', () {
      final early = overlayWith(id: 'early', end: const Duration(seconds: 1));
      final late = overlayWith(
        id: 'late',
        start: const Duration(seconds: 6),
        end: const Duration(seconds: 9),
      );
      final project = projectWith(
        [early, late],
        trim: ClipTrim(
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 10),
        ),
      );

      final graph = const ExportService().buildFilterGraph(
        project: project,
        rasters: [rasterFor(early, 0), rasterFor(late, 1)],
        frame: exportFrame,
      );

      // `early` ends before the trim starts, so only input 2 is composited.
      expect(graph.description, contains('[base][2:v]overlay'));
      expect(graph.description, isNot(contains('[1:v]')));
      expect(graph.outputLabel, 'v2');
    });

    test('a project without overlays still crops to the preset', () {
      final graph = const ExportService().buildFilterGraph(
        project: projectWith([]),
        rasters: [],
        frame: exportFrame,
      );

      expect(graph.outputLabel, 'base');
      expect(graph.description, endsWith('[base]'));
    });

    test('a rotated clip adds FFmpeg rotate after the cover crop', () {
      final graph = const ExportService().buildFilterGraph(
        project: projectWith([], rotation: math.pi / 4),
        rasters: [],
        frame: exportFrame,
      );

      expect(
        graph.description,
        '[0:v]scale=1080:1920:flags=lanczos,crop=1080:1920,rotate=0.785398:ow=1080:oh=1920:c=black[base]',
      );
      expect(graph.outputLabel, 'base');
    });

    test('the preset is the frame overlays were authored against', () {
      expect(ExportPreset.youtubeShorts.width, kOverlayFrameWidth);
      expect(ExportPreset.youtubeShorts.height, kOverlayFrameHeight);
    });
  });
}
