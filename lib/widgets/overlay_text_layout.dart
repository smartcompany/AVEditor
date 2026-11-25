import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:aveditor/models/text_composition.dart';
import 'package:aveditor/models/text_entrance_animation.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/services/text_pack_image_cache.dart';
import 'package:aveditor/services/text_template_pack_service.dart';
import 'package:aveditor/widgets/nine_slice_image.dart';
import 'package:aveditor/widgets/overlay_fonts.dart';
import 'package:aveditor/widgets/overlay_geometry.dart';
import 'package:aveditor/widgets/text_composition_paint.dart';
import 'package:aveditor/widgets/text_entrance.dart';
import 'package:flutter/material.dart';

/// Soft floor so a single glyph still has a grab target; chrome hugs text.
const double minOverlayBoxWidth = 32;
const double minOverlayBoxHeight = 32;
const double maxOverlayBoxWidth = kOverlayFrameWidth * 1.3;
const double maxOverlayBoxHeight = kOverlayFrameHeight * 1.3;

/// Used when measuring an empty overlay so the box stays wide enough for a
/// short horizontal placeholder — not one glyph that forces vertical wrap.
const String kEmptyOverlayLayoutSample = '탭 해서 텍스트 입력';

/// Bundled font used for overlay text (DM Sans — not an Apple system face).
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
      return accent.withValues(alpha: 0.55);
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
      return const TextStyleTemplate(
        id: 'basic_box_dim',
        label: 'Dim',
        fillArgb: 0xFFFFFFFF,
        fillUseAccent: false,
        lineBackground: TextStyleLineBackground(
          useAccent: true,
          opacity: 0.55,
          padHFactor: 0.28,
          padVFactor: 0.16,
          radiusFactor: 0.2,
        ),
      );
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

/// Paints one background strip per line (capsule or CapCut-like brush paper).
void paintOverlayLineBackgrounds({
  required Canvas canvas,
  required TextPainter painter,
  required Offset origin,
  required Color background,
  required double fontSize,
  double padHFactor = 0.22,
  double padVFactor = 0.14,
  double radiusFactor = 0.18,
  TextStyleLineShape shape = TextStyleLineShape.capsule,
  double shadowOpacity = 0,
  double shadowBlurFactor = 0.12,
  TextStyleLineBackground? lineBackground,
  Set<int>? visibleLineIndexes,
}) {
  if (background.a <= 0 && !(lineBackground?.hasUnderlayImage ?? false)) {
    return;
  }

  final padH = fontSize * padHFactor;
  final padV = fontSize * padVFactor;
  final lines = painter.computeLineMetrics();
  var lineIndex = 0;

  for (final line in lines) {
    final include =
        visibleLineIndexes == null || visibleLineIndexes.contains(lineIndex);
    final index = lineIndex;
    lineIndex++;
    if (!include) continue;

    final ink = overlayLineInkY(
      painter: painter,
      lines: lines,
      lineIndex: index,
    );
    final rect = Rect.fromLTWH(
      origin.dx + line.left - padH,
      origin.dy + ink.top - padV,
      line.width + padH * 2,
      (ink.bottom - ink.top) + padV * 2,
    );
    if (shape == TextStyleLineShape.brush) {
      _paintBrushLineBackground(
        canvas: canvas,
        rect: rect,
        color: background,
        fontSize: fontSize,
        shadowOpacity: shadowOpacity,
        shadowBlurFactor: shadowBlurFactor,
        lineBackground: lineBackground,
        lineIndex: index,
      );
    } else {
      final radius = Radius.circular((fontSize * radiusFactor).clamp(4.0, 12.0));
      if (shadowOpacity > 0) {
        final shadowPaint = Paint()
          ..color = const Color(0xFF000000).withValues(alpha: shadowOpacity)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            (fontSize * shadowBlurFactor).clamp(1.0, 24.0),
          );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect.translate(0, fontSize * 0.04), radius),
          shadowPaint,
        );
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, radius),
        Paint()..color = background,
      );
    }
  }
}

/// CapCut journal strip: asset nine-slice when available, else procedural path.
void _paintBrushLineBackground({
  required Canvas canvas,
  required Rect rect,
  required Color color,
  required double fontSize,
  required double shadowOpacity,
  required double shadowBlurFactor,
  TextStyleLineBackground? lineBackground,
  int lineIndex = 0,
}) {
  final key = lineBackground?.underlayKeyForLine(lineIndex);
  if (key != null) {
    // Kick decode; when ready cache notifies listeners → preview repaints.
    unawaited(TextPackImageCache.instance.ensure(key));
    final grainKey = lineBackground?.grainAsset;
    if (grainKey != null && grainKey.isNotEmpty) {
      unawaited(TextPackImageCache.instance.ensure(grainKey));
    }
    final image = TextPackImageCache.instance[key];
    if (image != null) {
      _paintUnderlayStrip(
        canvas: canvas,
        rect: rect,
        image: image,
        fontSize: fontSize,
        shadowOpacity: shadowOpacity,
        shadowBlurFactor: shadowBlurFactor,
        nineSlice: NineSliceInsets.fromJson(
          lineBackground?.nineSlice == null
              ? null
              : Map<String, dynamic>.from(lineBackground!.nineSlice!),
        ),
        grainKey: grainKey,
        opacity: color.a.clamp(0.0, 1.0),
      );
      return;
    }
  }

  final path = _tornPaperPath(rect);
  if (shadowOpacity > 0) {
    final shadowPaint = Paint()
      ..color = const Color(0xFF000000).withValues(alpha: shadowOpacity)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        (fontSize * shadowBlurFactor).clamp(2.0, 28.0),
      );
    canvas.save();
    canvas.translate(0, fontSize * 0.045);
    canvas.drawPath(path, shadowPaint);
    canvas.restore();
  }

  // Soft fringe so edges read as brush / torn paper, not hard vectors.
  final fringe = Paint()
    ..color = color.withValues(alpha: (color.a * 0.55).clamp(0.0, 1.0))
    ..maskFilter = MaskFilter.blur(
      BlurStyle.normal,
      (fontSize * 0.08).clamp(1.2, 10.0),
    );
  canvas.drawPath(path, fringe);
  canvas.drawPath(path, Paint()..color = color);
}

