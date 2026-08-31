/// Short-form export targets (YouTube Shorts first).
enum ExportPreset {
  youtubeShorts,
  instagramReels,
  tiktok,
}

extension ExportPresetX on ExportPreset {
  int get width => 1080;

  int get height => 1920;

  double get aspectRatio => 9 / 16;

  /// Max duration for reliable Shorts classification.
  Duration get maxDuration => const Duration(seconds: 60);
}
