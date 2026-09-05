import 'package:aveditor/widgets/overlay_geometry.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const previewW = 270.0;
  const previewH = 480.0;

  Offset previewOf(OverlayBox box, Offset chromeLocal) {
    final origin = OverlayGeometry.chromeTopLeft(
      previewW: previewW,
      previewH: previewH,
      box: box,
    );
    return origin + chromeLocal;
  }

  test('centered box keeps knobs outside each corner', () {
    const box = OverlayBox(
      width: 120,
      height: 60,
      fontSize: 20,
      offset: Offset.zero,
    );
    final corners = OverlayGeometry.resolveChromeCorners(
      previewW: previewW,
      previewH: previewH,
      box: box,
    );
    final body = OverlayGeometry.bodyRect(
      previewW: previewW,
      previewH: previewH,
      box: box,
    );
    final delete = previewOf(box, corners.delete);
    expect(delete.dx, lessThan(body.left));
    expect(delete.dy, lessThan(body.top));
    expect(delete.dx, greaterThan(OverlayGeometry.chromeKnobMargin - 0.1));
    expect(delete.dy, greaterThan(OverlayGeometry.chromeKnobMargin - 0.1));
  });

  test('top-edge knobs clamp into the preview', () {
    final box = OverlayBox(
      width: 140,
      height: 70,
      fontSize: 20,
      offset: const Offset(0, -0.85),
    );
    final corners = OverlayGeometry.resolveChromeCorners(
      previewW: previewW,
      previewH: previewH,
      box: box,
    );
    for (final local in [
      corners.delete,
      corners.edit,
      corners.duplicate,
      corners.resizeRotate,
    ]) {
      final p = previewOf(box, local);
      expect(p.dy, greaterThanOrEqualTo(OverlayGeometry.chromeKnobMargin));
      expect(
        p.dy,
        lessThanOrEqualTo(previewH - OverlayGeometry.chromeKnobMargin),
      );
    }
  });

  test('left-edge knobs clamp into the preview', () {
    final box = OverlayBox(
      width: 140,
      height: 70,
      fontSize: 20,
      offset: const Offset(-0.9, 0),
    );
    final corners = OverlayGeometry.resolveChromeCorners(
      previewW: previewW,
      previewH: previewH,
      box: box,
    );
    for (final local in [
      corners.delete,
      corners.edit,
      corners.duplicate,
      corners.resizeRotate,
    ]) {
      final p = previewOf(box, local);
      expect(p.dx, greaterThanOrEqualTo(OverlayGeometry.chromeKnobMargin));
      expect(
        p.dx,
        lessThanOrEqualTo(previewW - OverlayGeometry.chromeKnobMargin),
      );
    }
  });

  test('left-edge knobs may sit in letterbox when clamp expands', () {
    final box = OverlayBox(
      width: 140,
      height: 70,
      fontSize: 20,
      offset: const Offset(-0.9, 0),
    );
    // Host wider than 9:16 canvas → side gutters in preview space.
    final clamp = OverlayGeometry.viewportClampRect(
      previewW: previewW,
      previewH: previewH,
      hostViewport: const Size(400, 480),
    );
    expect(clamp.left, lessThan(0));
    expect(clamp.right, greaterThan(previewW));

    final corners = OverlayGeometry.resolveChromeCorners(
      previewW: previewW,
      previewH: previewH,
      box: box,
      clampRect: clamp,
    );
    final delete = previewOf(box, corners.delete);
    // Allowed into the gutter, not forced onto the video frame edge.
    expect(delete.dx, lessThan(OverlayGeometry.chromeKnobMargin));
    expect(
      delete.dx,
      greaterThanOrEqualTo(clamp.left + OverlayGeometry.chromeKnobMargin),
    );
  });
}
