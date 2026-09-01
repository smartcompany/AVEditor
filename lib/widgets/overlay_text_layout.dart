import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/widgets/overlay_geometry.dart';
import 'package:flutter/widgets.dart';

/// Bundled font used for overlay text.
///
/// Pinned rather than inherited from the theme so the preview and the exported
/// video lay out identically — theme fonts are fetched at runtime and would
/// silently change line breaking.
const String overlayFontFamily = 'OverlayText';

/// The one text style used to draw overlay text, on screen and on export.
TextStyle overlayTextStyle({
  required Color color,
  required double fontSize,
}) {
  return TextStyle(
    fontFamily: overlayFontFamily,
    color: color,
    fontSize: fontSize,
    fontWeight: FontWeight.w700,
    height: 1.15,
    shadows: const [Shadow(blurRadius: 8, color: Color(0x8A000000))],
  );
}

/// Lays text out exactly the way the preview's centred [Text] does.
///
/// Mirrors `RenderParagraph`: soft wrapping against the box width, no text
/// scaling, centre aligned.
TextPainter layoutOverlayText({
  required String text,
  required Color color,
  required double fontSize,
  required double maxWidth,
}) {
  return TextPainter(
    text: TextSpan(
      text: text,
      style: overlayTextStyle(color: color, fontSize: fontSize),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  )..layout(maxWidth: maxWidth);
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
///
/// The preview centres the paragraph inside the box, so the export must too.
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