void _paintUnderlayStrip({
  required Canvas canvas,
  required Rect rect,
  required ui.Image image,
  required double fontSize,
  required double shadowOpacity,
  required double shadowBlurFactor,
  required NineSliceInsets nineSlice,
  String? grainKey,
  double opacity = 1,
}) {
  if (shadowOpacity > 0) {
    final shadowPaint = Paint()
      ..color = const Color(0xFF000000).withValues(alpha: shadowOpacity * 0.85)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        (fontSize * shadowBlurFactor).clamp(2.0, 28.0),
      );
    // Approximate paper silhouette for soft drop (image alpha is expensive).
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.translate(0, fontSize * 0.045).inflate(-fontSize * 0.04),
        Radius.circular(fontSize * 0.12),
      ),
      shadowPaint,
    );
  }
  paintNineSliceImage(
    canvas: canvas,
    image: image,
    dst: rect,
    insets: nineSlice,
    opacity: opacity,
  );
  final grain = grainKey == null ? null : TextPackImageCache.instance[grainKey];
  if (grain != null) {
    final paint = Paint()
      ..isAntiAlias = true
      ..filterQuality = FilterQuality.medium
      ..blendMode = BlendMode.softLight
      ..color = const Color.fromRGBO(255, 255, 255, 0.35);
    // Tile grain lightly over the strip.
    const tile = 96.0;
    for (var x = rect.left; x < rect.right; x += tile) {
      for (var y = rect.top; y < rect.bottom; y += tile) {
        final w = (rect.right - x).clamp(0.0, tile);
        final h = (rect.bottom - y).clamp(0.0, tile);
        if (w <= 0 || h <= 0) continue;
        canvas.drawImageRect(
          grain,
          Rect.fromLTWH(0, 0, w, h),
          Rect.fromLTWH(x, y, w, h),
          paint,
        );
      }
    }
  }
}

/// Deterministic irregular strip path (stable across frames / export).
Path _tornPaperPath(Rect rect) {
  final h = rect.height;
  final w = rect.width;
  final seed = (rect.left * 0.13 + rect.top * 0.07).abs();
  double n(double t, double a, double f, double p) =>
      math.sin((t + seed) * f * math.pi * 2 + p) * a;

  final path = Path();
  final leftInset = h * 0.08;
  final rightInset = h * 0.1;
  final topAmp = h * 0.16;
  final botAmp = h * 0.14;

  // Jagged left cap.
  path.moveTo(rect.left + leftInset, rect.top + h * 0.42);
  path.quadraticBezierTo(
    rect.left - h * 0.04,
    rect.top + h * 0.18 + n(0.1, topAmp * 0.4, 1.7, 0.4),
    rect.left + leftInset * 0.6,
    rect.top + n(0.15, topAmp, 2.1, 0.2),
  );

  // Wavy top edge left → right.
  const steps = 10;
  for (var i = 1; i <= steps; i++) {
    final t = i / steps;
    final x = rect.left + leftInset + (w - leftInset - rightInset) * t;
    final y = rect.top + n(t, topAmp, 2.4, 0.6) + n(t, topAmp * 0.35, 5.1, 1.3);
    path.lineTo(x, y);
  }

  // Jagged right cap.
  path.quadraticBezierTo(
    rect.right + h * 0.05,
    rect.top + h * 0.35 + n(0.9, botAmp * 0.5, 1.9, 2.1),
    rect.right - rightInset * 0.35,
    rect.bottom - h * 0.28 + n(1.0, botAmp * 0.3, 2.2, 0.8),
  );
  path.quadraticBezierTo(
    rect.right + h * 0.02,
    rect.bottom - h * 0.08,
    rect.right - rightInset,
    rect.bottom + n(1.05, botAmp, 2.0, 1.7),
  );

  // Wavy bottom edge right → left.
  for (var i = steps - 1; i >= 0; i--) {
    final t = i / steps;
    final x = rect.left + leftInset + (w - leftInset - rightInset) * t;
    final y =
        rect.bottom + n(t, botAmp, 2.2, 2.4) + n(t, botAmp * 0.4, 4.6, 0.9);
    path.lineTo(x, y);
  }

  path.quadraticBezierTo(
    rect.left - h * 0.03,
    rect.bottom - h * 0.25,
    rect.left + leftInset,
    rect.top + h * 0.42,
  );
  path.close();
  return path;
}

TextStyle _baseTextStyle({
  required double fontSize,
  String? fontFamily,
  Color? color,
  Paint? foreground,
  List<Shadow>? shadows,
}) {
  final base = TextStyle(
    fontFamily: overlayFontFamily,
    color: foreground == null ? color : null,
    fontSize: fontSize,
    fontWeight: FontWeight.w700,
    // 1.0 keeps ascent/descent tight. 1.15 added leading mostly under the
    // baseline, so line backgrounds looked bottom-heavy around the glyphs.
    height: 1.0,
    foreground: foreground,
    shadows: shadows,
  );
  return OverlayFonts.resolve(fontFamily, base);
}

/// Fill layer for overlay text (basic style path / editing field).
TextStyle overlayTextFillStyle({
  required Color color,
  required double fontSize,
  TextOverlayStyle style = TextOverlayStyle.plain,
  String? fontFamily,
}) {
  final fill = overlayTextFillColor(style: style, accent: color);
  if (style == TextOverlayStyle.plain) {
    return _baseTextStyle(
      fontSize: fontSize,
      fontFamily: fontFamily,
      color: fill,
      shadows: const [Shadow(blurRadius: 8, color: Color(0x8A000000))],
    );
  }
  return _baseTextStyle(
    fontSize: fontSize,
    fontFamily: fontFamily,
    color: fill,
  );
}

