import 'dart:math' as math;

import 'package:aveditor/utils/overlay_guides.dart';
import 'package:aveditor/widgets/overlay_geometry.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const box = OverlayBox(
    width: 100,
    height: 80,
    fontSize: 20,
    offset: Offset.zero,
  );

  test('snaps to frame center when nearby', () {
    final snapped = snapOverlayGuides(
      offset: const Offset(0.01, -0.012),
      rotation: 0,
      box: box,
      previewW: 270,
      previewH: 480,
    );

    expect(snapped.offset, Offset.zero);
    expect(snapped.guides, containsAll([OverlayGuide.centerX, OverlayGuide.centerY]));
  });

  test('snaps left edge to margin guide', () {
    final halfW = box.width / 270;
    final margin = overlayMarginNorm();
    final nearLeft = -1 + margin + halfW + 0.005;

    final snapped = snapOverlayGuides(
      offset: Offset(nearLeft, 0.4),
      rotation: 0,
      box: box.copyWith(offset: Offset(nearLeft, 0.4)),
      previewW: 270,
      previewH: 480,
    );

    expect(snapped.guides, contains(OverlayGuide.left));
    expect(snapped.offset.dx, closeTo(-1 + margin + halfW, 1e-6));
    expect(snapped.guides, isNot(contains(OverlayGuide.centerY)));
  });

  test('snaps rotation to horizontal and reports guide', () {
    final tilted = 3 * math.pi / 180;
    final snapped = snapOverlayGuides(
      offset: Offset.zero,
      rotation: tilted,
      box: box,
      previewW: 270,
      previewH: 480,
      snapPosition: false,
      snapRotation: true,
    );

    expect(snapped.rotation, 0);
    expect(snapped.guides, contains(OverlayGuide.rotateHorizontal));
  });

  test('snaps rotation to vertical', () {
    final tilted = math.pi / 2 - 2 * math.pi / 180;
    final snapped = snapOverlayGuides(
      offset: Offset.zero,
      rotation: tilted,
      box: box,
      previewW: 270,
      previewH: 480,
      snapPosition: false,
      snapRotation: true,
    );

    expect(snapped.rotation, closeTo(math.pi / 2, 1e-9));
    expect(snapped.guides, contains(OverlayGuide.rotateVertical));
  });
}
