import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// What a press on the overlay chrome does.
///
/// [delete], [duplicate], and [edit] are one-shot taps; the rest are
/// continuous gestures.
enum OverlayDragKind {
  move,
  resize,
  resizeRotate,
  pinch,
  delete,
  duplicate,
  edit,
}

class OverlayDrag {
  const OverlayDrag._(this.kind, {this.fromLeft, this.fromTop});

  final OverlayDragKind kind;
  final bool? fromLeft;
  final bool? fromTop;

  static const move = OverlayDrag._(OverlayDragKind.move);
  static const delete = OverlayDrag._(OverlayDragKind.delete);
  static const duplicate = OverlayDrag._(OverlayDragKind.duplicate);
  static const edit = OverlayDrag._(OverlayDragKind.edit);

  /// Bottom-right: scales and rotates at once.
  static const resizeRotate = OverlayDrag._(OverlayDragKind.resizeRotate);

  /// Two-finger pinch: uniform scale about the box centre.
  static const pinch = OverlayDrag._(OverlayDragKind.pinch);

  static OverlayDrag resize({required bool fromLeft, required bool fromTop}) {
    return OverlayDrag._(
      OverlayDragKind.resize,
      fromLeft: fromLeft,
      fromTop: fromTop,
    );
  }

  bool get isResize =>
      kind == OverlayDragKind.resize ||
      kind == OverlayDragKind.resizeRotate ||
      kind == OverlayDragKind.pinch;

  /// Fires on release without travel, so a slip does not destroy work.
  bool get isTapAction =>
      kind == OverlayDragKind.delete ||
      kind == OverlayDragKind.duplicate ||
      kind == OverlayDragKind.edit;

  String get label {
    switch (kind) {
      case OverlayDragKind.move:
        return 'move';
      case OverlayDragKind.delete:
        return 'delete';
      case OverlayDragKind.duplicate:
        return 'duplicate';
      case OverlayDragKind.edit:
        return 'edit';
      case OverlayDragKind.resizeRotate:
        return 'resize_rotate';
      case OverlayDragKind.pinch:
        return 'pinch';
      case OverlayDragKind.resize:
        return 'resize_'
            '${fromLeft == true ? 'L' : 'R'}${fromTop == true ? 'T' : 'B'}';
    }
  }
}

/// An overlay's box resolved into preview-canvas pixels.
///
/// Overlays store their size in frame pixels; the preview canvas is a different
/// size, so everything is converted once here and the rest of the layout and
/// hit-testing code works in a single space.
@immutable
class OverlayBox {
  const OverlayBox({
    required this.width,
    required this.height,
    required this.fontSize,
    required this.offset,
    this.rotation = 0,
  });

  final double width;
  final double height;
  final double fontSize;
  final Offset offset;

  /// Clockwise radians about the box centre.
  final double rotation;

  OverlayBox scaled(double factor) => OverlayBox(
    width: width * factor,
    height: height * factor,
    fontSize: fontSize * factor,
    offset: offset,
    rotation: rotation,
  );

  OverlayBox copyWith({
    double? width,
    double? height,
    double? fontSize,
    Offset? offset,
    double? rotation,
  }) {
    return OverlayBox(
      width: width ?? this.width,
      height: height ?? this.height,
      fontSize: fontSize ?? this.fontSize,
      offset: offset ?? this.offset,
      rotation: rotation ?? this.rotation,
    );
  }
}

/// Resolved corner placement so action knobs stay on-screen.
@immutable
class OverlayChromeCorners {
  const OverlayChromeCorners({
    required this.delete,
    required this.edit,
    required this.duplicate,
    required this.resizeRotate,
  });

  /// Centres in chrome-local coordinates (origin = [OverlayGeometry.chromeTopLeft]).
  final Offset delete;
  final Offset edit;
  final Offset duplicate;
  final Offset resizeRotate;
}

/// Overlay layout + hit testing in preview (canvas) coordinates.
class OverlayGeometry {
  OverlayGeometry._();

  static const handleHit = 45.0;
  static const knobSize = 35.0;

  /// Outward offset so each knob circle is tangent to its box corner
  /// (center lies on the corner diagonal at distance [knobSize]/2).
  /// = (knobSize/2) * (1 + 1/√2)
  static const knobOutset = 29.87436867;

  static const handlePad = knobOutset + knobSize / 2 + handleHit / 2 + 4;

  /// Grip sits in the padding ring below the box so it never eats text space.
  static const gripOutset = 18.0;

  /// Keep icon knobs this far inside the clamp rect so they stay tappable.
  static const chromeKnobMargin = 20.0;

  /// On-screen pixels per canvas pixel for a [BoxFit.contain] host.
  ///
  /// Dock resize shrinks the FittedBox; divide fixed screen sizes by this so
  /// chrome knobs stay the same finger size.
  static double canvasScreenScale({
    required double previewW,
    required double previewH,
    Size? hostViewport,
  }) {
    if (hostViewport == null || previewW <= 0 || previewH <= 0) return 1.0;
    final sx = hostViewport.width / previewW;
    final sy = hostViewport.height / previewH;
    final scale = math.min(sx, sy);
    if (!scale.isFinite || scale <= 0) return 1.0;
    return scale;
  }