/// Stroke layer for outline mode.
TextStyle overlayTextStrokeStyle({
  required Color color,
  required double fontSize,
  double? width,
  String? fontFamily,
}) {
  return _baseTextStyle(
    fontSize: fontSize,
    fontFamily: fontFamily,
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
  String? fontFamily,
}) {
  return overlayTextFillStyle(
    color: color,
    fontSize: fontSize,
    style: style,
    fontFamily: fontFamily,
  );
}

TextPainter createOverlayTextPainter({
  required String text,
  required TextStyle style,
  required double maxWidth,
  TextAlign textAlign = TextAlign.center,
}) {
  return TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: textAlign,
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
    textHeightBehavior: const TextHeightBehavior(
      applyHeightToFirstAscent: false,
      applyHeightToLastDescent: false,
    ),
  )..layout(maxWidth: maxWidth);
}

/// Prefer tight glyph ink over font ascent/descent so equal [padV] reads as
/// equal margin above/below the letters (many faces leave empty descent).
({double top, double bottom}) overlayLineInkY({
  required TextPainter painter,
  required List<ui.LineMetrics> lines,
  required int lineIndex,
}) {
  final line = lines[lineIndex];
  final metricsTop = line.baseline - line.ascent;
  final metricsBottom = line.baseline + line.descent;
  final plain = painter.text?.toPlainText() ?? '';
  if (plain.isEmpty) {
    return (top: metricsTop, bottom: metricsBottom);
  }
  final boxes = painter.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: plain.length),
    boxHeightStyle: ui.BoxHeightStyle.tight,
    boxWidthStyle: ui.BoxWidthStyle.tight,
  );
  double? inkTop;
  double? inkBottom;
  for (final box in boxes) {
    final mid = (box.top + box.bottom) / 2;
    if (_lineIndexForY(lines, mid) != lineIndex) continue;
    inkTop = inkTop == null ? box.top : math.min(inkTop, box.top);
    inkBottom =
        inkBottom == null ? box.bottom : math.max(inkBottom, box.bottom);
  }
  if (inkTop == null || inkBottom == null || inkBottom <= inkTop) {
    return (top: metricsTop, bottom: metricsBottom);
  }
  return (top: inkTop, bottom: inkBottom);
}

/// Lays text out exactly the way the preview's centred [Text] does.
TextPainter layoutOverlayText({
  required String text,
  required Color color,
  required double fontSize,
  required double maxWidth,
  TextOverlayStyle style = TextOverlayStyle.plain,
  String? fontFamily,
  TextAlign textAlign = TextAlign.center,
}) {
  return createOverlayTextPainter(
    text: text,
    style: overlayTextFillStyle(
      color: color,
      fontSize: fontSize,
      style: style,
      fontFamily: fontFamily,
    ),
    maxWidth: maxWidth,
    textAlign: textAlign,
  );
}

/// Resolves [overlay] into a frame of [frameWidth] x [frameHeight] pixels.
///
/// Text: box hugs the glyphs (including pack brush / stroke pads).
/// Stickers: use stored [TextOverlay.boxWidth]/[TextOverlay.boxHeight] so
/// selection chrome matches the GIF bounds (not the Giphy title string).
OverlayBox overlayBoxForFrame(
  TextOverlay overlay, {
  required double frameWidth,
}) {
  final scale = frameWidth / kOverlayFrameWidth;
  if (overlay.isSticker) {
    return OverlayBox(
      width: overlay.boxWidth * scale,
      height: overlay.boxHeight * scale,
      fontSize: overlay.fontSize * scale,
      offset: overlay.offset,
      rotation: overlay.rotation,
    );
  }
  final fitted = measureFittedOverlayBox(
    text: overlay.text,
    fontSize: overlay.fontSize,
    fontFamily: overlay.fontFamily,
    textAlign: overlay.textAlign,
    template: resolveOverlayTemplate(overlay),
    packItemId: overlay.packItemId,
  );
  return OverlayBox(
    width: fitted.width * scale,
    height: fitted.height * scale,
    fontSize: overlay.fontSize * scale,
    offset: overlay.offset,
    rotation: overlay.rotation,
  );
}

/// Horizontal padding around glyphs for line backgrounds / strokes / brush.
double overlayTextPadH({
  required double fontSize,
  TextStyleTemplate? template,
}) {
  final strokePad = overlayStrokeWidth(fontSize) * 0.55;
  final softPad = fontSize * 0.06;
  final lineBg = template?.lineBackground;
  final linePadH = lineBg == null ? 0.0 : fontSize * lineBg.padHFactor;
  final brushBleed = lineBg?.shape == TextStyleLineShape.brush
      ? fontSize * 0.2
      : 0.0;
  return (strokePad + softPad + linePadH + brushBleed).clamp(2.0, 80.0);
}

/// Vertical padding around glyphs for line backgrounds / strokes / brush.
double overlayTextPadV({
  required double fontSize,
  TextStyleTemplate? template,
}) {
  final strokePad = overlayStrokeWidth(fontSize) * 0.55;
  final softPad = fontSize * 0.06;
  final lineBg = template?.lineBackground;
  final linePadV = lineBg == null ? 0.0 : fontSize * lineBg.padVFactor;
  final brushBleed = lineBg?.shape == TextStyleLineShape.brush
      ? fontSize * 0.2
      : 0.0;
  return (strokePad + softPad + linePadV + brushBleed).clamp(2.0, 80.0);
}

