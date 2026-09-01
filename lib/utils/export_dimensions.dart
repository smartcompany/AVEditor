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

  /// Intermediate scale dimensions fed to FFmpeg before the centre crop.
  final int scaleWidth;
  final int scaleHeight;
}

int _even(int value) {
  final rounded = value.round();
  return rounded.isOdd ? rounded - 1 : rounded;
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
