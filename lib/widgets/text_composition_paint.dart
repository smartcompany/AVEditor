import 'dart:math' as math;

import 'package:aveditor/models/text_composition.dart';
import 'package:aveditor/models/text_style_template.dart';
import 'package:aveditor/widgets/overlay_fonts.dart';
import 'package:aveditor/widgets/overlay_text_layout.dart';
import 'package:aveditor/widgets/text_entrance.dart';
import 'package:flutter/material.dart';

/// Tight size of a composition stack (slots + decorations), matching paint.
Size measureTextCompositionSize({
  required TextComposition composition,
  required String text,
  required double fontSize,
  required double maxWidth,
  required TextStyleTemplate fallbackStyle,
  String? fontFamily,
}) {
  final laid = _layoutCompositionSlots(
    composition: composition,
    text: text,
    fontSize: fontSize,
    maxWidth: maxWidth,
    fallbackStyle: fallbackStyle,
    fontFamily: fontFamily,
    layerOpacity: 1,
    slotOpacity: const [],
    slotDy: const [],
    disposePainters: true,
  );
  return Size(laid.totalW, laid.totalH);
}

/// Paints a server-driven [TextComposition] (slots + decorations).
Size paintTextComposition({
  required Canvas canvas,
  required TextComposition composition,
  required String text,
  required Color accent,
  required double fontSize,
  required double maxWidth,
  required Offset origin,
  required TextStyleTemplate fallbackStyle,
  String? fontFamily,
  TextEntranceState? entrance,
}) {
  final state = entrance ?? TextEntranceState.fullyVisible;
  if (state.isInvisible) return Size.zero;

  final laid = _layoutCompositionSlots(
    composition: composition,
    text: text,
    fontSize: fontSize,
    maxWidth: maxWidth,
    fallbackStyle: fallbackStyle,
    fontFamily: fontFamily,
    layerOpacity: state.layerOpacity,
    slotOpacity: state.slotOpacity,
    slotDy: state.slotDy,
    accent: accent,
  );
  final totalW = laid.totalW;
  final totalH = laid.totalH;
  final contentW = laid.contentW;
  final contentH = laid.contentH;
  final leftInset = laid.leftInset;
  final topInset = laid.topInset;
  final stackLeft = origin.dx + leftInset;
  final stackTop = origin.dy + topInset + state.layerDy;

  for (final s in laid.slots) {
    final x =
        stackLeft + s.dx + _alignOffset(composition.align, contentW, s.width);
    s.origin = Offset(x, stackTop + s.top + s.dy);
  }

  final slotById = {for (final s in laid.slots) s.slot.id: s};

  canvas.save();
  if (state.layerOpacity < 0.999) {
    canvas.saveLayer(
      Rect.fromLTWH(
        origin.dx - 4,
        stackTop - topInset - 4,
        totalW + 8,
        totalH + 8,
      ),
      Paint()..color = Color.fromRGBO(255, 255, 255, state.layerOpacity),
    );
  }

  for (final d in composition.decorations) {
    _paintDecoration(
      canvas: canvas,
      decoration: d,
      fontSize: fontSize,
      stackLeft: stackLeft,
      stackTop: stackTop,
      contentW: contentW,
      contentH: contentH,
      slotById: slotById,
      opacity: state.layerOpacity,
    );
  }

  for (final s in laid.slots) {
    if (s.opacity <= 0.01) {
      s.painter.dispose();
      continue;
    }
    final o = s.origin!;
    canvas.save();
    if (s.opacity < 0.999) {
      canvas.saveLayer(
        Rect.fromLTWH(o.dx - 2, o.dy - 2, s.width + 4, s.height + 4),
        Paint()..color = Color.fromRGBO(255, 255, 255, s.opacity),
      );
    }
    if (s.slot.boxFillArgb != null) {
      final rect = Rect.fromLTWH(o.dx, o.dy, s.width, s.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()..color = Color(s.slot.boxFillArgb!),
      );
      if (s.slot.boxStrokeArgb != null && s.slot.boxStrokeWidthFactor > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(2)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth =
                (s.slotFontSize * s.slot.boxStrokeWidthFactor).clamp(1.0, 12.0)
            ..color = Color(s.slot.boxStrokeArgb!),
        );
      }
    }
    s.painter.paint(canvas, Offset(o.dx + s.padH, o.dy + s.padV));
    if (s.opacity < 0.999) canvas.restore();
    canvas.restore();
    s.painter.dispose();
  }

  if (state.layerOpacity < 0.999) canvas.restore();
  canvas.restore();

  return Size(totalW, totalH);
}