/// Frame-pixel size that tightly wraps the laid-out text.
///
/// Empty text uses a short horizontal placeholder so the selection box stays
/// wide enough for the on-canvas hint (not one glyph stacked vertically).
/// Multi-slot packs use [measureTextCompositionSize] so chrome hugs bubbles.
Size measureFittedOverlayBox({
  required String text,
  required double fontSize,
  String? fontFamily,
  TextAlign textAlign = TextAlign.center,
  double maxWidth = maxOverlayBoxWidth,
  TextStyleTemplate? template,
  String? emptyPlaceholder,
  String? packItemId,
}) {
  final trimmed = text.trim();
  final sample = trimmed.isEmpty
      ? (emptyPlaceholder?.trim().isNotEmpty == true
            ? emptyPlaceholder!.trim()
            : kEmptyOverlayLayoutSample)
      : text;

  final pack = TextTemplatePackService.instance.itemById(packItemId);
  final composition = pack?.composition;
  if (composition != null && composition.slots.isNotEmpty) {
    final size = measureTextCompositionSize(
      composition: composition,
      text: sample,
      fontSize: fontSize,
      maxWidth: maxWidth,
      fallbackStyle: template ?? pack!.style,
      fontFamily: fontFamily,
    );
    // Small chrome pad so magenta handles clear bubble edges.
    const chromePad = 8.0;
    return Size(
      (size.width + chromePad * 2).clamp(minOverlayBoxWidth, maxOverlayBoxWidth),
      (size.height + chromePad * 2)
          .clamp(minOverlayBoxHeight, maxOverlayBoxHeight),
    );
  }

  final padH = overlayTextPadH(fontSize: fontSize, template: template);
  final padV = overlayTextPadV(fontSize: fontSize, template: template);
  final innerMax = (maxWidth - padH * 2).clamp(fontSize, maxWidth);

  // Prefer a single horizontal line; only wrap if we exceed the frame budget.
  final painter = createOverlayTextPainter(
    text: sample,
    style: _baseTextStyle(
      fontSize: fontSize,
      fontFamily: fontFamily,
      color: const Color(0xFFFFFFFF),
    ),
    maxWidth: maxOverlayBoxWidth,
    textAlign: textAlign,
  );
  if (painter.width > innerMax) {
    painter.layout(maxWidth: innerMax);
  }
  final width =
      (painter.width + padH * 2).clamp(minOverlayBoxWidth, maxOverlayBoxWidth);
  final height =
      (painter.height + padV * 2).clamp(minOverlayBoxHeight, maxOverlayBoxHeight);
  painter.dispose();
  return Size(width.toDouble(), height.toDouble());
}

