import 'dart:ui' as ui;

/// One decoded frame for the clip track filmstrip.
class TimelineFilmstripFrame {
  const TimelineFilmstripFrame({
    required this.sourceTime,
    required this.image,
  });

  final Duration sourceTime;
  final ui.Image image;
}
