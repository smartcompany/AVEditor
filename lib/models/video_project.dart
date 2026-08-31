import 'package:aveditor/models/clip_trim.dart';
import 'package:aveditor/models/export_preset.dart';
import 'package:aveditor/models/text_overlay.dart';

/// In-memory edit project for a single video.
class VideoProject {
  VideoProject({
    required this.sourcePath,
    required this.duration,
    ClipTrim? trim,
    List<TextOverlay>? overlays,
    this.preset = ExportPreset.youtubeShorts,
  })  : trim = trim ?? ClipTrim(start: Duration.zero, end: duration),
        overlays = overlays ?? [];

  final String sourcePath;
  final Duration duration;
  ClipTrim trim;
  final List<TextOverlay> overlays;
  ExportPreset preset;

  Duration get trimmedDuration => trim.duration;

  VideoProject copyWith({
    ClipTrim? trim,
    List<TextOverlay>? overlays,
    ExportPreset? preset,
  }) {
    return VideoProject(
      sourcePath: sourcePath,
      duration: duration,
      trim: trim ?? this.trim,
      overlays: overlays ?? List<TextOverlay>.from(this.overlays),
      preset: preset ?? this.preset,
    );
  }
}
