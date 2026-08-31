import 'package:aveditor/models/text_overlay.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

enum OverlayDragKind { move, resize }

class OverlayDrag {
  const OverlayDrag._(this.kind, {this.fromLeft, this.fromTop});

  final OverlayDragKind kind;
  final bool? fromLeft;
  final bool? fromTop;

  static const move = OverlayDrag._(OverlayDragKind.move);

  static OverlayDrag resize({required bool fromLeft, required bool fromTop}) {
    return OverlayDrag._(
      OverlayDragKind.resize,
      fromLeft: fromLeft,
      fromTop: fromTop,
    );
  }

  bool get isResize => kind == OverlayDragKind.resize;

  String get label {
    if (kind == OverlayDragKind.move) return 'move';
    return 'resize_${fromLeft == true ? 'L' : 'R'}${fromTop == true ? 'T' : 'B'}';
  }
}

/// Overlay layout + hit testing in preview (canvas) coordinates.
class OverlayGeometry {
  OverlayGeometry._();

  static const handleHit = 56.0;
  static const knobSize = 14.0;
  static const knobOutset = 22.0;
  static const handlePad = knobOutset + knobSize / 2 + handleHit / 2 + 4;

  static double boxWidth(TextOverlay overlay, {double? live}) =>
      live ?? overlay.boxWidth;

  static double boxHeight(TextOverlay overlay, {double? live}) =>
      live ?? overlay.boxHeight;

  static Offset boxOffset(TextOverlay overlay, {Offset? live}) =>
      live ?? overlay.offset;

  static Offset chromeTopLeft({
    required double previewW,
    required double previewH,
    required TextOverlay overlay,
    double? liveW,
    double? liveH,
    Offset? liveOffset,
  }) {
    final w = boxWidth(overlay, live: liveW);
    final h = boxHeight(overlay, live: liveH);
    final o = boxOffset(overlay, live: liveOffset);
    final cx = previewW / 2 + o.dx * (previewW / 2);
    final cy = previewH / 2 + o.dy * (previewH / 2);
    return Offset(cx - w / 2 - handlePad, cy - h / 2 - handlePad);
  }

  static Rect chromeRect({
    required double previewW,
    required double previewH,
    required TextOverlay overlay,
    double? liveW,
    double? liveH,
    Offset? liveOffset,
  }) {
    final w = boxWidth(overlay, live: liveW);
    final h = boxHeight(overlay, live: liveH);
    final topLeft = chromeTopLeft(
      previewW: previewW,
      previewH: previewH,
      overlay: overlay,
      liveW: liveW,
      liveH: liveH,
      liveOffset: liveOffset,
    );
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      w + handlePad * 2,
      h + handlePad * 2,
    );
  }

  /// Text box only, without the handle padding ring.
  static Rect bodyRect({
    required double previewW,
    required double previewH,
    required TextOverlay overlay,
    double? liveW,
    double? liveH,
    Offset? liveOffset,
  }) {
    final topLeft = chromeTopLeft(
      previewW: previewW,
      previewH: previewH,
      overlay: overlay,
      liveW: liveW,
      liveH: liveH,
      liveOffset: liveOffset,
    );
    return Rect.fromLTWH(
      topLeft.dx + handlePad,
      topLeft.dy + handlePad,
      boxWidth(overlay, live: liveW),
      boxHeight(overlay, live: liveH),
    );
  }

  /// Hit test in preview-local coordinates (full 9:16 canvas incl. letterbox).
  static OverlayDrag? hitTestPreviewPoint(
    Offset previewPoint, {
    required double previewW,
    required double previewH,
    required TextOverlay overlay,
    required bool editing,
    double? liveW,
    double? liveH,
    Offset? liveOffset,
  }) {
    final topLeft = chromeTopLeft(
      previewW: previewW,
      previewH: previewH,
      overlay: overlay,
      liveW: liveW,
      liveH: liveH,
      liveOffset: liveOffset,
    );
    final local = previewPoint - topLeft;
    final boxW = boxWidth(overlay, live: liveW);
    final boxH = boxHeight(overlay, live: liveH);
    return _hitTestLocal(local, boxW, boxH, editing: editing);
  }

  static OverlayDrag? _hitTestLocal(
    Offset local,
    double boxW,
    double boxH, {
    required bool editing,
  }) {
    const pad = handlePad;
    const knobRadius = knobSize / 2;
    const hit = handleHit / 2;

    final corners = <(Offset, OverlayDrag)>[
      (
        Offset(pad - knobOutset + knobRadius, pad - knobOutset + knobRadius),
        OverlayDrag.resize(fromLeft: true, fromTop: true),
      ),
      (
        Offset(
          pad + boxW + knobOutset - knobRadius,
          pad - knobOutset + knobRadius,
        ),
        OverlayDrag.resize(fromLeft: false, fromTop: true),
      ),
      (
        Offset(
          pad - knobOutset + knobRadius,
          pad + boxH + knobOutset - knobRadius,
        ),
        OverlayDrag.resize(fromLeft: true, fromTop: false),
      ),
      (
        Offset(
          pad + boxW + knobOutset - knobRadius,
          pad + boxH + knobOutset - knobRadius,
        ),
        OverlayDrag.resize(fromLeft: false, fromTop: false),
      ),
    ];

    for (final (anchor, drag) in corners) {
      if ((local - anchor).distance <= hit) return drag;
    }

    final moveCenter = Offset(pad + boxW / 2, pad + boxH - 14);
    if ((local - moveCenter).distance <= hit) {
      return OverlayDrag.move;
    }

    if (!editing &&
        local.dx >= pad &&
        local.dx <= pad + boxW &&
        local.dy >= pad &&
        local.dy <= pad + boxH) {
      return OverlayDrag.move;
    }

    return null;
  }
}
