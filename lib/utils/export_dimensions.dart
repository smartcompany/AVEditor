/// Even width/height for the exported frame after cover-crop.
class ExportFrameSize {
  const ExportFrameSize({
    required this.width,
    required this.height,
    required this.scaleWidth,
    required this.scaleHeight,
  });

  final int width;
  final int height;

  /// Intermediate scale dimensions before the centre crop in native export.
  final int scaleWidth;
  final int scaleHeight;
}

int _even(int value) {
  final rounded = value.round();
  return rounded.isOdd ? rounded - 1 : rounded;
}

/// Output frame for [canvasAspect] (width / height).
///
/// The short side is capped at [shortSideCap]. Sources smaller than that cap
/// keep their short side when [allowUpscale] is false. The video is fitted
/// inside this frame, so a mismatched source leaves black bars.
ExportFrameSize computeCanvasFrameSize({
  required int sourceWidth,
  required int sourceHeight,
  required double canvasAspect,
  int shortSideCap = 1080,
  required bool allowUpscale,
}) {
  final aspect = canvasAspect <= 0 ? 9 / 16 : canvasAspect;
  if (sourceWidth <= 0 || sourceHeight <= 0) {
    return _frameFor(aspect, shortSideCap.toDouble());
  }

  final sourceShort = sourceWidth < sourceHeight ? sourceWidth : sourceHeight;
  var shortSide = shortSideCap.toDouble();
  if (!allowUpscale && sourceShort < shortSide) {
    shortSide = sourceShort.toDouble();
  }
  return _frameFor(aspect, shortSide);
}

ExportFrameSize _frameFor(double aspect, double shortSide) {
  final double width;
  final double height;
  if (aspect >= 1) {
    height = shortSide;
    width = shortSide * aspect;
  } else {
    width = shortSide;
    height = shortSide / aspect;
  }
  final evenW = _even(width.round()).clamp(2, 8192);
  final evenH = _even(height.round()).clamp(2, 8192);
  return ExportFrameSize(
    width: evenW,
    height: evenH,
    scaleWidth: evenW,
    scaleHeight: evenH,
  );
}

/// Cover-crops [source] into a 9:16 frame capped at [maxWidth]×[maxHeight].
///
/// When [allowUpscale] is false, sources smaller than the cap keep their native
/// pixel density instead of being blown up to 1080p.
ExportFrameSize computeExportFrameSize({
  required int sourceWidth,
  required int sourceHeight,
  required int maxWidth,
  required int maxHeight,
  required bool allowUpscale,
}) {
  if (sourceWidth <= 0 || sourceHeight <= 0) {
    return ExportFrameSize(
      width: maxWidth,
      height: maxHeight,
      scaleWidth: maxWidth,
      scaleHeight: maxHeight,
    );
  }

  final targetAspect = maxWidth / maxHeight;
  var coverScale = [
    maxWidth / sourceWidth,
    maxHeight / sourceHeight,
  ].reduce((a, b) => a > b ? a : b);

  if (!allowUpscale && coverScale > 1) {
    coverScale = 1;
  }

  final scaledW = sourceWidth * coverScale;
  final scaledH = sourceHeight * coverScale;
  final scaledAspect = scaledW / scaledH;

  late final double cropW;
  late final double cropH;
  if (scaledAspect > targetAspect) {
    cropH = scaledH;
    cropW = scaledH * targetAspect;
  } else {
    cropW = scaledW;
    cropH = scaledW / targetAspect;
  }

  return ExportFrameSize(
    width: _even(cropW.round()).clamp(2, maxWidth),
    height: _even(cropH.round()).clamp(2, maxHeight),
    scaleWidth: _even(scaledW.round()).clamp(2, maxWidth * 2),
    scaleHeight: _even(scaledH.round()).clamp(2, maxHeight * 2),
  );
}