class _CompositionLayout {
  const _CompositionLayout({
    required this.slots,
    required this.contentW,
    required this.contentH,
    required this.leftInset,
    required this.rightInset,
    required this.topInset,
  });

  final List<_SlotLayout> slots;
  final double contentW;
  final double contentH;
  final double leftInset;
  final double rightInset;
  final double topInset;

  double get totalW => contentW + leftInset + rightInset;
  double get totalH => contentH + topInset;
}

_CompositionLayout _layoutCompositionSlots({
  required TextComposition composition,
  required String text,
  required double fontSize,
  required double maxWidth,
  required TextStyleTemplate fallbackStyle,
  String? fontFamily,
  required double layerOpacity,
  required List<double> slotOpacity,
  required List<double> slotDy,
  Color accent = Colors.white,
  bool disposePainters = false,
}) {
  final entries = composition.entriesFor(text);
  final gap = fontSize * composition.gapFactor;
  final laid = <_SlotLayout>[];
  var contentW = 0.0;
  var contentH = 0.0;

  for (var i = 0; i < entries.length; i++) {
    final slot = entries[i].slot;
    final body = entries[i].text;
    final slotFs = (fontSize * slot.fontSizeFactor).clamp(6.0, 400.0);
    final slotOp =
        i < slotOpacity.length ? slotOpacity[i] : layerOpacity;
    final fillBase = slot.fillArgb != null
        ? Color(slot.fillArgb!)
        : (fallbackStyle.fillArgb != null
              ? Color(fallbackStyle.fillArgb!)
              : accent);
    final fill = fillBase.withValues(
      alpha: (layerOpacity * slotOp).clamp(0.0, 1.0),
    );
    final base = TextStyle(
      fontSize: slotFs,
      fontWeight: _fontWeight(slot.fontWeight),
      fontStyle: slot.italic ? FontStyle.italic : FontStyle.normal,
      letterSpacing: slot.letterSpacingEm * slotFs,
      color: fill,
      height: 1.05,
    );
    final styled = OverlayFonts.resolve(
      slot.preferredFontId ?? fontFamily ?? fallbackStyle.preferredFontId,
      base,
    );
    final painter = createOverlayTextPainter(
      text: body.isEmpty ? ' ' : body,
      style: styled,
      maxWidth: maxWidth,
      textAlign: _toAlign(slot.align),
    );
    final padH = slot.boxFillArgb != null ? slotFs * slot.boxPadHFactor : 0.0;
    final padV = slot.boxFillArgb != null ? slotFs * slot.boxPadVFactor : 0.0;
    final w = painter.width + padH * 2;
    final h = painter.height + padV * 2;
    final dx = fontSize * slot.dxFactor;
    final dy = i < slotDy.length ? slotDy[i] : 0.0;
    laid.add(
      _SlotLayout(
        slot: slot,
        painter: painter,
        slotFontSize: slotFs,
        width: w,
        height: h,
        padH: padH,
        padV: padV,
        dx: dx,
        top: contentH,
        opacity: slotOp,
        dy: dy,
      ),
    );
    contentW = math.max(contentW, w + dx.abs());
    contentH += h;
    if (i < entries.length - 1) contentH += gap;
  }

  var leftInset = 0.0;
  var rightInset = 0.0;
  var topInset = 0.0;
  for (final d in composition.decorations) {
    final thick = fontSize * d.thicknessFactor;
    final gapD = fontSize * d.gapFactor;
    switch (d.kind) {
      case TextCompDecorationKind.barV:
        if (d.attach == 'left') leftInset = math.max(leftInset, thick + gapD);
        if (d.attach == 'right') {
          rightInset = math.max(rightInset, thick + gapD);
        }
      case TextCompDecorationKind.chevronDown:
        if (d.attach == 'above') {
          topInset = math.max(topInset, fontSize * d.heightFactor + gapD);
        }
      default:
        break;
    }
  }

  if (disposePainters) {
    for (final s in laid) {
      s.painter.dispose();
    }
  }

  return _CompositionLayout(
    slots: laid,
    contentW: contentW,
    contentH: contentH,
    leftInset: leftInset,
    rightInset: rightInset,
    topInset: topInset,
  );
}

FontWeight _fontWeight(int w) {
  final stepped = ((w / 100).round().clamp(1, 9)) * 100;
  for (final fw in FontWeight.values) {
    if (fw.value == stepped) return fw;
  }
  return FontWeight.w700;
}