/// Returns [overlay] with [TextOverlay.boxWidth]/[TextOverlay.boxHeight] fitted
/// to the current text and font size (center / offset unchanged).
TextOverlay fitOverlayBoxToText(
  TextOverlay overlay, {
  String? emptyPlaceholder,
}) {
  if (overlay.isSticker) return overlay;
  final size = measureFittedOverlayBox(
    text: overlay.text,
    fontSize: overlay.fontSize,
    fontFamily: overlay.fontFamily,
    textAlign: overlay.textAlign,
    template: resolveOverlayTemplate(overlay),
    emptyPlaceholder: emptyPlaceholder,
    packItemId: overlay.packItemId,
  );
  if ((overlay.boxWidth - size.width).abs() < 0.5 &&
      (overlay.boxHeight - size.height).abs() < 0.5) {
    return overlay;
  }
  return overlay.copyWith(boxWidth: size.width, boxHeight: size.height);
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
  String? fontFamily,
  TextAlign textAlign = TextAlign.center,
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
    style: _baseTextStyle(
      fontSize: fontSize,
      fontFamily: fontFamily,
      foreground: paint,
    ),
    maxWidth: maxWidth,
    textAlign: textAlign,
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
  String? fontFamily,
  TextAlign textAlign = TextAlign.center,
  List<Shadow>? shadows,
  Shader? fillShader,
}) {
  final Paint? foreground = fillShader == null
      ? null
      : (Paint()
          ..shader = fillShader
          ..style = PaintingStyle.fill);
  final painter = createOverlayTextPainter(
    text: text,
    style: _baseTextStyle(
      fontSize: fontSize,
      fontFamily: fontFamily,
      color: foreground == null ? color : null,
      foreground: foreground,
      shadows: shadows,
    ),
    maxWidth: maxWidth,
    textAlign: textAlign,
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
  String? fontFamily,
  TextAlign textAlign = TextAlign.center,
  TextEntranceState? entrance,
}) {
  final state = entrance ?? TextEntranceState.fullyVisible;
  if (state.isInvisible) return;

  final crawl = state.hasCrawlTransform;
  final layerXform = state.hasLayerTransform ||
      (state.layerScale - 1).abs() > 0.001 ||
      state.glowPulse != 1.0;
  if (crawl || layerXform) {
    canvas.save();
  }
  if (crawl) {
    // Keep perspective on an identity matrix (setEntry after translate skews
    // the vanishing point sideways — crawl looked yawed left). Pivot at the
    // top-center so scroll goes bottom → top into the distance.
    final pivotX = origin.dx + maxWidth / 2;
    final pivotY = origin.dy;
    canvas.translate(pivotX, pivotY);
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, state.layerPerspective)
      ..rotateX(state.layerTilt);
    canvas.transform(matrix.storage);
    canvas.translate(-pivotX, -pivotY + state.layerScroll);
  }
  if (layerXform && !crawl) {
    final pivotX = origin.dx + maxWidth / 2;
    final pivotY = origin.dy + fontSize * 0.5;
    canvas.translate(pivotX + state.layerDx, pivotY + state.layerDy);
    canvas.scale(state.layerScale);
    canvas.translate(-pivotX, -pivotY);
  }

  void paintStatic({required double opacity, required Offset paintOrigin}) {
    if (opacity <= 0.01) return;
    final fillColor = template.resolveFill(accent).withValues(
      alpha: (template.resolveFill(accent).a * opacity).clamp(0.0, 1.0),
    );
    final metricsPainter = createOverlayTextPainter(
      text: text,
      style: _baseTextStyle(
        fontSize: fontSize,
        fontFamily: fontFamily,
        color: fillColor,
      ),
      maxWidth: maxWidth,
      textAlign: textAlign,
    );

    final lineBg = template.lineBackground;
    if (lineBg != null) {
      paintOverlayLineBackgrounds(
        canvas: canvas,
        painter: metricsPainter,
        origin: paintOrigin,
        background: lineBg.resolveColor(accent).withValues(
          alpha: (lineBg.resolveColor(accent).a * opacity).clamp(0.0, 1.0),
        ),
        fontSize: fontSize,
        padHFactor: lineBg.padHFactor,
        padVFactor: lineBg.padVFactor,
        radiusFactor: lineBg.radiusFactor,
        shape: lineBg.shape,
        shadowOpacity: lineBg.shadowOpacity * opacity,
        shadowBlurFactor: lineBg.shadowBlurFactor,
        lineBackground: lineBg,
      );
    }

    final glow = template.glow;
    if (glow != null) {
      final glowColor = glow.resolveColor(accent);
      final pulse = state.glowPulse.clamp(0.15, 1.6);
      _paintStrokeLayer(
        canvas: canvas,
        text: text,
        fontSize: fontSize,
        maxWidth: maxWidth,
        origin: paintOrigin,
        color: glowColor.withValues(
          alpha: (glowColor.a * opacity * pulse).clamp(0.0, 1.0),
        ),
        width: (fontSize * glow.widthFactor * pulse).clamp(1.0, 48.0),
        fontFamily: fontFamily,
        textAlign: textAlign,
        blur: (fontSize * glow.blurFactor * pulse).clamp(1.0, 64.0),
      );
    }

    final shadow = template.shadow;
    if (shadow != null) {
      final dx = fontSize * shadow.dxFactor;
      final dy = fontSize * shadow.dyFactor;
      final blur = fontSize * shadow.blurFactor;
      final shadowColor = shadow.resolveColor(accent);
      _paintFillLayer(
        canvas: canvas,
        text: text,
        fontSize: fontSize,
        maxWidth: maxWidth,
        origin: paintOrigin + Offset(dx, dy),
        color: shadowColor.withValues(
          alpha: (shadowColor.a * opacity).clamp(0.0, 1.0),
        ),
        fontFamily: fontFamily,
        textAlign: textAlign,
        shadows: blur > 0
            ? [
                Shadow(
                  blurRadius: blur,
                  color: shadowColor.withValues(
                    alpha: (shadowColor.a * opacity).clamp(0.0, 1.0),
                  ),
                ),
              ]
            : null,
      );
    }

    final strokes = [...template.strokes]
      ..sort((a, b) => b.widthFactor.compareTo(a.widthFactor));
    for (final stroke in strokes) {
      final strokeColor = stroke.resolveColor(accent);
      _paintStrokeLayer(
        canvas: canvas,
        text: text,
        fontSize: fontSize,
        maxWidth: maxWidth,
        origin: paintOrigin,
        color: strokeColor.withValues(
          alpha: (strokeColor.a * opacity).clamp(0.0, 1.0),
        ),
        width: (fontSize * stroke.widthFactor).clamp(1.0, 40.0),
        fontFamily: fontFamily,
        textAlign: textAlign,
      );
    }

    _paintFillLayer(
      canvas: canvas,
      text: text,
      fontSize: fontSize,
      maxWidth: maxWidth,
      origin: paintOrigin,
      color: fillColor,
      fontFamily: fontFamily,
      textAlign: textAlign,
      fillShader: () {
        final gradient = template.fillGradient;
        if (gradient == null) return null;
        return gradient.createShader(
          Rect.fromLTWH(
            paintOrigin.dx,
            paintOrigin.dy,
            metricsPainter.width,
            metricsPainter.height,
          ),
          accent: fillColor,
        );
      }(),
    );

    metricsPainter.dispose();
  }

  if (!state.perGlyph || state.glyphs.isEmpty) {
    final dy = (layerXform && !crawl) ? 0.0 : state.layerDy;
    final dx = (layerXform && !crawl) ? 0.0 : state.layerDx;
    void paintOnce({required Offset shift, required double op}) {
      if (state.layerBlur > 0.5) {
        canvas.saveLayer(
          Rect.fromLTWH(
            origin.dx - fontSize,
            origin.dy - fontSize,
            maxWidth + fontSize * 2,
            fontSize * 8,
          ),
          Paint()
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: state.layerBlur,
              sigmaY: state.layerBlur,
            ),
        );
      }
      paintStatic(
        opacity: op,
        paintOrigin: origin + Offset(dx, dy) + shift,
      );
      if (state.layerBlur > 0.5) canvas.restore();
    }

    if (state.rgbOffset.abs() > 0.5) {
      final o = state.rgbOffset;
      paintOnce(shift: Offset(-o, 0), op: state.layerOpacity * 0.55);
      paintOnce(shift: Offset(o, 0), op: state.layerOpacity * 0.55);
      paintOnce(shift: Offset.zero, op: state.layerOpacity);
    } else {
      paintOnce(shift: Offset.zero, op: state.layerOpacity);
    }
    if (crawl || layerXform) canvas.restore();
    return;
  }

  // Per-grapheme reveal: layout full string, paint visible chars in place.
  final fillColor = template.resolveFill(accent);
  final metricsPainter = createOverlayTextPainter(
    text: text,
    style: _baseTextStyle(
      fontSize: fontSize,
      fontFamily: fontFamily,
      color: fillColor,
    ),
    maxWidth: maxWidth,
    textAlign: textAlign,
  );

  final graphemes = text.characters.toList(growable: false);
  final lines = metricsPainter.computeLineMetrics();
  // Per line: leftmost / rightmost extent of revealed glyphs (painter space).
  final lineLeft = <int, double>{};
  final lineRight = <int, double>{};

  var utf16 = 0;
  for (var i = 0; i < graphemes.length; i++) {
    final g = graphemes[i];
    final opacity =
        i < state.glyphs.length ? state.glyphs[i].opacity : 1.0;
    if (opacity > 0.01) {
      final caret = metricsPainter.getOffsetForCaret(
        TextPosition(offset: utf16),
        Rect.zero,
      );
      var lineIdx = _lineIndexForY(lines, caret.dy);
      var left = caret.dx;
      var right = caret.dx + fontSize * 0.55;
      final boxes = metricsPainter.getBoxesForSelection(
        TextSelection(
          baseOffset: utf16,
          extentOffset: utf16 + g.length,
        ),
      );
      if (boxes.isNotEmpty) {
        left = boxes.map((b) => b.left).reduce(math.min);
        right = boxes.map((b) => b.right).reduce(math.max);
        final midY = (boxes.first.top + boxes.first.bottom) / 2;
        lineIdx = _lineIndexForY(lines, midY);
      }
      lineLeft[lineIdx] = math.min(lineLeft[lineIdx] ?? left, left);
      lineRight[lineIdx] = math.max(lineRight[lineIdx] ?? right, right);
    }
    utf16 += g.length;
  }

  final lineBg = template.lineBackground;
  if (lineBg != null && lineRight.isNotEmpty) {
    _paintGrowingLineBackgrounds(
      canvas: canvas,
      painter: metricsPainter,
      lines: lines,
      origin: origin,
      lineLeft: lineLeft,
      lineRight: lineRight,
      background: lineBg.resolveColor(accent),
      fontSize: fontSize,
      padHFactor: lineBg.padHFactor,
      padVFactor: lineBg.padVFactor,
      radiusFactor: lineBg.radiusFactor,
      shape: lineBg.shape,
      shadowOpacity: lineBg.shadowOpacity,
      shadowBlurFactor: lineBg.shadowBlurFactor,
      lineBackground: lineBg,
    );
  }

  utf16 = 0;
  for (var i = 0; i < graphemes.length; i++) {
    final g = graphemes[i];
    final glyph = i < state.glyphs.length
        ? state.glyphs[i]
        : const TextEntranceGlyph(opacity: 1);
    final nextUtf = utf16 + g.length;
    if (glyph.isVisible && g.trim().isNotEmpty) {
      final caret = metricsPainter.getOffsetForCaret(
        TextPosition(offset: utf16),
        Rect.zero,
      );
      final charOrigin =
          origin + caret + Offset(glyph.dx, glyph.dy);
      final needsGlyphXform =
          (glyph.scale - 1).abs() > 0.01 || glyph.rotation.abs() > 0.01;
      if (needsGlyphXform) {
        canvas.save();
        canvas.translate(charOrigin.dx, charOrigin.dy + fontSize * 0.5);
        canvas.rotate(glyph.rotation);
        canvas.scale(glyph.scale);
        canvas.translate(-charOrigin.dx, -(charOrigin.dy + fontSize * 0.5));
      }
      _paintStyledGrapheme(
        canvas: canvas,
        grapheme: g,
        accent: accent,
        fontSize: fontSize,
        origin: charOrigin,
        template: template,
        fontFamily: fontFamily,
        opacity: glyph.opacity,
      );
      if (needsGlyphXform) canvas.restore();
    }
    utf16 = nextUtf;
  }

  if (state.cursorVisible) {
    // Caret after the last visible glyph.
    var caretUtf = 0;
    var lastVisibleUtf = 0;
    for (var i = 0; i < graphemes.length; i++) {
      final op = i < state.glyphs.length ? state.glyphs[i].opacity : 1.0;
      caretUtf += graphemes[i].length;
      if (op > 0.01) lastVisibleUtf = caretUtf;
    }
    final caret = metricsPainter.getOffsetForCaret(
      TextPosition(offset: lastVisibleUtf),
      Rect.zero,
    );
    final cx = origin.dx + caret.dx;
    final cy = origin.dy + caret.dy;
    canvas.drawRect(
      Rect.fromLTWH(cx, cy, math.max(2.0, fontSize * 0.06), fontSize * 0.9),
      Paint()..color = fillColor,
    );
  }

  metricsPainter.dispose();
  if (crawl || layerXform) canvas.restore();
}

