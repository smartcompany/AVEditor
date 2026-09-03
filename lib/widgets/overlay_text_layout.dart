import 'dart:ui' as ui;

import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
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

/// Maps the Shorts A-button cycle onto a [TextStyleTemplate].
TextStyleTemplate templateForBasicStyle(TextOverlayStyle style) {
  switch (style) {
    case TextOverlayStyle.plain:
      return TextStyleTemplateCatalog.classic;
    case TextOverlayStyle.outline:
      return TextStyleTemplateCatalog.outline;
    case TextOverlayStyle.box:
      return TextStyleTemplateCatalog.banner;
    case TextOverlayStyle.boxDim:
      return TextStyleTemplateCatalog.dimBanner;
  }
}

TextStyleTemplate resolveOverlayTemplate(TextOverlay overlay) {
  final packStyle =
      TextTemplatePackService.instance.styleFor(overlay.packItemId);
  if (packStyle != null) return packStyle;
  return overlay.template ?? templateForBasicStyle(overlay.style);
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
  double padHFactor = 0.22,
  double padVFactor = 0.14,
  double radiusFactor = 0.18,
}) {
  if (background.a <= 0) return;

  final padH = fontSize * padHFactor;
  final padV = fontSize * padVFactor;
  final radius = Radius.circular((fontSize * radiusFactor).clamp(4.0, 12.0));
  final paint = Paint()..color = background;

  for (final line in painter.computeLineMetrics()) {
    final rect = Rect.fromLTWH(
      origin.dx + line.left - padH,
      origin.dy + line.baseline - line.ascent - padV,
      line.width + padH * 2,
      line.ascent + line.descent + padV * 2,
    );
    canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
  }
}

TextStyle _baseTextStyle({
  required double fontSize,
  Color? color,
  Paint? foreground,
  List<Shadow>? shadows,
}) {
  return TextStyle(
    fontFamily: overlayFontFamily,
    color: foreground == null ? color : null,
    fontSize: fontSize,
    fontWeight: FontWeight.w700,
    height: 1.15,
    foreground: foreground,
    shadows: shadows,
  );
}

/// Fill layer for overlay text (basic style path / editing field).
TextStyle overlayTextFillStyle({
  required Color color,
  required double fontSize,
  TextOverlayStyle style = TextOverlayStyle.plain,
}) {
  final fill = overlayTextFillColor(style: style, accent: color);
  if (style == TextOverlayStyle.plain) {
    return _baseTextStyle(
      fontSize: fontSize,
      color: fill,
      shadows: const [Shadow(blurRadius: 8, color: Color(0x8A000000))],
    );
  }
  return _baseTextStyle(fontSize: fontSize, color: fill);
}

