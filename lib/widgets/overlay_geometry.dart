import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// What a press on the overlay chrome does.
///
/// [delete] and [duplicate] are one-shot taps rather than drags; the rest are
/// continuous gestures.
enum OverlayDragKind { move, resize, resizeRotate, delete, duplicate }

class OverlayDrag {
  const OverlayDrag._(this.kind, {this.fromLeft, this.fromTop});

  final OverlayDragKind kind;
  final bool? fromLeft;
  final bool? fromTop;

  static const move = OverlayDrag._(OverlayDragKind.move);
  static const delete = OverlayDrag._(OverlayDragKind.delete);
  static const duplicate = OverlayDrag._(OverlayDragKind.duplicate);

  /// Bottom-right: scales and rotates at once.
  static const resizeRotate = OverlayDrag._(OverlayDragKind.resizeRotate);

  static OverlayDrag resize({required bool fromLeft, required bool fromTop}) {
    return OverlayDrag._(
      OverlayDragKind.resize,
      fromLeft: fromLeft,
      fromTop: fromTop,
    );
  }

  bool get isResize =>
      kind == OverlayDragKind.resize || kind == OverlayDragKind.resizeRotate;

  /// Fires on release without travel, so a slip does not destroy work.
  bool get isTapAction =>
      kind == OverlayDragKind.delete || kind == OverlayDragKind.duplicate;

  String get label {
    switch (kind) {
      case OverlayDragKind.move:
        return 'move';
      case OverlayDragKind.delete:
        return 'delete';
      case OverlayDragKind.duplicate:
        return 'duplicate';
      case OverlayDragKind.resizeRotate:
        return 'resize_rotate';
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

/// Overlay layout + hit testing in preview (canvas) coordinates.
class OverlayGeometry {
  OverlayGeometry._();

  static const handleHit = 56.0;
  static const knobSize = 14.0;
  static const knobOutset = 22.0;
  static const handlePad = knobOutset + knobSize / 2 + handleHit / 2 + 4;

  /// Grip sits in the padding ring below the box so it never eats text space.
  static const gripOutset = 18.0;

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
  }) {
    final centre = boxCenter(previewW: previewW, previewH: previewH, box: box);
    return Offset(
      centre.dx - box.width / 2 - handlePad,
      centre.dy - box.height / 2 - handlePad,
    );
  }

  static Rect chromeRect({
    required double previewW,
    required double previewH,
    required OverlayBox box,
  }) {
    final topLeft = chromeTopLeft(
      previewW: previewW,
      previewH: previewH,
      box: box,
    );
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      box.width + handlePad * 2,
      box.height + handlePad * 2,
    );
  }

  /// Text box only, without the handle padding ring, before rotation.
  static Rect bodyRect({
    required double previewW,
    required double previewH,
    required OverlayBox box,
  }) {
    final topLeft = chromeTopLeft(
      previewW: previewW,
      previewH: previewH,
      box: box,
    );
    return Rect.fromLTWH(
      topLeft.dx + handlePad,
      topLeft.dy + handlePad,
      box.width,
      box.height,
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
    ).contains(local);
  }

  /// Hit test in preview-local coordinates (full 9:16 canvas incl. letterbox).
  static OverlayDrag? hitTestPreviewPoint(
    Offset previewPoint, {
    required double previewW,
    required double previewH,
    required OverlayBox box,
    required bool editing,
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
    );
    return _hitTestLocal(
      local - topLeft,
      box.width,
      box.height,
      editing: editing,
    );
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

    final left = pad - knobOutset + knobRadius;
    final right = pad + boxW + knobOutset - knobRadius;
    final top = pad - knobOutset + knobRadius;
    final bottom = pad + boxH + knobOutset - knobRadius;

    final corners = <(Offset, OverlayDrag)>[
      (Offset(left, top), OverlayDrag.delete),
      (
        Offset(right, top),
        OverlayDrag.resize(fromLeft: false, fromTop: true),
      ),
      (Offset(left, bottom), OverlayDrag.duplicate),
      (Offset(right, bottom), OverlayDrag.resizeRotate),
    ];

    for (final (anchor, drag) in corners) {
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