int _lineIndexForY(List<ui.LineMetrics> lines, double y) {
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final top = line.baseline - line.ascent;
    final bottom = line.baseline + line.descent;
    if (y >= top && y <= bottom) return i;
  }
  if (lines.isEmpty) return 0;
  // Nearest line by baseline.
  var best = 0;
  var bestDist = double.infinity;
  for (var i = 0; i < lines.length; i++) {
    final d = (y - lines[i].baseline).abs();
    if (d < bestDist) {
      bestDist = d;
      best = i;
    }
  }
  return best;
}

/// Brush/capsule strips that grow with revealed glyph extents (typewriter).
void _paintGrowingLineBackgrounds({
  required Canvas canvas,
  required TextPainter painter,
  required List<ui.LineMetrics> lines,
  required Offset origin,
  required Map<int, double> lineLeft,
  required Map<int, double> lineRight,
  required Color background,
  required double fontSize,
  required double padHFactor,
  required double padVFactor,
  required double radiusFactor,
  required TextStyleLineShape shape,
  required double shadowOpacity,
  required double shadowBlurFactor,
  TextStyleLineBackground? lineBackground,
}) {
  if (background.a <= 0) return;
  final padH = fontSize * padHFactor;
  final padV = fontSize * padVFactor;

  for (final entry in lineRight.entries) {
    final i = entry.key;
    if (i < 0 || i >= lines.length) continue;
    final line = lines[i];
    final left = lineLeft[i] ?? line.left;
    final right = entry.value;
    final width = (right - left).clamp(fontSize * 0.2, double.infinity);
    final ink = overlayLineInkY(
      painter: painter,
      lines: lines,
      lineIndex: i,
    );
    final top = origin.dy + ink.top - padV;
    final height = (ink.bottom - ink.top) + padV * 2;
    final rect = Rect.fromLTWH(
      origin.dx + left - padH,
      top,
      width + padH * 2,
      height,
    );
    if (shape == TextStyleLineShape.brush) {
      // Torn paper is one fixed piece: lay it out for the whole line (same
      // rect as the finished look) and reveal it up to the typed glyphs.
      // Regrowing the rect re-spread the torn edge, so the paper stretched.
      final fullRect = Rect.fromLTWH(
        origin.dx + line.left - padH,
        top,
        line.width + padH * 2,
        height,
      );
      final revealRight = origin.dx + right + padH;
      final clipped = revealRight < fullRect.right - 0.5;
      if (clipped) {
        canvas.save();
        canvas.clipPath(
          _tornRevealClip(
            fullRect: fullRect,
            revealRight: revealRight,
            fontSize: fontSize,
          ),
        );
      }
      _paintBrushLineBackground(
        canvas: canvas,
        rect: fullRect,
        color: background,
        fontSize: fontSize,
        shadowOpacity: shadowOpacity,
        shadowBlurFactor: shadowBlurFactor,
        lineBackground: lineBackground,
        lineIndex: i,
      );
      if (clipped) canvas.restore();
    } else {
      final radius = Radius.circular((fontSize * radiusFactor).clamp(4.0, 12.0));
      if (shadowOpacity > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect.translate(0, fontSize * 0.04), radius),
          Paint()
            ..color = const Color(0xFF000000).withValues(alpha: shadowOpacity)
            ..maskFilter = MaskFilter.blur(
              BlurStyle.normal,
              (fontSize * shadowBlurFactor).clamp(1.0, 24.0),
            ),
        );
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, radius),
        Paint()..color = background,
      );
    }
  }
}

