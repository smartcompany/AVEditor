/// Project frame shape. [original] follows the loaded video.
enum CanvasRatio {
  original,
  vertical,
  square,
  portrait,
  wide,
}

extension CanvasRatioX on CanvasRatio {
  /// Width / height of the preview and export frame.
  double frameAspect(double sourceAspect) {
    final aspect = sourceAspect <= 0 ? 9 / 16 : sourceAspect;
    return switch (this) {
      CanvasRatio.original => aspect,
      CanvasRatio.vertical => 9 / 16,
      CanvasRatio.square => 1,
      CanvasRatio.portrait => 4 / 5,
      CanvasRatio.wide => 16 / 9,
    };
  }

  /// Shown under the ratio chip. [original] uses a localized label.
  String get ratioLabel => switch (this) {
        CanvasRatio.original => '',
        CanvasRatio.vertical => '9:16',
        CanvasRatio.square => '1:1',
        CanvasRatio.portrait => '4:5',
        CanvasRatio.wide => '16:9',
      };
}
