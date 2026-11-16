import 'dart:ui' as ui;

/// One decoded frame for the clip track filmstrip.
class TimelineFilmstripFrame {
  const TimelineFilmstripFrame({
    required this.sourceTime,
    required this.image,
    this.mediaId,
  });

  /// Local time on the media asset (or legacy master file).
  final Duration sourceTime;

  final ui.Image image;

  /// When set, paint only matches this frame to clips of the same asset.
  final String? mediaId;
}