/// Stroke layer for outline mode.
TextStyle overlayTextStrokeStyle({
  required Color color,
  required double fontSize,
  double? width,
}) {
  return _baseTextStyle(
    fontSize: fontSize,
    foreground: Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width ?? overlayStrokeWidth(fontSize)
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

TextPainter createOverlayTextPainter({
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
  return createOverlayTextPainter(
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

void _paintStrokeLayer({
  required Canvas canvas,
  required String text,
  required double fontSize,
  required double maxWidth,
  required Offset origin,
  required Color color,
  required double width,
  double blur = 0,
}) {
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..color = color
    ..strokeJoin = StrokeJoin.round;
  if (blur > 0) {
    paint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, blur);
  }

  final painter = createOverlayTextPainter(
    text: text,
    style: _baseTextStyle(fontSize: fontSize, foreground: paint),
    maxWidth: maxWidth,
  );
  painter.paint(canvas, origin);
  painter.dispose();
}

void _paintFillLayer({
  required Canvas canvas,
  required String text,
  required double fontSize,
  required double maxWidth,
  required Offset origin,
  required Color color,
  List<Shadow>? shadows,
}) {
  final painter = createOverlayTextPainter(
    text: text,
    style: _baseTextStyle(fontSize: fontSize, color: color, shadows: shadows),
    maxWidth: maxWidth,
  );
  painter.paint(canvas, origin);
  painter.dispose();
}

/// Shared paint path for preview + export Word Art / Shorts styles.
void paintTextStyleTemplate({
  required Canvas canvas,
  required String text,
  required Color accent,
  required double fontSize,
  required double maxWidth,
  required Offset origin,
  required TextStyleTemplate template,
}) {
  final fillColor = template.resolveFill(accent);
  final metricsPainter = createOverlayTextPainter(
    text: text,
    style: _baseTextStyle(fontSize: fontSize, color: fillColor),
    maxWidth: maxWidth,
  );

  final lineBg = template.lineBackground;
  if (lineBg != null) {
    paintOverlayLineBackgrounds(
      canvas: canvas,
      painter: metricsPainter,
      origin: origin,
      background: lineBg.resolveColor(accent),
      fontSize: fontSize,
      padHFactor: lineBg.padHFactor,
      padVFactor: lineBg.padVFactor,
      radiusFactor: lineBg.radiusFactor,
    );
  }

  final glow = template.glow;
  if (glow != null) {
    _paintStrokeLayer(
      canvas: canvas,
      text: text,
      fontSize: fontSize,
      maxWidth: maxWidth,
      origin: origin,
      color: glow.resolveColor(accent),
      width: (fontSize * glow.widthFactor).clamp(1.0, 40.0),
      blur: (fontSize * glow.blurFactor).clamp(1.0, 48.0),
    );
  }

  final shadow = template.shadow;
  if (shadow != null) {
    final dx = fontSize * shadow.dxFactor;
    final dy = fontSize * shadow.dyFactor;
    final blur = fontSize * shadow.blurFactor;
    _paintFillLayer(
      canvas: canvas,
      text: text,
      fontSize: fontSize,
      maxWidth: maxWidth,
      origin: origin + Offset(dx, dy),
      color: shadow.resolveColor(accent),
      shadows: blur > 0
          ? [Shadow(blurRadius: blur, color: shadow.resolveColor(accent))]
          : null,
    );
  }

  // Thick strokes first so thinner ones sit on top.
  final strokes = [...template.strokes]
    ..sort((a, b) => b.widthFactor.compareTo(a.widthFactor));
  for (final stroke in strokes) {
    _paintStrokeLayer(
      canvas: canvas,
      text: text,
      fontSize: fontSize,
      maxWidth: maxWidth,
      origin: origin,
      color: stroke.resolveColor(accent),
      width: (fontSize * stroke.widthFactor).clamp(1.0, 40.0),
    );
  }

  _paintFillLayer(
    canvas: canvas,
    text: text,
    fontSize: fontSize,
    maxWidth: maxWidth,
    origin: origin,
    color: fillColor,
  );

  metricsPainter.dispose();
}

/// Paints the style background and text the same way in preview and export.
void paintOverlayTextLayer({
  required Canvas canvas,
  required TextOverlay overlay,
  required OverlayBox box,
  required double frameWidth,
  required double frameHeight,
}) {
  final template = resolveOverlayTemplate(overlay);
  final fillColor = template.resolveFill(overlay.color);
  final metricsPainter = createOverlayTextPainter(
    text: overlay.text,
    style: _baseTextStyle(fontSize: box.fontSize, color: fillColor),
    maxWidth: box.width,
  );
  final origin = overlayTextOrigin(
    painter: metricsPainter,
    box: box,
    frameWidth: frameWidth,
    frameHeight: frameHeight,
  );
  metricsPainter.dispose();

  paintTextStyleTemplate(
    canvas: canvas,
    text: overlay.text,
    accent: overlay.color,
    fontSize: box.fontSize,
    maxWidth: box.width,
    origin: origin,
    template: template,
  );
}

/// Preview widget that paints overlay text the same way as export.
class OverlayTextDisplay extends StatelessWidget {
  const OverlayTextDisplay({
    super.key,
    required this.text,
    required this.color,
    required this.fontSize,
    required this.maxWidth,
    required this.template,
    this.hintColor,
  });

  final String text;
  final Color color;
  final double fontSize;
  final double maxWidth;
  final TextStyleTemplate template;
  final Color? hintColor;

  @override
  Widget build(BuildContext context) {
    final fill = hintColor ?? template.resolveFill(color);
    final probe = createOverlayTextPainter(
      text: text,
      style: _baseTextStyle(fontSize: fontSize, color: fill),
      maxWidth: maxWidth,
    );
    final size = Size(probe.width, probe.height);
    probe.dispose();

    return CustomPaint(
      size: size,
      painter: _OverlayTextDisplayPainter(
        text: text,
        color: color,
        fontSize: fontSize,
        maxWidth: maxWidth,
        template: template,
        hintColor: hintColor,
      ),
    );
  }
}

class _OverlayTextDisplayPainter extends CustomPainter {
  _OverlayTextDisplayPainter({
    required this.text,
    required this.color,
    required this.fontSize,
    required this.maxWidth,
    required this.template,
    this.hintColor,
  });

  final String text;
  final Color color;
  final double fontSize;
  final double maxWidth;
  final TextStyleTemplate template;
  final Color? hintColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (hintColor != null) {
      _paintFillLayer(
        canvas: canvas,
        text: text,
        fontSize: fontSize,
        maxWidth: maxWidth,
        origin: Offset.zero,
        color: hintColor!,
      );
      return;
    }

    paintTextStyleTemplate(
      canvas: canvas,
      text: text,
      accent: color,
      fontSize: fontSize,
      maxWidth: maxWidth,
      origin: Offset.zero,
      template: template,
    );
  }

  @override
  bool shouldRepaint(covariant _OverlayTextDisplayPainter oldDelegate) {
    return oldDelegate.text != text ||
        oldDelegate.color != color ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.maxWidth != maxWidth ||
        oldDelegate.template.id != template.id ||
        oldDelegate.hintColor != hintColor;
  }
}
