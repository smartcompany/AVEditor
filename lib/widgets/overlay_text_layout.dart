import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/widgets/overlay_geometry.dart';
import 'package:flutter/material.dart';

/// Bundled font used for overlay text.
///
/// Pinned rather than inherited from the theme so the preview and the exported
/// video lay out identically — theme fonts are fetched at runtime and would
/// silently change line breaking.
const String overlayFontFamily = 'OverlayText';

Color overlayTextFillColor({
  required TextOverlayStyle style,
  required Color accent,
}) {
  switch (style) {
    case TextOverlayStyle.plain:
      return accent;
    case TextOverlayStyle.outline:
      return accent.computeLuminance() > 0.6 ? Colors.black : Colors.white;
    case TextOverlayStyle.box:
      return accent.computeLuminance() > 0.55 ? Colors.black : Colors.white;
    case TextOverlayStyle.boxDim:
      return Colors.white;
  }
}

Color overlayStyleBackgroundColor({
  required TextOverlayStyle style,
  required Color accent,
}) {
  switch (style) {
    case TextOverlayStyle.plain:
    case TextOverlayStyle.outline:
      return Colors.transparent;
    case TextOverlayStyle.box:
      return accent;
    case TextOverlayStyle.boxDim:
      return const Color(0x8C000000);
  }
}

double overlayStrokeWidth(double fontSize) =>
    (fontSize * 0.08).clamp(2.0, 12.0);

/// Padding around the laid-out glyphs for box-style backgrounds.
EdgeInsets overlayTextBackgroundPadding(double fontSize) {
  return EdgeInsets.symmetric(
    horizontal: fontSize * 0.22,
    vertical: fontSize * 0.14,
  );
}

/// Paints one rounded background per line, like YouTube Shorts.
void paintOverlayLineBackgrounds({
  required Canvas canvas,
  required TextPainter painter,
  required Offset origin,
  required Color background,
  required double fontSize,
}) {
  if (background.a <= 0) return;

  final padding = overlayTextBackgroundPadding(fontSize);
  final radius = Radius.circular((fontSize * 0.18).clamp(4.0, 12.0));
  final paint = Paint()..color = background;

  for (final line in painter.computeLineMetrics()) {
    final rect = Rect.fromLTWH(
      origin.dx + line.left - padding.left,
      origin.dy + line.baseline - line.ascent - padding.top,
      line.width + padding.horizontal,
      line.ascent + line.descent + padding.vertical,
    );
    canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
  }
}

/// Fill layer for overlay text.
TextStyle overlayTextFillStyle({
  required Color color,
  required double fontSize,
  TextOverlayStyle style = TextOverlayStyle.plain,
}) {
  final fill = overlayTextFillColor(style: style, accent: color);
  final base = TextStyle(
    fontFamily: overlayFontFamily,
    color: fill,
    fontSize: fontSize,
    fontWeight: FontWeight.w700,
    height: 1.15,
  );

  if (style == TextOverlayStyle.plain) {
    return base.copyWith(
      shadows: const [Shadow(blurRadius: 8, color: Color(0x8A000000))],
    );
  }
  return base;
}

/// Stroke layer for outline mode. Must not be combined with [color] on one
/// [TextStyle] — paint it behind [overlayTextFillStyle] instead.
TextStyle overlayTextStrokeStyle({
  required Color color,
  required double fontSize,
}) {
  return TextStyle(
    fontFamily: overlayFontFamily,
    fontSize: fontSize,
    fontWeight: FontWeight.w700,
    height: 1.15,
    foreground: Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = overlayStrokeWidth(fontSize)
      ..color = color,
  );
}

/// Convenience alias for the fill layer.
TextStyle overlayTextStyle({
  required Color color,
  required double fontSize,
  TextOverlayStyle style = TextOverlayStyle.plain,
}) {
  return overlayTextFillStyle(color: color, fontSize: fontSize, style: style);
}

TextPainter _createTextPainter({
  required String text,
  required TextStyle style,
  required double maxWidth,
}) {
  return TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  )..layout(maxWidth: maxWidth);
}

/// Lays text out exactly the way the preview's centred [Text] does.
TextPainter layoutOverlayText({
  required String text,
  required Color color,
  required double fontSize,
  required double maxWidth,
  TextOverlayStyle style = TextOverlayStyle.plain,
}) {
  return _createTextPainter(
    text: text,
    style: overlayTextFillStyle(
      color: color,
      fontSize: fontSize,
      style: style,
    ),
    maxWidth: maxWidth,
  );
}

/// Resolves [overlay] into a frame of [frameWidth] x [frameHeight] pixels.
OverlayBox overlayBoxForFrame(
  TextOverlay overlay, {
  required double frameWidth,
}) {
  final scale = frameWidth / kOverlayFrameWidth;
  return OverlayBox(
    width: overlay.boxWidth * scale,
    height: overlay.boxHeight * scale,
    fontSize: overlay.fontSize * scale,
    offset: overlay.offset,
    rotation: overlay.rotation,
  );
}