  /// Canvas-space knob diameter that paints as [knobSize] on screen.
  static double knobSizeForScale(double screenScale) {
    final s = screenScale <= 0 ? 1.0 : screenScale;
    return knobSize / s;
  }

  /// Canvas-space hit diameter matching [knobSizeForScale].
  static double handleHitForScale(double screenScale) {
    final s = screenScale <= 0 ? 1.0 : screenScale;
    return handleHit / s;
  }

  static double chromeKnobMarginForScale(double screenScale) {
    final s = screenScale <= 0 ? 1.0 : screenScale;
    return chromeKnobMargin / s;
  }

  static double handlePadForScale(double screenScale) {
    final knob = knobSizeForScale(screenScale);
    final hit = handleHitForScale(screenScale);
    final outset = (knob / 2) * (1 + 1 / math.sqrt2);
    return outset + knob / 2 + hit / 2 + 4;
  }

  /// Default clamp: the 9:16 video canvas (no letterbox gutters).
  static Rect previewClampRect(double previewW, double previewH) {
    return Rect.fromLTWH(0, 0, previewW, previewH);
  }

  /// Centre of the box in canvas pixels — also the pivot for [OverlayBox.rotation].
  static Offset boxCenter({
    required double previewW,
    required double previewH,
    required OverlayBox box,
  }) {
    return Offset(
      previewW / 2 + box.offset.dx * (previewW / 2),
      previewH / 2 + box.offset.dy * (previewH / 2),
    );
  }

  /// Top-left of the chrome *before* rotation.
  ///
  /// The widget layer positions the chrome here and rotates it about its own
  /// centre, which coincides with [boxCenter] because the padding is symmetric.
  static Offset chromeTopLeft({
    required double previewW,
    required double previewH,
    required OverlayBox box,
    double screenScale = 1,
  }) {
    final centre = boxCenter(previewW: previewW, previewH: previewH, box: box);
    final pad = handlePadForScale(screenScale);
    return Offset(
      centre.dx - box.width / 2 - pad,
      centre.dy - box.height / 2 - pad,
    );
  }

