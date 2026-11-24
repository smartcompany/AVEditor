import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Normalized insets (0…1 of source size) for CapCut-style stretchable strips.
@immutable
class NineSliceInsets {
  const NineSliceInsets({
    this.left = 0.22,
    this.top = 0.28,
    this.right = 0.22,
    this.bottom = 0.28,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  factory NineSliceInsets.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const NineSliceInsets();
    return NineSliceInsets(
      left: (json['l'] as num?)?.toDouble() ??
          (json['left'] as num?)?.toDouble() ??
          0.22,
      top: (json['t'] as num?)?.toDouble() ??
          (json['top'] as num?)?.toDouble() ??
          0.28,
      right: (json['r'] as num?)?.toDouble() ??
          (json['right'] as num?)?.toDouble() ??
          0.22,
      bottom: (json['b'] as num?)?.toDouble() ??
          (json['bottom'] as num?)?.toDouble() ??
          0.28,
    );
  }

  Map<String, dynamic> toJson() => {
    'l': left,
    't': top,
    'r': right,
    'b': bottom,
  };
}

/// Draws [image] into [dst] with left/right (and top/bottom) caps fixed.
void paintNineSliceImage({
  required Canvas canvas,
  required ui.Image image,
  required Rect dst,
  NineSliceInsets insets = const NineSliceInsets(),
  double opacity = 1,
  ColorFilter? colorFilter,
}) {
  if (dst.width <= 0 || dst.height <= 0) return;
  final sw = image.width.toDouble();
  final sh = image.height.toDouble();
  if (sw <= 0 || sh <= 0) return;

  var l = (sw * insets.left).clamp(1.0, sw * 0.45);
  var r = (sw * insets.right).clamp(1.0, sw * 0.45);
  var t = (sh * insets.top).clamp(1.0, sh * 0.45);
  var b = (sh * insets.bottom).clamp(1.0, sh * 0.45);
  if (l + r >= sw) {
    l = sw * 0.35;
    r = sw * 0.35;
  }
  if (t + b >= sh) {
    t = sh * 0.35;
    b = sh * 0.35;
  }

  var dl = dst.width * (l / sw);
  var dr = dst.width * (r / sw);
  var dt = dst.height * (t / sh);
  var db = dst.height * (b / sh);
  // When the strip is short, shrink caps so center still exists.
  final maxCapW = dst.width * 0.42;
  if (dl + dr > dst.width * 0.84) {
    final scale = (dst.width * 0.84) / (dl + dr);
    dl *= scale;
    dr *= scale;
  }
  if (dt + db > dst.height * 0.84) {
    final scale = (dst.height * 0.84) / (dt + db);
    dt *= scale;
    db *= scale;
  }
  dl = dl.clamp(1.0, maxCapW);
  dr = dr.clamp(1.0, maxCapW);

  final paint = Paint()
    ..isAntiAlias = true
    ..filterQuality = FilterQuality.high
    ..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0));
  if (colorFilter != null) paint.colorFilter = colorFilter;

  void patch(Rect src, Rect out) {
    if (out.width <= 0 || out.height <= 0) return;
    canvas.drawImageRect(image, src, out, paint);
  }

  final srcCenter = Rect.fromLTRB(l, t, sw - r, sh - b);
  final dstCenter = Rect.fromLTRB(
    dst.left + dl,
    dst.top + dt,
    dst.right - dr,
    dst.bottom - db,
  );

  // Corners
  patch(Rect.fromLTWH(0, 0, l, t), Rect.fromLTWH(dst.left, dst.top, dl, dt));
  patch(
    Rect.fromLTWH(sw - r, 0, r, t),
    Rect.fromLTWH(dst.right - dr, dst.top, dr, dt),
  );
  patch(
    Rect.fromLTWH(0, sh - b, l, b),
    Rect.fromLTWH(dst.left, dst.bottom - db, dl, db),
  );
  patch(
    Rect.fromLTWH(sw - r, sh - b, r, b),
    Rect.fromLTWH(dst.right - dr, dst.bottom - db, dr, db),
  );
  // Edges
  patch(
    Rect.fromLTRB(l, 0, sw - r, t),
    Rect.fromLTRB(dst.left + dl, dst.top, dst.right - dr, dst.top + dt),
  );
  patch(
    Rect.fromLTRB(l, sh - b, sw - r, sh),
    Rect.fromLTRB(dst.left + dl, dst.bottom - db, dst.right - dr, dst.bottom),
  );
  patch(
    Rect.fromLTRB(0, t, l, sh - b),
    Rect.fromLTRB(dst.left, dst.top + dt, dst.left + dl, dst.bottom - db),
  );
  patch(
    Rect.fromLTRB(sw - r, t, sw, sh - b),
    Rect.fromLTRB(dst.right - dr, dst.top + dt, dst.right, dst.bottom - db),
  );
  // Center
  patch(srcCenter, dstCenter);
}