double _alignOffset(TextCompAlign align, double contentW, double itemW) {
  return switch (align) {
    TextCompAlign.start => 0,
    TextCompAlign.end => contentW - itemW,
    TextCompAlign.center => (contentW - itemW) / 2,
  };
}

TextAlign _toAlign(TextCompAlign a) => switch (a) {
      TextCompAlign.start => TextAlign.left,
      TextCompAlign.end => TextAlign.right,
      TextCompAlign.center => TextAlign.center,
    };

void _paintDecoration({
  required Canvas canvas,
  required TextCompDecoration decoration,
  required double fontSize,
  required double stackLeft,
  required double stackTop,
  required double contentW,
  required double contentH,
  required Map<String, _SlotLayout> slotById,
  required double opacity,
}) {
  final color = Color(decoration.colorArgb ?? 0xFFFFFFFF).withValues(
    alpha: (decoration.opacity * opacity).clamp(0.0, 1.0),
  );
  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.fill
    ..strokeCap = StrokeCap.round;

  final slot = decoration.slotId != null ? slotById[decoration.slotId!] : null;
  final thick = fontSize * decoration.thicknessFactor;
  final gap = fontSize * decoration.gapFactor;

  switch (decoration.kind) {
    case TextCompDecorationKind.barV:
      final h = contentH * decoration.lengthFactor;
      final y = stackTop + (contentH - h) / 2;
      if (decoration.attach == 'right') {
        final x = stackLeft + contentW + gap;
        canvas.drawRect(Rect.fromLTWH(x, y, thick, h), paint);
      } else {
        final x = stackLeft - gap - thick;
        canvas.drawRect(Rect.fromLTWH(x, y, thick, h), paint);
      }
    case TextCompDecorationKind.barH:
      final w = contentW * decoration.lengthFactor;
      final x = stackLeft + (contentW - w) / 2;
      final y = decoration.attach == 'above'
          ? stackTop - gap - thick
          : stackTop + contentH + gap;
      canvas.drawRect(Rect.fromLTWH(x, y, w, thick), paint);
    case TextCompDecorationKind.rule:
      final anchor = slot?.origin ?? Offset(stackLeft, stackTop);
      final aw = slot?.width ?? contentW;
      final ah = slot?.height ?? contentH;
      final w = aw * decoration.lengthFactor;
      final x = anchor.dx + (aw - w) / 2;
      final y = decoration.attach == 'above'
          ? anchor.dy - gap - thick
          : anchor.dy + ah + gap;
      paint
        ..strokeWidth = thick
        ..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(x, y), Offset(x + w, y), paint);
    case TextCompDecorationKind.slash:
      final anchor = slot?.origin ?? Offset(stackLeft, stackTop);
      final aw = slot?.width ?? contentW;
      final ah = slot?.height ?? 0;
      final w = aw * decoration.lengthFactor;
      final x = anchor.dx + (aw - w) / 2;
      final y = anchor.dy + ah + gap;
      paint
        ..strokeWidth = thick
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(x, y + thick),
        Offset(x + w, y - thick * 2),
        paint,
      );
    case TextCompDecorationKind.chevronDown:
      final aw = (slot?.width ?? contentW) * decoration.widthFactor;
      final ah = fontSize * decoration.heightFactor;
      final cx =
          (slot?.origin?.dx ?? stackLeft) + (slot?.width ?? contentW) / 2;
      final top = (slot?.origin?.dy ?? stackTop) - gap - ah;
      final path = Path()
        ..moveTo(cx - aw / 2, top)
        ..lineTo(cx, top + ah)
        ..lineTo(cx + aw / 2, top)
        ..lineTo(cx + aw / 2 - ah * 0.25, top)
        ..lineTo(cx, top + ah * 0.65)
        ..lineTo(cx - aw / 2 + ah * 0.25, top)
        ..close();
      canvas.drawPath(path, paint);
  }
}

class _SlotLayout {
  _SlotLayout({
    required this.slot,
    required this.painter,
    required this.slotFontSize,
    required this.width,
    required this.height,
    required this.padH,
    required this.padV,
    required this.dx,
    required this.top,
    this.opacity = 1,
    this.dy = 0,
  });

  final TextCompSlot slot;
  final TextPainter painter;
  final double slotFontSize;
  final double width;
  final double height;
  final double padH;
  final double padV;
  final double dx;
  final double top;
  final double opacity;
  final double dy;
  Offset? origin;
}