/// Everything left of [revealRight], with a small torn (zig-zag) cut so the
/// growing end of the paper reads as ripped, not sliced. The teeth depend only
/// on y, so they stay put while the cut moves right.
Path _tornRevealClip({
  required Rect fullRect,
  required double revealRight,
  required double fontSize,
}) {
  final margin = fontSize * 2;
  final top = fullRect.top - margin;
  final bottom = fullRect.bottom + margin;
  final amp = fullRect.height * 0.07;
  const teeth = 7;
  final path = Path()
    ..moveTo(fullRect.left - margin, top)
    ..lineTo(revealRight, top)
    ..lineTo(revealRight, fullRect.top);
  for (var i = 1; i <= teeth; i++) {
    final y = fullRect.top + fullRect.height * i / teeth;
    final x = revealRight + (i.isOdd ? amp : -amp * 0.6);
    path.lineTo(x, y);
  }
  path
    ..lineTo(revealRight, bottom)
    ..lineTo(fullRect.left - margin, bottom)
    ..close();
  return path;
}

void _paintStyledGrapheme({
  required Canvas canvas,
  required String grapheme,
  required Color accent,
  required double fontSize,
  required Offset origin,
  required TextStyleTemplate template,
  String? fontFamily,
  required double opacity,
}) {
  final fill = template.resolveFill(accent).withValues(
    alpha: (template.resolveFill(accent).a * opacity).clamp(0.0, 1.0),
  );

  final glow = template.glow;
  if (glow != null) {
    final glowColor = glow.resolveColor(accent);
    _paintStrokeLayer(
      canvas: canvas,
      text: grapheme,
      fontSize: fontSize,
      maxWidth: fontSize * 4,
      origin: origin,
      color: glowColor.withValues(
        alpha: (glowColor.a * opacity).clamp(0.0, 1.0),
      ),
      width: (fontSize * glow.widthFactor).clamp(1.0, 40.0),
      fontFamily: fontFamily,
      textAlign: TextAlign.left,
      blur: (fontSize * glow.blurFactor).clamp(1.0, 48.0),
    );
  }

  final shadow = template.shadow;
  if (shadow != null) {
    final shadowColor = shadow.resolveColor(accent);
    _paintFillLayer(
      canvas: canvas,
      text: grapheme,
      fontSize: fontSize,
      maxWidth: fontSize * 4,
      origin: origin +
          Offset(fontSize * shadow.dxFactor, fontSize * shadow.dyFactor),
      color: shadowColor.withValues(
        alpha: (shadowColor.a * opacity).clamp(0.0, 1.0),
      ),
      fontFamily: fontFamily,
      textAlign: TextAlign.left,
    );
  }

  final strokes = [...template.strokes]
    ..sort((a, b) => b.widthFactor.compareTo(a.widthFactor));
  for (final stroke in strokes) {
    final strokeColor = stroke.resolveColor(accent);
    _paintStrokeLayer(
      canvas: canvas,
      text: grapheme,
      fontSize: fontSize,
      maxWidth: fontSize * 4,
      origin: origin,
      color: strokeColor.withValues(
        alpha: (strokeColor.a * opacity).clamp(0.0, 1.0),
      ),
      width: (fontSize * stroke.widthFactor).clamp(1.0, 40.0),
      fontFamily: fontFamily,
      textAlign: TextAlign.left,
    );
  }

  _paintFillLayer(
    canvas: canvas,
    text: grapheme,
    fontSize: fontSize,
    maxWidth: fontSize * 4,
    origin: origin,
    color: fill,
    fontFamily: fontFamily,
    textAlign: TextAlign.left,
  );
}