  static Rect chromeRect({
    required double previewW,
    required double previewH,
    required OverlayBox box,
    double screenScale = 1,
  }) {
    final pad = handlePadForScale(screenScale);
    final topLeft = chromeTopLeft(
      previewW: previewW,
      previewH: previewH,
      box: box,
      screenScale: screenScale,
    );
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      box.width + pad * 2,
      box.height + pad * 2,
    );
  }

  /// Text box only, without the handle padding ring, before rotation.
  static Rect bodyRect({
    required double previewW,
    required double previewH,
    required OverlayBox box,
    double screenScale = 1,
  }) {
    final pad = handlePadForScale(screenScale);
    final topLeft = chromeTopLeft(
      previewW: previewW,
      previewH: previewH,
      box: box,
      screenScale: screenScale,
    );
    return Rect.fromLTWH(
      topLeft.dx + pad,
      topLeft.dy + pad,
      box.width,
      box.height,
    );
  }

  /// Preview-space centre of a corner action knob before clamping.
  ///
  /// Placed on the outward corner diagonal so the knob circle is tangent to
  /// the box vertex (circle edge meets the corner).
  static Offset _idealKnobPreviewCenter({
    required Rect body,
    required bool left,
    required bool top,
    double screenScale = 1,
  }) {
    final r = knobSizeForScale(screenScale) / 2;
    final along = r / math.sqrt2;
    return Offset(
      left ? body.left - along : body.right + along,
      top ? body.top - along : body.bottom + along,
    );
  }

  /// Picks on-screen knob centres (chrome-local) for the four actions.
  ///
  /// Ideal positions sit outside each box corner; when a corner leaves
  /// [clampRect] the knob slides onto the nearest visible edge.
  ///
  /// [clampRect] is in preview-canvas coordinates. Pass the editor viewport
  /// (video + letterbox gutters) so knobs may sit in the black bars instead of
  /// being forced onto the 9:16 frame.
  ///
  /// [screenScale] is canvas→screen from [canvasScreenScale]; knobs keep a
  /// fixed finger size when the preview FittedBox shrinks.
  static OverlayChromeCorners resolveChromeCorners({
    required double previewW,
    required double previewH,
    required OverlayBox box,
    Rect? clampRect,
    double screenScale = 1,
  }) {
    final body = bodyRect(previewW: previewW, previewH: previewH, box: box);
    final chromeOrigin = chromeTopLeft(
      previewW: previewW,
      previewH: previewH,
      box: box,
      screenScale: screenScale,
    );
    final bounds = clampRect ?? previewClampRect(previewW, previewH);
    final margin = chromeKnobMarginForScale(screenScale);
    final minX = bounds.left + margin;
    final maxX = bounds.right - margin;
    final minY = bounds.top + margin;
    final maxY = bounds.bottom - margin;

    Offset place({required bool left, required bool top}) {
      final ideal = _idealKnobPreviewCenter(
        body: body,
        left: left,
        top: top,
        screenScale: screenScale,
      );
      final clamped = Offset(
        minX <= maxX ? ideal.dx.clamp(minX, maxX) : ideal.dx,
        minY <= maxY ? ideal.dy.clamp(minY, maxY) : ideal.dy,
      );
      return clamped - chromeOrigin;
    }

    return OverlayChromeCorners(
      delete: place(left: true, top: true),
      edit: place(left: false, top: true),
      duplicate: place(left: true, top: false),
      resizeRotate: place(left: false, top: false),
    );
  }

  /// Maps a canvas point into the box's own un-rotated frame.
  ///
  /// Every rect above is axis aligned, so rotation is handled once here rather
  /// than by rotating each rect.
  static Offset toBoxFrame(
    Offset point, {
    required double previewW,
    required double previewH,
    required OverlayBox box,
  }) {
    if (box.rotation == 0) return point;
    final centre = boxCenter(previewW: previewW, previewH: previewH, box: box);
    final v = point - centre;
    final cos = math.cos(-box.rotation);
    final sin = math.sin(-box.rotation);
    return Offset(
      centre.dx + v.dx * cos - v.dy * sin,
      centre.dy + v.dx * sin + v.dy * cos,
    );
  }

  static bool bodyContains(
    Offset previewPoint, {
    required double previewW,
    required double previewH,
    required OverlayBox box,
  }) {
    final local = toBoxFrame(
      previewPoint,
      previewW: previewW,
      previewH: previewH,
      box: box,
    );
    return bodyRect(
      previewW: previewW,
      previewH: previewH,
      box: box,
    ).contains(local);
  }

  static bool chromeContains(
    Offset previewPoint, {
    required double previewW,
    required double previewH,
    required OverlayBox box,
    double screenScale = 1,
  }) {
    final local = toBoxFrame(
      previewPoint,
      previewW: previewW,
      previewH: previewH,
      box: box,
    );
    return chromeRect(
      previewW: previewW,
      previewH: previewH,
      box: box,
      screenScale: screenScale,
    ).contains(local);
  }

  /// Hit test in preview-local coordinates.
  static OverlayDrag? hitTestPreviewPoint(
    Offset previewPoint, {
    required double previewW,
    required double previewH,
    required OverlayBox box,
    required bool editing,
    Rect? clampRect,
    bool allowEdit = true,
    double screenScale = 1,
  }) {
    final local = toBoxFrame(
      previewPoint,
      previewW: previewW,
      previewH: previewH,
      box: box,
    );
    final topLeft = chromeTopLeft(
      previewW: previewW,
      previewH: previewH,
      box: box,
      screenScale: screenScale,
    );
    final corners = resolveChromeCorners(
      previewW: previewW,
      previewH: previewH,
      box: box,
      clampRect: clampRect,
      screenScale: screenScale,
    );
    return _hitTestLocal(
      local - topLeft,
      box.width,
      box.height,
      editing: editing,
      corners: corners,
      allowEdit: allowEdit,
      screenScale: screenScale,
    );
  }

  /// Maps a [BoxFit.contain] + [Alignment.topCenter] host viewport into
  /// preview-canvas coordinates (letterbox gutters become negative / >size).
  static Rect viewportClampRect({
    required double previewW,
    required double previewH,
    required Size hostViewport,
  }) {
    if (previewW <= 0 || previewH <= 0) {
      return previewClampRect(previewW, previewH);
    }
    if (hostViewport.width <= 0 || hostViewport.height <= 0) {
      return previewClampRect(previewW, previewH);
    }
    final scale = math.min(
      hostViewport.width / previewW,
      hostViewport.height / previewH,
    );
    if (scale <= 0) return previewClampRect(previewW, previewH);

    final displayedW = previewW * scale;
    final displayedH = previewH * scale;
    // Matches FittedBox alignment: Alignment.topCenter
    final dx = (hostViewport.width - displayedW) / 2;
    final dy = 0.0;
    return Rect.fromLTRB(
      -dx / scale,
      -dy / scale,
      previewW + (hostViewport.width - displayedW - dx) / scale,
      previewH + (hostViewport.height - displayedH - dy) / scale,
    );
  }

  static OverlayDrag? _hitTestLocal(
    Offset local,
    double boxW,
    double boxH, {
    required bool editing,
    required OverlayChromeCorners corners,
    bool allowEdit = true,
    double screenScale = 1,
  }) {
    final hit = handleHitForScale(screenScale) / 2;
    final pad = handlePadForScale(screenScale);

    final anchors = <(Offset, OverlayDrag)>[
      (corners.delete, OverlayDrag.delete),
      if (allowEdit) (corners.edit, OverlayDrag.edit),
      (corners.duplicate, OverlayDrag.duplicate),
      (corners.resizeRotate, OverlayDrag.resizeRotate),
    ];

    for (final (anchor, drag) in anchors) {
      if ((local - anchor).distance <= hit) return drag;
    }

    final gripCenter = Offset(pad + boxW / 2, pad + boxH + gripOutset);
    if ((local - gripCenter).distance <= hit) {
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
