import 'package:aveditor/models/clip_segment.dart';
import 'package:aveditor/models/project_music.dart';
import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/utils/clip_segment_ops.dart';
import 'package:aveditor/utils/timeline_math.dart';

/// Maps a music clip's source range onto the packed sequence timeline.
({Duration start, Duration end})? musicSequenceSpan(
  ProjectMusic music,
  List<ClipSegment> segments,
) {
  if (segments.isEmpty) {
    return (start: music.timelineStart, end: music.timelineEnd);
  }

  final exportStart = sourceTimeToExportTime(segments, music.timelineStart);
  final exportEnd = sourceTimeToExportTime(segments, music.timelineEnd);
  if (exportStart == null || exportEnd == null) return null;
  if (exportEnd < exportStart) return null;
  if (exportEnd == exportStart) {
    return (start: exportStart, end: exportStart + minMusicClipDuration);
  }
  return (start: exportStart, end: exportEnd);
}

/// Packed timeline length: video plus any music/text that extends past EOF.
Duration projectSequenceDuration({
  required List<ClipSegment> segments,
  required Duration sourceDuration,
  List<ProjectMusic> musicTracks = const [],
  List<TextOverlay> overlays = const [],
}) {
  var total = totalKeptDuration(segments);
  if (total <= Duration.zero) total = sourceDuration;

  for (final music in musicTracks) {
    final span = musicSequenceSpan(music, segments);
    if (span != null && span.end > total) total = span.end;
  }
  for (final overlay in overlays) {
    final span = overlayTimelineSpan(overlay, segments);
    if (span != null && span.end > total) total = span.end;
  }
  return total;
}

/// Sequence length plus trailing empty runway for free trim / scrub past content.
Duration projectEditableSequenceDuration({
  required List<ClipSegment> segments,
  required Duration sourceDuration,
  List<ProjectMusic> musicTracks = const [],
  List<TextOverlay> overlays = const [],
}) {
  final content = projectSequenceDuration(
    segments: segments,
    sourceDuration: sourceDuration,
    musicTracks: musicTracks,
    overlays: overlays,
  );
  return content + timelineTrailingEditPad(content);
}

/// Furthest scrub position in source-time coordinates (may exceed video length
/// when music/text sit after the last frame). Trailing edit pad is not
/// scrubbable — that runway is for trim handles only.
Duration projectMaxScrubSourceTime({
  required List<ClipSegment> segments,
  required Duration sourceDuration,
  List<ProjectMusic> musicTracks = const [],
  List<TextOverlay> overlays = const [],
}) {
  final seq = projectSequenceDuration(
    segments: segments,
    sourceDuration: sourceDuration,
    musicTracks: musicTracks,
    overlays: overlays,
  );
  if (segments.isEmpty) return seq;
  return exportTimeToSourceTime(segments, seq);
}