/// Paints the style background and text the same way in preview and export.
void paintOverlayTextLayer({
  required Canvas canvas,
  required TextOverlay overlay,
  required OverlayBox box,
  required double frameWidth,
  required double frameHeight,
  TextEntranceState? entrance,
}) {
  final template = resolveOverlayTemplate(overlay);
  final fillColor = template.resolveFill(overlay.color);
  final metricsPainter = createOverlayTextPainter(
    text: overlay.text,
    style: _baseTextStyle(
      fontSize: box.fontSize,
      fontFamily: overlay.fontFamily,
      color: fillColor,
    ),
    maxWidth: box.width,
    textAlign: overlay.textAlign,
  );
  final origin = overlayTextOrigin(
    painter: metricsPainter,
    box: box,
    frameWidth: frameWidth,
    frameHeight: frameHeight,
  );
  metricsPainter.dispose();

  final anim = resolveOverlayAnimation(overlay);
  final TextEntranceState resolvedEntrance;
  if (entrance != null) {
    resolvedEntrance = entrance;
  } else if (anim.isNone) {
    resolvedEntrance = TextEntranceState.fullyVisible;
  } else {
    // Export static path without an explicit progress → fully revealed.
    resolvedEntrance = evaluateTextEntrance(
      animationId: anim.id,
      animation: anim,
      text: overlay.text,
      progress: 1,
      fontSize: box.fontSize,
    );
  }

  final pack = TextTemplatePackService.instance.itemById(overlay.packItemId);
  final composition = pack?.composition;
  if (composition != null && composition.slots.isNotEmpty) {
    paintTextComposition(
      canvas: canvas,
      composition: composition,
      text: overlay.text,
      accent: overlay.color,
      fontSize: box.fontSize,
      maxWidth: box.width,
      origin: origin,
      fallbackStyle: template,
      fontFamily: overlay.fontFamily,
      entrance: resolvedEntrance,
    );
    return;
  }

  paintTextStyleTemplate(
    canvas: canvas,
    text: overlay.text,
    accent: overlay.color,
    fontSize: box.fontSize,
    maxWidth: box.width,
    origin: origin,
    template: template,
    fontFamily: overlay.fontFamily,
    textAlign: overlay.textAlign,
    entrance: resolvedEntrance,
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
    this.fontFamily,
    this.textAlign = TextAlign.center,
    this.hintColor,
    this.entrance,
    this.composition,
  });

  final String text;
  final Color color;
  final double fontSize;
  final double maxWidth;
  final TextStyleTemplate template;
  final String? fontFamily;
  final TextAlign textAlign;
  final Color? hintColor;
  final TextEntranceState? entrance;
  final TextComposition? composition;

  @override
  Widget build(BuildContext context) {
    final fill = hintColor ?? template.resolveFill(color);
    final hasComp = composition != null && composition!.slots.isNotEmpty;
    // Tight size must match paint — a crude slot-factor estimate was shorter
    // / used full maxWidth, so OverflowBox centering left empty chrome gaps.
    final Size size;
    final double paintMaxWidth;
    if (hasComp) {
      final measured = measureTextCompositionSize(
        composition: composition!,
        text: text.isEmpty ? ' ' : text,
        fontSize: fontSize,
        maxWidth: maxWidth,
        fallbackStyle: template,
        fontFamily: fontFamily,
      );
      // Keep settled layout size fixed (dashboard parity). Staged slotDy is a
      // paint-only offset — expanding height by rise made earlier lines drop
      // as the last bubble eased into place.
      size = measured;
      // Lay out bubbles against their own width so start-align packs don't
      // leave a hollow strip on the right inside a wider constraint.
      paintMaxWidth = measured.width.clamp(1.0, maxWidth);
    } else {
      final probe = createOverlayTextPainter(
        text: text,
        style: _baseTextStyle(
          fontSize: fontSize,
          fontFamily: fontFamily,
          color: fill,
        ),
        maxWidth: maxWidth,
        textAlign: textAlign,
      );
      size = Size(probe.width, probe.height);
      paintMaxWidth = maxWidth;
      probe.dispose();
    }

    return CustomPaint(
      size: size,
      painter: _OverlayTextDisplayPainter(
        text: text,
        color: color,
        fontSize: fontSize,
        maxWidth: paintMaxWidth,
        template: template,
        fontFamily: fontFamily,
        textAlign: textAlign,
        hintColor: hintColor,
        entrance: entrance,
        composition: composition,
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
    this.fontFamily,
    this.textAlign = TextAlign.center,
    this.hintColor,
    this.entrance,
    this.composition,
  }) : super(repaint: TextPackImageCache.instance);

  final String text;
  final Color color;
  final double fontSize;
  final double maxWidth;
  final TextStyleTemplate template;
  final String? fontFamily;
  final TextAlign textAlign;
  final Color? hintColor;
  final TextEntranceState? entrance;
  final TextComposition? composition;

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
        fontFamily: fontFamily,
        textAlign: textAlign,
      );
      return;
    }

    if (composition != null && composition!.slots.isNotEmpty) {
      paintTextComposition(
        canvas: canvas,
        composition: composition!,
        text: text,
        accent: color,
        fontSize: fontSize,
        maxWidth: maxWidth,
        origin: Offset.zero,
        fallbackStyle: template,
        fontFamily: fontFamily,
        entrance: entrance,
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
      fontFamily: fontFamily,
      textAlign: textAlign,
      entrance: entrance,
    );
  }

  @override
  bool shouldRepaint(covariant _OverlayTextDisplayPainter oldDelegate) {
    final a = oldDelegate.entrance;
    final b = entrance;
    return oldDelegate.text != text ||
        oldDelegate.color != color ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.maxWidth != maxWidth ||
        oldDelegate.template.id != template.id ||
        oldDelegate.fontFamily != fontFamily ||
        oldDelegate.textAlign != textAlign ||
        oldDelegate.hintColor != hintColor ||
        oldDelegate.composition != composition ||
        a?.progress != b?.progress ||
        a?.animationId != b?.animationId ||
        a?.layerOpacity != b?.layerOpacity ||
        a?.layerDy != b?.layerDy ||
        a?.layerDx != b?.layerDx ||
        a?.layerScale != b?.layerScale ||
        a?.layerBlur != b?.layerBlur ||
        a?.layerScroll != b?.layerScroll ||
        a?.layerTilt != b?.layerTilt ||
        a?.layerPerspective != b?.layerPerspective ||
        a?.rgbOffset != b?.rgbOffset ||
        a?.glowPulse != b?.glowPulse ||
        a?.cursorVisible != b?.cursorVisible ||
        a?.perGlyph != b?.perGlyph ||
        !_listEquals(a?.slotOpacity, b?.slotOpacity) ||
        !_listEquals(a?.slotDy, b?.slotDy) ||
        !_glyphsEqual(a?.glyphs, b?.glyphs);
  }
}

bool _listEquals(List<double>? a, List<double>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _glyphsEqual(List<TextEntranceGlyph>? a, List<TextEntranceGlyph>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x.opacity != y.opacity ||
        x.dx != y.dx ||
        x.dy != y.dy ||
        x.scale != y.scale ||
        x.rotation != y.rotation) {
      return false;
    }
  }
  return true;
}
