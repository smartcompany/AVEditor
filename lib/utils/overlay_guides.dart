import 'dart:math' as math;

import 'package:aveditor/utils/clip_rotation.dart';
import 'package:aveditor/widgets/overlay_geometry.dart';
import 'package:flutter/rendering.dart';

/// Active alignment guides while dragging a text overlay.
enum OverlayGuide {
  centerX,
  centerY,
  left,
  right,
  top,
  bottom,
  rotateHorizontal,
  rotateVertical,
}

/// Result of snapping an overlay to frame guides.
class OverlayGuideSnap {
  const OverlayGuideSnap({
    required this.offset,
    required this.rotation,
    required this.guides,
  });

  final Offset offset;
  final double rotation;
  final Set<OverlayGuide> guides;
}

/// CapCut-style soft margins (~5% inset from each frame edge).
const double overlayGuideMarginFraction = 0.05;

/// How close (in canvas px) before a guide engages and snaps.
const double overlayGuideSnapPx = 7.0;

/// Degrees within which rotation snaps to an axis.
const double overlayRotateSnapDegrees = 4.0;

double overlayMarginNorm() => overlayGuideMarginFraction * 2;

/// Half-width / half-height of [box] in normalized offset units.
({double halfW, double halfH}) overlayHalfExtents({
  required OverlayBox box,
  required double previewW,
  required double previewH,
}) {
  return (
    halfW: box.width / previewW,
    halfH: box.height / previewH,
  );
}

/// Snap [offset] / [rotation] to center, margin, and axis guides.
OverlayGuideSnap snapOverlayGuides({
  required Offset offset,
  required double rotation,
  required OverlayBox box,
  required double previewW,
  required double previewH,
  bool snapPosition = true,
  bool snapRotation = false,
}) {
  final guides = <OverlayGuide>{};
  var next = offset;
  var nextRotation = rotation;

  if (snapPosition && previewW > 0 && previewH > 0) {
    final threshX = overlayGuideSnapPx / (previewW / 2);
    final threshY = overlayGuideSnapPx / (previewH / 2);
    final extents = overlayHalfExtents(
      box: box,
      previewW: previewW,
      previewH: previewH,
    );
    final margin = overlayMarginNorm();
    final leftTarget = -1 + margin + extents.halfW;
    final rightTarget = 1 - margin - extents.halfW;
    final topTarget = -1 + margin + extents.halfH;
    final bottomTarget = 1 - margin - extents.halfH;

    var dx = next.dx;
    var dy = next.dy;

    if (dx.abs() <= threshX) {
      dx = 0;
      guides.add(OverlayGuide.centerX);
    } else if ((dx - leftTarget).abs() <= threshX) {
      dx = leftTarget;
      guides.add(OverlayGuide.left);
    } else if ((dx - rightTarget).abs() <= threshX) {
      dx = rightTarget;
      guides.add(OverlayGuide.right);
    }

    if (dy.abs() <= threshY) {
      dy = 0;
      guides.add(OverlayGuide.centerY);
    } else if ((dy - topTarget).abs() <= threshY) {
      dy = topTarget;
      guides.add(OverlayGuide.top);
    } else if ((dy - bottomTarget).abs() <= threshY) {
      dy = bottomTarget;
      guides.add(OverlayGuide.bottom);
    }

    next = Offset(dx, dy);
  }

  if (snapRotation) {
    final window = overlayRotateSnapDegrees * math.pi / 180;
    final nearest = (rotation / quarterTurn).round() * quarterTurn;
    if ((rotation - nearest).abs() <= window) {
      nextRotation = normalizeClipRotation(nearest);
      final axis = (nextRotation / quarterTurn).round().abs() % 2;
      if (axis == 0) {
        guides.add(OverlayGuide.rotateHorizontal);
      } else {
        guides.add(OverlayGuide.rotateVertical);
      }
    }
  }

  return OverlayGuideSnap(
    offset: next,
    rotation: nextRotation,
    guides: guides,
  );
}

/// Paints dashed magenta/cyan-style guide lines over the 9:16 preview.
class OverlayGuidePainter extends CustomPainter {
  OverlayGuidePainter({
    required this.guides,
    required this.previewW,
    required this.previewH,
  });

  final Set<OverlayGuide> guides;
  final double previewW;
  final double previewH;

  static const _guideColor = Color(0xFFFF4D8D);

  @override
  void paint(Canvas canvas, Size size) {
    if (guides.isEmpty || previewW <= 0 || previewH <= 0) return;

    final paint = Paint()
      ..color = _guideColor
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final margin = overlayGuideMarginFraction;
    final left = previewW * margin;
    final right = previewW * (1 - margin);
    final top = previewH * margin;
    final bottom = previewH * (1 - margin);
    final cx = previewW / 2;
    final cy = previewH / 2;

    void vLine(double x) => _dashLine(canvas, Offset(x, 0), Offset(x, previewH), paint);
    void hLine(double y) => _dashLine(canvas, Offset(0, y), Offset(previewW, y), paint);

    if (guides.contains(OverlayGuide.centerX) ||
        guides.contains(OverlayGuide.rotateVertical)) {
      vLine(cx);
    }
    if (guides.contains(OverlayGuide.centerY) ||
        guides.contains(OverlayGuide.rotateHorizontal)) {
      hLine(cy);
    }
    if (guides.contains(OverlayGuide.left)) vLine(left);
    if (guides.contains(OverlayGuide.right)) vLine(right);
    if (guides.contains(OverlayGuide.top)) hLine(top);
    if (guides.contains(OverlayGuide.bottom)) hLine(bottom);
  }

  void _dashLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 6.0;
    const gap = 4.0;
    final total = (b - a).distance;
    if (total < 1) return;
    final dir = (b - a) / total;
    var drawn = 0.0;
    while (drawn < total) {
      final start = a + dir * drawn;
      final end = a + dir * math.min(drawn + dash, total);
      canvas.drawLine(start, end, paint);
      drawn += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant OverlayGuidePainter oldDelegate) {
    return oldDelegate.previewW != previewW ||
        oldDelegate.previewH != previewH ||
        !_sameGuides(oldDelegate.guides, guides);
  }

  bool _sameGuides(Set<OverlayGuide> a, Set<OverlayGuide> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }
}