/// Where the laid-out text block sits inside the frame, in frame pixels.
Offset overlayTextOrigin({
  required TextPainter painter,
  required OverlayBox box,
  required double frameWidth,
  required double frameHeight,
}) {
  final body = OverlayGeometry.bodyRect(
    previewW: frameWidth,
    previewH: frameHeight,
    box: box,
  );
  return Offset(
    body.left + (body.width - painter.width) / 2,
    body.top + (body.height - painter.height) / 2,
  );
}

/// Paints the style background and text the same way in preview and export.
void paintOverlayTextLayer({
  required Canvas canvas,
  required TextOverlay overlay,
  required OverlayBox box,
  required double frameWidth,
  required double frameHeight,
}) {
  final background = overlayStyleBackgroundColor(
    style: overlay.style,
    accent: overlay.color,
  );

  final fillPainter = layoutOverlayText(
    text: overlay.text,
    color: overlay.color,
    fontSize: box.fontSize,
    maxWidth: box.width,
    style: overlay.style,
  );
  final origin = overlayTextOrigin(
    painter: fillPainter,
    box: box,
    frameWidth: frameWidth,
    frameHeight: frameHeight,
  );

  if (background.a > 0) {
    paintOverlayLineBackgrounds(
      canvas: canvas,
      painter: fillPainter,
      origin: origin,
      background: background,
      fontSize: box.fontSize,
    );
  }

  if (overlay.style == TextOverlayStyle.outline) {
    final strokePainter = _createTextPainter(
      text: overlay.text,
      style: overlayTextStrokeStyle(
        color: overlay.color,
        fontSize: box.fontSize,
      ),
      maxWidth: box.width,
    );
    strokePainter.paint(canvas, origin);
    strokePainter.dispose();
  }

  fillPainter.paint(canvas, origin);
  fillPainter.dispose();
}

/// Preview widget that paints overlay text the same way as export.
class OverlayTextDisplay extends StatefulWidget {
  const OverlayTextDisplay({
    super.key,
    required this.text,
    required this.color,
    required this.fontSize,
    required this.maxWidth,
    required this.style,
    this.hintColor,
  });

  final String text;
  final Color color;
  final double fontSize;
  final double maxWidth;
  final TextOverlayStyle style;
  final Color? hintColor;

  @override
  State<OverlayTextDisplay> createState() => _OverlayTextDisplayState();
}

class _OverlayTextDisplayState extends State<OverlayTextDisplay> {
  TextPainter? _fillPainter;
  TextPainter? _strokePainter;

  @override
  void initState() {
    super.initState();
    _layout();
  }

  @override
  void didUpdateWidget(covariant OverlayTextDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.color != widget.color ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.maxWidth != widget.maxWidth ||
        oldWidget.style != widget.style ||
        oldWidget.hintColor != widget.hintColor) {
      _layout();
    }
  }

  @override
  void dispose() {
    _disposePainters();
    super.dispose();
  }

  void _disposePainters() {
    _fillPainter?.dispose();
    _strokePainter?.dispose();
    _fillPainter = null;
    _strokePainter = null;
  }

  void _layout() {
    _disposePainters();

    var fillStyle = overlayTextFillStyle(
      color: widget.color,
      fontSize: widget.fontSize,
      style: widget.style,
    );
    if (widget.hintColor != null) {
      fillStyle = fillStyle.copyWith(color: widget.hintColor);
    }

    _fillPainter = _createTextPainter(
      text: widget.text,
      style: fillStyle,
      maxWidth: widget.maxWidth,
    );

    if (widget.style == TextOverlayStyle.outline &&
        widget.hintColor == null) {
      _strokePainter = _createTextPainter(
        text: widget.text,
        style: overlayTextStrokeStyle(
          color: widget.color,
          fontSize: widget.fontSize,
        ),
        maxWidth: widget.maxWidth,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final fill = _fillPainter;
    if (fill == null) return const SizedBox.shrink();

    return CustomPaint(
      size: Size(fill.width, fill.height),
      painter: _OverlayTextDisplayPainter(
        fillPainter: fill,
        strokePainter: _strokePainter,
        style: widget.style,
        color: widget.color,
        fontSize: widget.fontSize,
      ),
    );
  }
}

class _OverlayTextDisplayPainter extends CustomPainter {
  _OverlayTextDisplayPainter({
    required this.fillPainter,
    required this.strokePainter,
    required this.style,
    required this.color,
    required this.fontSize,
  });

  final TextPainter fillPainter;
  final TextPainter? strokePainter;
  final TextOverlayStyle style;
  final Color color;
  final double fontSize;

  @override
  void paint(Canvas canvas, Size size) {
    final background = overlayStyleBackgroundColor(style: style, accent: color);
    if (background.a > 0) {
      paintOverlayLineBackgrounds(
        canvas: canvas,
        painter: fillPainter,
        origin: Offset.zero,
        background: background,
        fontSize: fontSize,
      );
    }

    strokePainter?.paint(canvas, Offset.zero);
    fillPainter.paint(canvas, Offset.zero);
  }

  @override
  bool shouldRepaint(covariant _OverlayTextDisplayPainter oldDelegate) {
    return oldDelegate.fillPainter != fillPainter ||
        oldDelegate.strokePainter != strokePainter ||
        oldDelegate.style != style ||
        oldDelegate.color != color ||
        oldDelegate.fontSize != fontSize;
  }
}
